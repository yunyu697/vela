/// 系统代理设置（桌面端）。
///
/// 内核启动后把系统 HTTP/HTTPS/SOCKS 代理指向 mixed 入站端口，
/// 停止时还原（关闭）。命令构建与执行分离（[runCmd] 可注入），便于测试。
///
/// 平台实现：
///  - macOS：`networksetup`（遍历所有网络服务逐个设置）
///  - Windows：HKCU 注册表 Internet Settings（无需管理员）
///  - Linux：gsettings（GNOME 系桌面；其它桌面环境忽略）
///
/// 已知边界：v1 停止时不恢复用户原有代理，直接整体关闭——下次启用时
/// 由本应用接管。还原原状态需要逐服务记录现场，M2 再做。
library;

import 'dart:io';

typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> args);

/// 系统代理服务（应用级单例）。
class SystemProxy {
  SystemProxy._();
  static final SystemProxy instance = SystemProxy._();

  ProcessRunner runCmd = Process.run;
  bool _enabled = false;

  bool get isEnabled => _enabled;

  /// 是否支持当前平台。
  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// 开启系统代理，指向 [host]:[port]（mixed 入站）。
  Future<void> enable({
    String host = '127.0.0.1',
    required int port,
  }) async {
    if (!supported) return;
    final ok = Platform.isMacOS
        ? await _enableMac(host, port)
        : Platform.isWindows
            ? await _enableWindows(host, port)
            : await _enableLinux(host, port);
    _enabled = ok;
  }

  /// 关闭系统代理。
  Future<void> disable() async {
    if (!supported) return;
    final ok = Platform.isMacOS
        ? await _disableMac()
        : Platform.isWindows
            ? await _disableWindows()
            : await _disableLinux();
    if (ok) _enabled = false;
  }

  // ---------------------------------------------------------------- macOS

  Future<List<String>> _macServices() async {
    final r = await runCmd('networksetup', ['-listallnetworkservices']);
    if (r.exitCode != 0) return const [];
    // 第一行是表头；带 * 的是被禁用的服务，跳过
    return (r.stdout as String)
        .split('\n')
        .skip(1)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.startsWith('*'))
        .toList();
  }

  Future<bool> _enableMac(String host, int port) async {
    var allOk = true;
    for (final svc in await _macServices()) {
      for (final args in [
        ['-setwebproxy', svc, host, '$port'],
        ['-setsecurewebproxy', svc, host, '$port'],
        ['-setsocksfirewallproxy', svc, host, '$port'],
        ['-setproxybypassdomains', svc, '127.0.0.1', 'localhost', '*.local'],
      ]) {
        final r = await runCmd('networksetup', args);
        if (r.exitCode != 0) allOk = false;
      }
    }
    return allOk;
  }

  Future<bool> _disableMac() async {
    var allOk = true;
    for (final svc in await _macServices()) {
      for (final args in [
        ['-setwebproxy', svc, 'off'],
        ['-setsecurewebproxy', svc, 'off'],
        ['-setsocksfirewallproxy', svc, 'off'],
      ]) {
        final r = await runCmd('networksetup', args);
        if (r.exitCode != 0) allOk = false;
      }
    }
    return allOk;
  }

  // ---------------------------------------------------------------- Windows

  static const _winKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  Future<bool> _enableWindows(String host, int port) async {
    final results = await Future.wait([
      runCmd('reg',
          ['add', _winKey, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']),
      runCmd('reg', [
        'add', _winKey, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d',
        '$host:$port', '/f',
      ]),
      runCmd('reg', [
        'add', _winKey, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d',
        'localhost;127.*;*.local', '/f',
      ]),
    ]);
    return results.every((r) => r.exitCode == 0);
  }

  Future<bool> _disableWindows() async {
    final r = await runCmd('reg',
        ['add', _winKey, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
    return r.exitCode == 0;
  }

  // ---------------------------------------------------------------- Linux

  Future<bool> _enableLinux(String host, int port) async {
    final commands = [
      ['set', 'org.gnome.system.proxy', 'mode', "'manual'"],
      ['set', 'org.gnome.system.proxy.http', 'host', "'$host'"],
      ['set', 'org.gnome.system.proxy.http', 'port', '$port'],
      ['set', 'org.gnome.system.proxy.https', 'host', "'$host'"],
      ['set', 'org.gnome.system.proxy.https', 'port', '$port'],
      ['set', 'org.gnome.system.proxy.socks', 'host', "'$host'"],
      ['set', 'org.gnome.system.proxy.socks', 'port', '$port'],
    ];
    var allOk = true;
    for (final c in commands) {
      final r = await runCmd('gsettings', c);
      if (r.exitCode != 0) allOk = false;
    }
    return allOk;
  }

  Future<bool> _disableLinux() async {
    final r = await runCmd(
        'gsettings', ['set', 'org.gnome.system.proxy', 'mode', "'none'"]);
    return r.exitCode == 0;
  }
}
