/// 桌面端系统集成：菜单栏托盘、系统代理联动、开机自启。
///
/// - 托盘：macOS 由第一方 Swift 代码实现（MainFlutterWindow.swift 的
///   SystemChannels，通道 dev.boxhub.boxhub/system）；菜单结构由 Dart
///   生成下发，点击动作回传 [onTrayAction]。Windows 托盘待实现（需要
///   C++ Runner 代码），届时复用同一份菜单模型。
/// - 系统代理：内核运行期间自动把系统代理指向 mixed 端口（可经托盘
///   开关），停止内核时还原关闭。
/// - 开机自启：macOS 走 SMAppService（沙盒推荐方式），Windows 写 HKCU
///   Run 注册表键，Linux 写 ~/.config/autostart 桌面项。
///
/// 偏好持久化在独立的 settings.json（KvStore），不与配置数据混放。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/run/core_manager.dart';
import '../../features/run/core_quick_actions.dart';
import 'system_proxy.dart';
import '../storage/kv_store.dart';

/// 托盘菜单项模型（跨平台中立，Swift/未来 Windows 侧共用）。
class TrayItem {
  const TrayItem({
    required this.id,
    required this.title,
    this.checked = false,
    this.enabled = true,
  });

  /// 分隔线用 `---`。
  final String id;
  final String title;
  final bool checked;
  final bool enabled;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'checked': checked,
        'enabled': enabled,
      };
}

class DesktopIntegrations {
  DesktopIntegrations._();
  static final DesktopIntegrations instance = DesktopIntegrations._();

  static const _channel = MethodChannel('dev.boxhub.boxhub/system');
  static const _keySysProxy = 'boxhub.sysproxy';
  static const _keyAutostart = 'boxhub.autostart';

  KvStore? _prefs;
  bool _initialized = false;
  bool _busy = false;

  bool get isDesktop =>
      !kIsWeb &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool _sysProxyPref = false;
  bool get sysProxyPref => _sysProxyPref;

  bool _autostartPref = false;
  bool get autostartPref => _autostartPref;

  /// 初始化（桌面端调用；幂等）。读取偏好、注册托盘回调、
  /// 按当前内核状态同步一次系统代理。
  Future<void> init() async {
    if (!isDesktop || _initialized) return;
    _initialized = true;
    _prefs = await KvStore.open(
        '${await AppPaths.supportDir()}/settings.json');
    _sysProxyPref = _prefs!.getString(_keySysProxy) == '1';
    _autostartPref = await _readAutostartState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTrayAction') {
        final id = (call.arguments as Map<Object?, Object?>?)?['id'] as String?;
        if (id != null) await _onAction(id);
      }
      return null;
    });
    CoreManager.instance.addListener(_onCoreChanged);
    await refresh();
    await _syncSystemProxy();
  }

  /// 按当前内核状态刷新托盘菜单与系统代理。
  Future<void> refresh() async {
    if (!isDesktop || _prefs == null) return;
    await _updateTray();
    await _syncSystemProxy();
  }

  // ---------------------------------------------------------------- 托盘

  List<TrayItem> buildMenu() {
    final manager = CoreManager.instance;
    final running = manager.isActive;
    final profileName = manager.activeProfile?.name ?? '';
    final items = <TrayItem>[
      TrayItem(
        id: 'toggle',
        title: running
            ? (profileName.isEmpty ? '停止内核' : '停止「$profileName」')
            : '一键启动',
        enabled: !_busy,
      ),
      const TrayItem(id: '---', title: ''),
      if (SystemProxy.supported)
        TrayItem(
          id: 'sysproxy',
          title: '系统代理',
          checked: _sysProxyPref,
          enabled: !_busy,
        ),
      if (Platform.isMacOS)
        TrayItem(id: 'autostart', title: '开机自启', checked: _autostartPref),
      const TrayItem(id: '---', title: ''),
      const TrayItem(id: 'show', title: '打开主窗口'),
      const TrayItem(id: 'quit', title: '退出 Vela'),
    ];
    return items;
  }

  Future<void> _updateTray() async {
    if (!Platform.isMacOS) return;
    final manager = CoreManager.instance;
    try {
      await _channel.invokeMethod('setTray', {
        'items': buildMenu().map((e) => e.toJson()).toList(),
        'tooltip': manager.isActive
            ? 'Vela — 运行中（${manager.activeProfile?.name ?? ''}）'
            : 'Vela — 已停止',
      });
    } on PlatformException {
      // 原生侧未就绪（如老版本构建），静默
    }
  }

  Future<void> _onAction(String id) async {
    switch (id) {
      case 'toggle':
      case 'sysproxy':
        if (id == 'sysproxy') {
          _sysProxyPref = !_sysProxyPref;
          await _prefs?.setString(
              _keySysProxy, _sysProxyPref ? '1' : '0');
          await _syncSystemProxy();
        } else {
          _busy = true;
          await _updateTray();
          try {
            await CoreQuickActions.toggle();
          } finally {
            _busy = false;
          }
        }
        await refresh();
      case 'autostart':
        _autostartPref = !_autostartPref;
        final ok = await setAutostart(_autostartPref);
        if (!ok) _autostartPref = !_autostartPref; // 失败回滚
        await _prefs?.setString(
            _keyAutostart, _autostartPref ? '1' : '0');
        await _updateTray();
      case 'show':
        // macOS 侧在原生层已激活窗口；Windows 托盘实现后走 AppWindow
        break;
      case 'quit':
        try {
          await CoreManager.instance.stop();
          await SystemProxy.instance.disable();
        } catch (_) {}
        exit(0);
    }
  }

  void _onCoreChanged() {
    // 内核状态变化：刷新托盘标题 + 系统代理联动
    refresh();
  }

  // ------------------------------------------------------------ 系统代理

  Future<void> _syncSystemProxy() async {
    final manager = CoreManager.instance;
    if (manager.isActive && _sysProxyPref) {
      final port = manager.activeProfile?.inbound.mixedPort ?? 7890;
      if (!SystemProxy.instance.isEnabled) {
        await SystemProxy.instance.enable(port: port);
      }
    } else if (SystemProxy.instance.isEnabled) {
      await SystemProxy.instance.disable();
    }
  }

  // ------------------------------------------------------------ 开机自启

  Future<bool> _readAutostartState() async {
    if (Platform.isMacOS) {
      try {
        return await _channel.invokeMethod<bool>('getAutostart') ?? false;
      } on PlatformException {
        return false;
      }
    }
    return _prefs?.getString(_keyAutostart) == '1';
  }

  /// 设置开机自启。macOS 走 SMAppService；Windows 写 HKCU Run 键；
  /// Linux 写 ~/.config/autostart 桌面项。返回是否成功。
  Future<bool> setAutostart(bool enabled) async {
    if (Platform.isMacOS) {
      try {
        final ok =
            await _channel.invokeMethod<bool>('setAutostart', {
              'enabled': enabled,
            });
        return ok ?? false;
      } on PlatformException {
        return false;
      }
    }
    if (Platform.isWindows) {
      final exe = Platform.resolvedExecutable;
      final r = enabled
          ? await Process.run('reg', [
              'add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v', 'Vela', '/t', 'REG_SZ', '/d', '"$exe"', '/f',
            ])
          : await Process.run('reg', [
              'delete', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v', 'Vela', '/f',
            ]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) {
      final dir = Directory(
          '${Platform.environment['HOME'] ?? ''}/.config/autostart');
      final file = File('${dir.path}/vela.desktop');
      if (enabled) {
        await dir.create(recursive: true);
        await file.writeAsString('[Desktop Entry]\n'
            'Type=Application\n'
            'Name=Vela\n'
            'Exec=${Platform.resolvedExecutable}\n'
            'X-GNOME-Autostart-enabled=true\n');
      } else {
        if (await file.exists()) await file.delete();
      }
      return true;
    }
    return false;
  }
}
