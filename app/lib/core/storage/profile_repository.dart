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
import 'kv_store.dart';
import 'profile_store.dart';

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
      );
}

/// 标签色板：索引 → 颜色值（ARGB int）。
///
/// 用 int 而非 Color，避免 core 层依赖 Flutter 渲染库。
abstract final class ProfileMetaPalette {
  static const List<int> colors = [
    0xFF4F46E5, // 靛蓝
    0xFF7C3AED, // 紫罗兰
    0xFF0EA5E9, // 天青
    0xFF10B981, // 翠绿
    0xFFF59E0B, // 琥珀
    0xFFE11D48, // 玫红
    0xFF0891B2, // 深青
    0xFF65A30D, // 苔绿
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
    _store = ProfileStore(kv);
    _profiles = _store!.listProfiles();
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
