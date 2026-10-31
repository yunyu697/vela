/// 应用级偏好设置：主题模式等「用户可见的开关」。
///
/// 与 [ProfileRepository] 同样走单例 + [ChangeNotifier]：设置项极少，
/// 但主题变化需要整棵树重建，放在一个可监听的中心比层层传参干净。
///
/// 持久化落在支持目录下的 `settings.json`（与 profiles.json 分开：
/// 设置不含敏感信息，不需要进 SecureVault，也不该被配置导入导出带走）。
library;

import 'package:flutter/material.dart';

import '../storage/kv_store.dart';

/// Vela 的主题模式。
///
/// 直接复用 Flutter 的 [ThemeMode]：三态语义完全一致，多一层自定义
/// 枚举只会在 MaterialApp 处多一次映射，没有收益。
extension VelaThemeModeLabel on ThemeMode {
  String get label => switch (this) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '亮色',
        ThemeMode.dark => '暗色',
      };

  IconData get icon => switch (this) {
        ThemeMode.system => Icons.brightness_auto_rounded,
        ThemeMode.light => Icons.light_mode_rounded,
        ThemeMode.dark => Icons.dark_mode_rounded,
      };

  /// 循环切换：跟随系统 → 亮色 → 暗色 → 跟随系统。
  ThemeMode get next => switch (this) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      };
}

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const _keyThemeMode = 'boxhub.themeMode';

  /// 默认跟随系统。
  ///
  /// 历史包袱说明：暗色主题曾经是半成品（近黑画布 + 未打磨的对比度），
  /// 当时把 `ThemeMode` 硬编码成 light 规避「UI 有时变黑」。暗色已完成
  /// 打磨并补了暗色黄金图守卫，默认值恢复为跟随系统。
  static const defaultThemeMode = ThemeMode.system;

  KvStore? _kv;
  ThemeMode _themeMode = defaultThemeMode;
  bool _ready = false;

  ThemeMode get themeMode => _themeMode;

  /// 是否已从磁盘载入（未载入时用默认值，不阻塞首帧）。
  bool get isReady => _ready;

  /// 打开存储并载入设置。重复调用安全（幂等）。
  Future<void> init() async {
    if (_ready) return;
    try {
      final kv = await KvStore.open('${await AppPaths.supportDir()}/settings.json');
      _kv = kv;
      _themeMode = _parseThemeMode(kv.getString(_keyThemeMode));
    } catch (_) {
      // 存储不可用时保持默认值：设置项失败不该阻塞启动
    }
    _ready = true;
    notifyListeners();
  }

  /// 切换主题模式并落盘。写入失败只影响下次启动，内存状态立即生效。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      await _kv?.setString(_keyThemeMode, mode.name);
    } catch (_) {
      // 忽略落盘失败
    }
  }

  /// 循环切换到下一个模式（供侧栏按钮 / 快捷键使用）。
  Future<void> cycleThemeMode() => setThemeMode(_themeMode.next);

  /// 仅供测试：重置内存状态。
  @visibleForTesting
  void resetForTest() {
    _kv = null;
    _themeMode = defaultThemeMode;
    _ready = false;
  }

  static ThemeMode _parseThemeMode(String? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return defaultThemeMode;
  }
}
