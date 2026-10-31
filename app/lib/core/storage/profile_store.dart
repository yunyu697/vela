/// Profile 持久化 + Override 补丁层。
///
/// 设计要点：订阅原始数据（base）与用户修改（UserPatch）分开存储。
/// 订阅更新 = 仅替换 base 后重新 applyPatch，用户定制永不丢失。
library;

import 'dart:convert';

import 'kv_store.dart';

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

/// M1 用 KvStore（JSON 文件）存数据；M2 切到 sqlite + 加密（移动端
/// Keychain/Keystore 保护订阅凭据）。
class ProfileStore {
  ProfileStore(this._prefs);

  static const _keyProfiles = 'boxhub.profiles';
  static const _keyPatches = 'boxhub.patches';

  final KvStore _prefs;

  final Map<String, Profile> _baseCache = {};
  final Map<String, UserPatch> _patchCache = {};

  /// 全部已保存的 Profile（用于「运行」页选择）。
  List<Profile> listProfiles() => _readAllBase();

  Future<void> saveBase(Profile profile) async {
    // 注意：不能用 _baseCache 直接当全量写入，否则新建一个实例保存时会
    // 把磁盘上已有的配置全部覆盖掉。这里始终以「全量合并」的方式落盘。
    final all = _allBase().where((p) => p.id != profile.id).toList()..add(profile);
    _baseCache
      ..clear()
      ..addEntries(all.map((p) => MapEntry(p.id, p)));
    await _prefs.setString(_keyProfiles, jsonEncode(
      all.map((p) => p.toJson()).toList(),
    ));
  }

  /// 删除一个 Profile 及其补丁。
  Future<void> deleteBase(String profileId) async {
    final all = _allBase().where((p) => p.id != profileId).toList();
    _baseCache
      ..clear()
      ..addEntries(all.map((p) => MapEntry(p.id, p)));
    _patchCache.remove(profileId);
    await _prefs.setString(_keyProfiles, jsonEncode(
      all.map((p) => p.toJson()).toList(),
    ));
  }

  Future<void> savePatch(String profileId, UserPatch patch) async {
    _patchCache[profileId] = patch;
    await _prefs.setString(_keyPatches, jsonEncode(
      _patchCache.map((k, v) => MapEntry(k, v.toJson())),
    ));
  }

  List<Profile> _allBase() {
    if (_baseCache.isNotEmpty) return _baseCache.values.toList();
    final raw = _prefs.getString(_keyProfiles);
    if (raw == null) return const [];
    return _readAllBase();
  }

  List<Profile> _readAllBase() {
    if (_baseCache.isNotEmpty) return _baseCache.values.toList();
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
