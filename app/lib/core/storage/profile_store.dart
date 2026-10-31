/// Profile 持久化 + Override 补丁层。
///
/// 设计要点：
///  - 订阅原始数据（base）与用户修改（UserPatch）分开存储。订阅更新 =
///    仅替换 base 后重新 applyPatch，用户定制永不丢失。
///  - 传入 [SecureVault] 时，Profile 与补丁（含订阅地址、节点凭据等
///    敏感信息）加密存储，并在首次运行时自动从 KvStore 明文迁移；
///    不传 vault 时保持旧的明文 KvStore 行为（布局测试等场景）。
library;

import 'dart:convert';

import 'kv_store.dart';
import 'secure_vault.dart';

import '../ir/profile.dart';

/// 用户补丁：记录「相对 base 的所有修改」。
class UserPatch {
  const UserPatch({
    this.ruleSetToggles = const {},
    this.addedRules = const [],
    this.removedRuleIds = const [],
    this.dns,
    this.groupSelections = const {},
  });

  /// 规则集启用/禁用覆盖：规则集 id → 是否启用
  final Map<String, bool> ruleSetToggles;

  /// 用户新增的自定义规则
  final List<RuleEntry> addedRules;

  /// 用户禁用/删除的 base 规则 id
  final List<String> removedRuleIds;

  /// DNS 调整（为空则沿用 base）
  final DnsConfig? dns;

  /// 手动分组的选中项：分组 id → 节点 id
  final Map<String, String> groupSelections;

  bool get isEmpty =>
      ruleSetToggles.isEmpty &&
      addedRules.isEmpty &&
      removedRuleIds.isEmpty &&
      dns == null &&
      groupSelections.isEmpty;

  /// 应用补丁到 base，得到生效的 Profile。
  Profile applyTo(Profile base) {
    final effectiveRules = <RuleEntry>[
      for (final r in base.rules)
        if (!removedRuleIds.contains(r.id))
          RuleEntry(
            id: r.id,
            action: r.action,
            ruleSetIds: r.ruleSetIds,
            domains: r.domains,
            ipCidrs: r.ipCidrs,
            outboundGroupId: r.outboundGroupId,
            enabled: r.enabled &&
                !r.ruleSetIds.any((id) => ruleSetToggles[id] == false),
          ),
      ...addedRules,
    ];

    return base.copyWith(
      rules: effectiveRules,
      dns: dns ?? base.dns,
    );
  }

  Map<String, Object?> toJson() => {
        'ruleSetToggles': ruleSetToggles,
        'addedRules': addedRules.map((r) => r.toJson()).toList(),
        'removedRuleIds': removedRuleIds,
        'dns': dns?.toJson(),
        'groupSelections': groupSelections,
      };

  factory UserPatch.fromJson(Map<Object?, Object?> json) => UserPatch(
        ruleSetToggles: ((json['ruleSetToggles'] as Map<Object?, Object?>?) ?? const {})
            .cast<String, bool>(),
        addedRules: ((json['addedRules'] as List<Object?>?) ?? const [])
            .map((r) => RuleEntry.fromJson(r as Map<Object?, Object?>))
            .toList(),
        removedRuleIds:
            ((json['removedRuleIds'] as List<Object?>?) ?? const []).cast<String>(),
        dns: json['dns'] == null
            ? null
            : DnsConfig.fromJson(json['dns'] as Map<Object?, Object?>),
        groupSelections: ((json['groupSelections'] as Map<Object?, Object?>?) ?? const {})
            .cast<String, String>(),
      );
}

class ProfileStore {
  ProfileStore(this._prefs, {SecureVault? vault}) : _vault = vault;

  static const _keyProfiles = 'boxhub.profiles';
  static const _keyPatches = 'boxhub.patches';

  final KvStore _prefs;
  final SecureVault? _vault;

  final Map<String, Profile> _baseCache = {};
  final Map<String, UserPatch> _patchCache = {};

  /// 加载全部数据进缓存（repository.init 时调用一次）。
  ///
  /// 首次启用加密存储时执行**明文迁移**：把 KvStore 里的旧明文
  /// Profile/补丁写入 vault 后，从明文文件中删除。
  Future<void> load() async {
    await _loadBlob(_keyProfiles, (raw) {
      final parsed = (jsonDecode(raw) as List<Object?>)
          .map((e) => Profile.fromJson(e as Map<Object?, Object?>))
          .toList();
      _baseCache
        ..clear()
        ..addEntries(parsed.map((p) => MapEntry(p.id, p)));
    });
    await _loadBlob(_keyPatches, (raw) {
      final map = (jsonDecode(raw) as Map<Object?, Object?>)
          .cast<String, Object?>();
      _patchCache
        ..clear()
        ..addEntries(map.entries.map((e) =>
            MapEntry(e.key, UserPatch.fromJson(e.value as Map<Object?, Object?>))));
    });
  }

  /// 读一个 blob：vault 优先；vault 未命中时尝试明文 KvStore 并迁移。
  Future<String?> _loadBlob(
      String key, void Function(String raw) intoCache) async {
    var raw = await _vault?.readString(key);
    if (raw == null) {
      final legacy = _prefs.getString(key);
      if (legacy != null) {
        if (_vault != null) {
          await _vault.setString(key, legacy);
          await _prefs.remove(key); // 明文清除，只留密文
        }
        raw = legacy;
      }
    }
    if (raw != null) intoCache(raw);
    return raw;
  }

  /// 全部已保存的 Profile（用于「运行」页选择）。
  List<Profile> listProfiles() => _readAllBase();

  Future<void> saveBase(Profile profile) async {
    // 注意：不能用 _baseCache 直接当全量写入，否则新建一个实例保存时会
    // 把磁盘上已有的配置全部覆盖掉。这里始终以「全量合并」的方式落盘。
    final all = _allBase().where((p) => p.id != profile.id).toList()..add(profile);
    _baseCache
      ..clear()
      ..addEntries(all.map((p) => MapEntry(p.id, p)));
    await _writeBlob(_keyProfiles, jsonEncode(all.map((p) => p.toJson()).toList()));
  }

  /// 删除一个 Profile 及其补丁。
  Future<void> deleteBase(String profileId) async {
    final all = _allBase().where((p) => p.id != profileId).toList();
    _baseCache
      ..clear()
      ..addEntries(all.map((p) => MapEntry(p.id, p)));
    _patchCache.remove(profileId);
    await _writeBlob(_keyProfiles, jsonEncode(all.map((p) => p.toJson()).toList()));
  }

  Future<void> savePatch(String profileId, UserPatch patch) async {
    _patchCache[profileId] = patch;
    await _writeBlob(_keyPatches,
        jsonEncode(_patchCache.map((k, v) => MapEntry(k, v.toJson()))));
  }

  /// blob 写入路由：有 vault 走密文，否则明文 KvStore。
  Future<void> _writeBlob(String key, String value) async {
    final vault = _vault;
    if (vault != null) {
      await vault.setString(key, value);
      // 兜底清除可能存在的旧明文（load() 已迁，防御构造顺序差异）
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }

  List<Profile> _allBase() => _readAllBase();

  /// 同步读缓存。带 vault 时数据只能经 [load] 异步进入缓存（init 保证）；
  /// 无 vault 时保留旧的直读 KvStore 行为（布局测试直接构造的场景）。
  List<Profile> _readAllBase() {
    if (_baseCache.isNotEmpty) return _baseCache.values.toList();
    if (_vault != null) return const [];
    final raw = _prefs.getString(_keyProfiles);
    if (raw == null) return const [];
    final parsed = (jsonDecode(raw) as List<Object?>)
        .map((e) => Profile.fromJson(e as Map<Object?, Object?>))
        .toList();
    // 解析结果写回缓存：否则每次 listProfiles() 都会重新 jsonDecode 全量
    // 配置。订阅动辄上百节点，重复解析是明显的 CPU 浪费。
    _baseCache
      ..clear()
      ..addEntries(parsed.map((p) => MapEntry(p.id, p)));
    return parsed;
  }

  Profile effectiveProfile(String profileId) {
    final base = _baseCache[profileId] ??
        _readAllBase().where((p) => p.id == profileId).firstOrNull;
    if (base == null) throw StateError('Profile 不存在: $profileId');
    final patch = _patchCache[profileId] ??
        _readPatch(profileId);
    return patch == null ? base : patch.applyTo(base);
  }

  UserPatch? _readPatch(String profileId) {
    final cached = _patchCache[profileId];
    if (cached != null) return cached;
    if (_vault != null) return null; // 补丁由 load() 异步载入缓存
    final raw = _prefs.getString(_keyPatches);
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<Object?, Object?>;
    final entry = map[profileId];
    if (entry == null) return null;
    final patch = UserPatch.fromJson(entry as Map<Object?, Object?>);
    _patchCache[profileId] = patch;
    return patch;
  }

  /// 订阅更新：仅替换 base，重新 applyPatch。
  Future<void> replaceBaseFromSubscription(String profileId, Profile newBase) async {
    assert(newBase.id == profileId);
    await saveBase(newBase);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
