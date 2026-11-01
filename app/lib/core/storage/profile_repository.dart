/// 配置仓库：应用级的**单一数据源**。
///
/// 设计要点：
///  1. 全应用只开一次 [KvStore]、只建一次 [ProfileStore]，避免每个页面
///     各自读盘 + 各自 JSON 解析（三页三份缓存 = 三倍 IO 与解析开销）。
///  2. 保存配置元信息（[ProfileMeta]）：昵称、标签、收藏、备注、颜色、
///     使用次数与最后使用时间——这些属于「管理」维度，不进编译用的 IR。
///  3. 通过 [ChangeNotifier] 广播变更，任何页面只需 listen 即可刷新，
///     不必各自轮询磁盘。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ir/profile.dart';
import '../subscribe/subscription_fetcher.dart';
import 'kv_store.dart';
import 'profile_store.dart';
import 'secure_vault.dart';

/// 单个配置的管理元信息。
///
/// 与 [Profile] 分离存放：Profile 是给编译器看的纯 IR，
/// 元信息是给用户看的管理属性，两者生命周期不同。
class ProfileMeta {
  ProfileMeta({
    required this.profileId,
    this.nickname = '',
    this.tags = const [],
    this.favorite = false,
    this.note = '',
    this.colorIndex = 0,
    DateTime? createdAt,
    this.lastUsedAt,
    this.useCount = 0,
    this.syncedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String profileId;

  /// 自定义显示名；为空时回落到 Profile.name。
  final String nickname;

  /// 标签（分组用），例如「工作」「流媒体」。
  final List<String> tags;

  /// 是否收藏（置顶显示）。
  final bool favorite;

  /// 备注。
  final String note;

  /// 标签色索引，取值见 [ProfileMeta.palette]。
  final int colorIndex;

  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final int useCount;

  /// 上次从订阅拉取节点的时刻（非订阅配置恒为 null）。
  ///
  /// 放在元信息而不是 [Profile] 里：它属于「管理」维度，不该进编译产物，
  /// 也不该在跨内核切换时被复制。
  final DateTime? syncedAt;

  /// 展示用的名称。
  String displayName(Profile profile) =>
      nickname.trim().isEmpty ? profile.name : nickname.trim();

  ProfileMeta copyWith({
    String? nickname,
    List<String>? tags,
    bool? favorite,
    String? note,
    int? colorIndex,
    DateTime? lastUsedAt,
    int? useCount,
    DateTime? syncedAt,
  }) =>
      ProfileMeta(
        profileId: profileId,
        nickname: nickname ?? this.nickname,
        tags: tags ?? this.tags,
        favorite: favorite ?? this.favorite,
        note: note ?? this.note,
        colorIndex: colorIndex ?? this.colorIndex,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        useCount: useCount ?? this.useCount,
        syncedAt: syncedAt ?? this.syncedAt,
      );

  Map<String, Object?> toJson() => {
        'nickname': nickname,
        'tags': tags,
        'favorite': favorite,
        'note': note,
        'colorIndex': colorIndex,
        'createdAt': createdAt.toIso8601String(),
        'lastUsedAt': lastUsedAt?.toIso8601String(),
        'useCount': useCount,
        'syncedAt': syncedAt?.toIso8601String(),
      };

  factory ProfileMeta.fromJson(String id, Map<Object?, Object?> json) =>
      ProfileMeta(
        profileId: id,
        nickname: json['nickname'] as String? ?? '',
        tags: ((json['tags'] as List<Object?>?) ?? const []).cast<String>(),
        favorite: json['favorite'] as bool? ?? false,
        note: json['note'] as String? ?? '',
        colorIndex: json['colorIndex'] as int? ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        lastUsedAt: DateTime.tryParse(json['lastUsedAt'] as String? ?? ''),
        useCount: json['useCount'] as int? ?? 0,
        // 旧版本没有这个字段：解析失败即视为「从未同步」，
        // 界面上显示成「未更新」，不会崩也不会误报「刚刚更新」。
        syncedAt: DateTime.tryParse(json['syncedAt'] as String? ?? ''),
      );
}

/// 标签色板：索引 → 颜色值（ARGB int）。
///
/// 用 int 而非 Color，避免 core 层依赖 Flutter 渲染库。
abstract final class ProfileMetaPalette {
  /// 标签/星标取色：低饱和的八个色相。
  ///
  /// 之前用的是 0xFF4F46E5 / 0xFFE11D48 这类高饱和品牌色，标签一多
  /// 就在卡片里形成一片刺眼的彩色碎片。这里统一降到「灰调 + 一点色相」，
  /// 既能区分标签，又不会把注意力从配置名上抢走。
  static const List<int> colors = [
    0xFF3E5C76, // 黛蓝
    0xFF6B5E86, // 紫灰
    0xFF456E8A, // 青灰
    0xFF4C7A62, // 松绿
    0xFF9A7429, // 赭石
    0xFFA8443A, // 砖红
    0xFF4F7079, // 深青
    0xFF6E7B4F, // 苔灰
  ];

  static int colorAt(int index) =>
      colors[index.abs() % colors.length];
}

/// 配置排序方式。
enum ProfileSort {
  /// 最近使用优先（收藏始终置顶）。
  recent('最近使用'),

  /// 按名称排序。
  name('名称'),

  /// 按创建时间倒序。
  created('创建时间'),

  /// 按节点数量倒序。
  nodes('节点数');

  const ProfileSort(this.label);
  final String label;
}

/// 配置仓库单例。
class ProfileRepository extends ChangeNotifier {
  ProfileRepository._();

  static final ProfileRepository instance = ProfileRepository._();

  static const _keyMeta = 'boxhub.profileMeta';

  KvStore? _kv;
  ProfileStore? _store;
  Map<String, ProfileMeta> _metas = {};
  List<Profile> _profiles = [];
  bool _ready = false;

  bool get isReady => _ready;
  List<Profile> get profiles => List.unmodifiable(_profiles);

  /// 打开存储并载入全部配置。重复调用是安全的（幂等）。
  Future<void> init() async {
    if (_ready) return;
    final kv = await KvStore.open('${await AppPaths.supportDir()}/profiles.json');
    _kv = kv;
    // 敏感数据（订阅地址/节点凭据）走加密保险库；vault 打开失败时
    // 降级为明文存储（可用性优先，不阻塞主流程）。
    SecureVault? vault;
    try {
      vault = await SecureVault.open();
    } catch (_) {
      vault = null;
    }
    final store = ProfileStore(kv, vault: vault);
    _store = store;
    await store.load();
    _profiles = store.listProfiles();
    _metas = _readMetas(kv);
    _ready = true;
    notifyListeners();
  }

  /// 仅供测试：清空缓存并重置就绪状态。
  @visibleForTesting
  void resetForTest() {
    _kv = null;
    _store = null;
    _metas = {};
    _profiles = [];
    _ready = false;
  }

  ProfileStore get _requireStore {
    final s = _store;
    if (s == null) {
      throw StateError('ProfileRepository 尚未初始化，请先 await init()');
    }
    return s;
  }

  // ------------------------------------------------------------ 读取

  /// 全部元信息。
  Map<String, ProfileMeta> get metas => Map.unmodifiable(_metas);

  /// 某个配置的管理元信息（不存在时返回一个默认实例）。
  ProfileMeta metaOf(String profileId) =>
      _metas[profileId] ??
      ProfileMeta(profileId: profileId, colorIndex: _metas.length);

  /// 所有已用过的标签（去重，按使用频次降序）。
  List<String> get allTags {
    final count = <String, int>{};
    for (final m in _metas.values) {
      for (final t in m.tags) {
        count[t] = (count[t] ?? 0) + 1;
      }
    }
    final tags = count.keys.toList()
      ..sort((a, b) {
        final c = count[b]!.compareTo(count[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return tags;
  }

  /// 按筛选条件过滤 + 排序。
  ///
  /// [query] 匹配名称 / 昵称 / 备注 / 标签；[tag] 非空时只保留含该标签的项；
  /// [favoriteOnly] 只保留收藏项。
  List<Profile> filter({
    String query = '',
    String tag = '',
    bool favoriteOnly = false,
    ProfileSort sort = ProfileSort.recent,
  }) {
    final q = query.trim().toLowerCase();
    final result = _profiles.where((p) {
      final m = metaOf(p.id);
      if (favoriteOnly && !m.favorite) return false;
      if (tag.isNotEmpty && !m.tags.contains(tag)) return false;
      if (q.isEmpty) return true;
      final haystack = [
        p.name,
        m.nickname,
        m.note,
        ...m.tags,
      ].join(' ').toLowerCase();
      return haystack.contains(q);
    }).toList();

    result.sort((a, b) {
      final ma = metaOf(a.id);
      final mb = metaOf(b.id);
      // 收藏永远置顶
      if (ma.favorite != mb.favorite) return ma.favorite ? -1 : 1;
      switch (sort) {
        case ProfileSort.recent:
          final ta = ma.lastUsedAt?.millisecondsSinceEpoch ?? 0;
          final tb = mb.lastUsedAt?.millisecondsSinceEpoch ?? 0;
          final c = tb.compareTo(ta);
          if (c != 0) return c;
          return ma.createdAt.compareTo(mb.createdAt);
        case ProfileSort.name:
          return metaOf(a.id)
              .displayName(a)
              .toLowerCase()
              .compareTo(metaOf(b.id).displayName(b).toLowerCase());
        case ProfileSort.created:
          final c = mb.createdAt.compareTo(ma.createdAt);
          if (c != 0) return c;
          return metaOf(a.id).displayName(a).compareTo(
                metaOf(b.id).displayName(b),
              );
        case ProfileSort.nodes:
          final c = b.nodes.length.compareTo(a.nodes.length);
          if (c != 0) return c;
          return metaOf(a.id).displayName(a).compareTo(
                metaOf(b.id).displayName(b),
              );
      }
    });
    return result;
  }

  // ------------------------------------------------------------ 写入

  /// 新建或覆盖一个配置。
  Future<void> saveProfile(Profile profile) async {
    await _requireStore.saveBase(profile);
    _reloadProfiles();
    _ensureMeta(profile.id);
    await _persistMetas();
    notifyListeners();
  }

  /// 删除配置及其元信息。
  Future<void> deleteProfile(String profileId) async {
    await _requireStore.deleteBase(profileId);
    _metas.remove(profileId);
    _reloadProfiles();
    await _persistMetas();
    notifyListeners();
  }

  /// 重命名（改 Profile.name，同时清掉旧的昵称避免二者不一致）。
  Future<void> renameProfile(String profileId, String newName) async {
    final p = _findProfile(profileId);
    if (p == null) return;
    await saveProfile(p.copyWith(name: newName));
  }

  /// 复制配置：新 id + 名称加「副本」后缀，元信息一并复制但去掉收藏。
  Future<Profile> duplicateProfile(String profileId) async {
    final p = _findProfile(profileId);
    if (p == null) throw StateError('配置不存在: $profileId');
    final copy = p.copyWith(
      id: '${p.id}-copy-${DateTime.now().millisecondsSinceEpoch}',
      name: '${p.name} 副本',
    );
    await _requireStore.saveBase(copy);
    final m = metaOf(p.id);
    _metas[copy.id] = m.copyWith(
      nickname: m.nickname.isEmpty ? '' : '${m.nickname} 副本',
      favorite: false,
      useCount: 0,
    );
    _reloadProfiles();
    await _persistMetas();
    notifyListeners();
    return copy;
  }

  /// 更新元信息（昵称 / 标签 / 收藏 / 备注 / 颜色）。
  Future<void> updateMeta(
    String profileId, {
    String? nickname,
    List<String>? tags,
    bool? favorite,
    String? note,
    int? colorIndex,
  }) async {
    final m = metaOf(profileId);
    _metas[profileId] = m.copyWith(
      nickname: nickname,
      tags: tags,
      favorite: favorite,
      note: note,
      colorIndex: colorIndex,
    );
    await _persistMetas();
    notifyListeners();
  }

  /// 切换收藏。
  Future<void> toggleFavorite(String profileId) async {
    final m = metaOf(profileId);
    await updateMeta(profileId, favorite: !m.favorite);
  }

  /// 记录一次使用（启动成功时调用）。
  Future<void> markUsed(String profileId) async {
    final m = metaOf(profileId);
    _metas[profileId] = m.copyWith(
      lastUsedAt: DateTime.now(),
      useCount: m.useCount + 1,
    );
    await _persistMetas();
    notifyListeners();
  }

  // ------------------------------------------------------------ 订阅同步

  /// 仅测试用：替换订阅抓取实现，避免单测真的发网络请求。
  @visibleForTesting
  Future<SubscriptionFetchResult> Function(String url, CoreKind core)?
      debugFetcher;

  /// 重新拉取订阅并用最新节点替换当前配置的节点。
  ///
  /// 保留配置本身的一切（id / 名称 / 规则 / DNS / 入站），只换节点；
  /// 分组成员按新节点重新绑定（见 [rebindGroupMembers]）。
  /// 非订阅来源、地址为空、订阅返回空节点都直接抛错——静默「更新成功」
  /// 但节点数变成 0 比报错更糟。
  Future<SubscriptionRefreshResult> refreshSubscription(
    String profileId,
  ) async {
    final p = _findProfile(profileId);
    if (p == null) throw StateError('配置不存在：$profileId');
    final url = p.source.url;
    if (p.source.type != ProfileSourceType.subscription ||
        url == null ||
        url.isEmpty) {
      throw const FormatException('这个配置不是从订阅导入的，没有可更新的地址');
    }
    // 原生配置模式下编译器直接吐出订阅原文，节点列表根本不参与编译，
    // 在这里「更新节点」只是改了张用不上的表。
    if (p.isNativeConfig) {
      throw const FormatException('这份配置是原生配置，节点不参与编译，无需更新');
    }

    final fetcher = debugFetcher;
    final result = fetcher != null
        ? await fetcher(url, p.coreKind)
        : await SubscriptionFetcher().fetch(url, forCore: p.coreKind);
    if (result.nodes.isEmpty) {
      throw const FormatException('订阅没有返回任何可用节点');
    }

    await saveProfile(p.copyWith(
      nodes: result.nodes,
      groups: rebindGroupMembers(p.groups, result.nodes),
    ));
    _metas[profileId] = metaOf(profileId).copyWith(syncedAt: DateTime.now());
    await _persistMetas();
    notifyListeners();

    return SubscriptionRefreshResult(
      before: p.nodes.length,
      after: result.nodes.length,
      info: result.info,
    );
  }

  /// 把分组成员重新挂到一批新节点上。
  ///
  /// 节点 id 由「协议://服务器:端口/名称」派生，节点没变则 id 不变；
  /// 但订阅删掉或改名节点后，旧成员的 id 会悬空。编译器对悬空成员是
  /// **静默跳过**的，于是整个分组可能变成 `proxies: []`，内核加载时
  /// 直接拒绝启动。这里提前把悬空成员剔掉，`region:` 过滤器与其他分组
  /// 的引用原样保留。
  ///
  /// 若某个分组一个有效节点都不剩（订阅整批换了节点），退化为「全部
  /// 节点」——留一个空分组比给个兜底更糟：规则指过去等于没有出口。
  static List<ProxyGroup> rebindGroupMembers(
    List<ProxyGroup> groups,
    List<ProxyNode> nodes,
  ) {
    final nodeIds = {for (final n in nodes) n.id};
    final groupIds = {for (final g in groups) g.id};
    final allNodeIds = [for (final n in nodes) n.id];

    // 成员是否真能解析出至少一个节点。
    bool resolves(String m) {
      if (m.startsWith('region:')) {
        final kw = m.substring('region:'.length);
        return nodes.any((n) => n.name.contains(kw));
      }
      return nodeIds.contains(m);
    }

    return [
      for (final g in groups)
        () {
          final kept = [
            for (final m in g.members)
              if (m.startsWith('region:') ||
                  groupIds.contains(m) ||
                  nodeIds.contains(m))
                m,
          ];
          final hasNode = kept.any(resolves);
          return ProxyGroup(
            id: g.id,
            name: g.name,
            type: g.type,
            members: hasNode ? kept : [...kept, ...allNodeIds],
            url: g.url,
            intervalSeconds: g.intervalSeconds,
          );
        }(),
    ];
  }

  // ------------------------------------------------------- 导入 / 导出

  /// 导出单个配置为 JSON 字符串。
  String exportProfile(String profileId) {
    final p = _findProfile(profileId);
    if (p == null) throw StateError('配置不存在: $profileId');
    final m = metaOf(profileId);
    return const JsonEncoder.withIndent('  ').convert({
      'velaProfile': 1,
      'profile': p.toJson(),
      'meta': m.toJson(),
    });
  }

  /// 批量导出为 JSON 数组。
  String exportProfiles(List<String> profileIds) {
    final items = <Map<String, Object?>>[];
    for (final id in profileIds) {
      final p = _findProfile(id);
      if (p == null) continue;
      items.add({
        'profile': p.toJson(),
        'meta': metaOf(id).toJson(),
      });
    }
    return const JsonEncoder.withIndent('  ').convert({
      'velaProfile': 1,
      'items': items,
    });
  }

  /// 从导出文本导入。返回新配置 id 列表。
  ///
  /// 兼容单条与批量两种格式；遇到同 id 时自动改名加后缀，避免覆盖。
  Future<List<String>> importFromText(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('不是合法的 Vela 配置文件');
    }
    final items = <Map<Object?, Object?>>[];
    final single = decoded['profile'];
    if (single is Map<Object?, Object?>) {
      items.add(decoded);
    } else {
      final list = decoded['items'];
      if (list is List<Object?>) {
        for (final e in list) {
          if (e is Map<Object?, Object?>) items.add(e);
        }
      }
    }
    if (items.isEmpty) {
      throw const FormatException('文件里没有可导入的配置');
    }

    final created = <String>[];
    for (final item in items) {
      final rawProfile = item['profile'];
      if (rawProfile is! Map<Object?, Object?>) continue;
      var profile = Profile.fromJson(rawProfile);
      // 同名 / 同 id 时改名，避免覆盖已有配置
      if (_profiles.any((p) => p.id == profile.id)) {
        profile = profile.copyWith(
          id: '${profile.id}-imp-${DateTime.now().millisecondsSinceEpoch}',
          name: '${profile.name}（导入）',
        );
      }
      await _requireStore.saveBase(profile);
      final rawMeta = item['meta'];
      if (rawMeta is Map<Object?, Object?>) {
        final m = ProfileMeta.fromJson(profile.id, rawMeta);
        _metas[profile.id] = m.copyWith(useCount: 0);
      } else {
        _ensureMeta(profile.id);
      }
      created.add(profile.id);
    }
    _reloadProfiles();
    await _persistMetas();
    notifyListeners();
    return created;
  }

  /// 导出到文件（返回文件路径）。
  Future<String> exportToFile(
    List<String> profileIds, {
    String? fileName,
  }) async {
    final dir = Directory('${await AppPaths.supportDir()}/exports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = fileName ??
        'vela-profiles-${DateTime.now().millisecondsSinceEpoch}.json';
    final file = File('${dir.path}/$name');
    final text = profileIds.length == 1
        ? exportProfile(profileIds.first)
        : exportProfiles(profileIds);
    file.writeAsStringSync(text);
    return file.path;
  }

  // ------------------------------------------------------------ 内部

  Profile? _findProfile(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _reloadProfiles() {
    _profiles = _requireStore.listProfiles();
  }

  void _ensureMeta(String profileId) {
    if (!_metas.containsKey(profileId)) {
      _metas[profileId] =
          ProfileMeta(profileId: profileId, colorIndex: _metas.length);
    }
  }

  Map<String, ProfileMeta> _readMetas(KvStore kv) {
    final raw = kv.getString(_keyMeta);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<Object?, Object?>;
      final result = <String, ProfileMeta>{};
      for (final entry in map.entries) {
        final key = entry.key as String;
        final value = entry.value;
        if (value is Map<Object?, Object?>) {
          result[key] = ProfileMeta.fromJson(key, value);
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistMetas() async {
    final kv = _kv;
    if (kv == null) return;
    await kv.setString(
      _keyMeta,
      jsonEncode(
        _metas.map((k, v) => MapEntry(k, v.toJson())),
      ),
    );
  }
}

/// 一次订阅更新的结果：更新前后节点数 + 订阅方返回的流量信息。
class SubscriptionRefreshResult {
  const SubscriptionRefreshResult({
    required this.before,
    required this.after,
    this.info,
  });

  final int before;
  final int after;
  final SubscriptionUserInfo? info;

  /// 节点数变化量（可为负）。
  int get delta => after - before;
}
