/// 内核桥接动态库的 FFI 绑定（桌面端通用）。
///
/// mihomo 与 sing-box 两个桥接库导出相同的 C API：
///   StartConfig / StopConfig / RestartConfig / IsRunning / LastError / FreeCString
///
/// 动态库由 `cores/mihomo-bridge/build_desktop.sh` 统一构建，查找顺序：
///   1. 环境变量 BOXHUB_MIHOMO_LIB / BOXHUB_SINGBOX_LIB（显式指定）
///   2. 可执行文件同目录 / macOS bundle 的 Frameworks/（打包产物）
///   3. 仓库 desktop-libs/<os>-<arch>/（开发期构建产物）
///
/// 移动端不使用本文件：Android/iOS 走 gomobile 平台通道。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 两个内核桥接库。
enum BridgeCore { mihomo, singbox }

/// 动态库缺失或平台不支持时抛出。
class BridgeNotAvailableException implements Exception {
  BridgeNotAvailableException(this.message);
  final String message;

  @override
  String toString() => 'BridgeNotAvailableException: $message';
}

typedef _StartConfigNative = Int32 Function(Pointer<Char>, Pointer<Char>,
    Pointer<Char>, Pointer<Char>);
typedef _StartConfigDart = int Function(
    Pointer<Char>, Pointer<Char>, Pointer<Char>, Pointer<Char>);
typedef _NoArgNative = Int32 Function();
typedef _NoArgDart = int Function();
typedef _LastErrorNative = Pointer<Char> Function();
typedef _LastErrorDart = Pointer<Char> Function();
typedef _FreeNative = Void Function(Pointer<Char>);
typedef _FreeDart = void Function(Pointer<Char>);

class BoxBridgeFfi {
  BoxBridgeFfi._(this.core, this.libraryPath, DynamicLibrary lib)
      : _startConfig = lib
            .lookupFunction<_StartConfigNative, _StartConfigDart>('StartConfig'),
        _stopConfig =
            lib.lookupFunction<_NoArgNative, _NoArgDart>('StopConfig'),
        _restartConfig = lib.lookupFunction<_StartConfigNative,
            _StartConfigDart>('RestartConfig'),
        _isRunning = lib.lookupFunction<_NoArgNative, _NoArgDart>('IsRunning'),
        _lastError =
            lib.lookupFunction<_LastErrorNative, _LastErrorDart>('LastError'),
        _freeC = lib.lookupFunction<_FreeNative, _FreeDart>('FreeCString');

  static final Map<BridgeCore, BoxBridgeFfi> _instances = {};

  final BridgeCore core;

  /// 加载桥接库（按内核进程内单例）。失败抛 [BridgeNotAvailableException]。
  factory BoxBridgeFfi.load(BridgeCore core) {
    final cached = _instances[core];
    if (cached != null) return cached;
    final path = findLibraryPath(core);
    if (path == null) {
      final dirName = switch (Abi.current()) {
        Abi.macosArm64 => 'darwin-arm64',
        Abi.macosX64 => 'darwin-x64',
        Abi.windowsX64 => 'windows-x64',
        Abi.windowsArm64 => 'windows-arm64',
        Abi.linuxX64 => 'linux-x64',
        Abi.linuxArm64 => 'linux-arm64',
        _ => '<platform>',
      };
      throw BridgeNotAvailableException(
          '未找到 $core 桥接动态库。请先运行 '
          'cores/mihomo-bridge/build_desktop.sh 构建桌面端产物'
          '（desktop-libs/$dirName/），'
          '或设置环境变量 ${_envKey(core)} 指向库文件。');
    }
    return _instances[core] =
        BoxBridgeFfi._(core, path, DynamicLibrary.open(path));
  }

  final String libraryPath;
  final _StartConfigDart _startConfig;
  final _NoArgDart _stopConfig;
  final _StartConfigDart _restartConfig;
  final _NoArgDart _isRunning;
  final _LastErrorDart _lastError;
  final _FreeDart _freeC;

  /// 启动内核。返回 0 成功；失败时读取 [lastError]。
  int startConfig(
      String configText, String homeDir, String controllerPath,
      String secret) {
    final c = configText.toNativeUtf8().cast<Char>();
    final h = homeDir.toNativeUtf8().cast<Char>();
    final u = controllerPath.toNativeUtf8().cast<Char>();
    final s = secret.toNativeUtf8().cast<Char>();
    try {
      return _startConfig(c, h, u, s);
    } finally {
      calloc
        ..free(c)
        ..free(h)
        ..free(u)
        ..free(s);
    }
  }

  /// 停止内核（幂等）。返回 0 成功。
  int stopConfig() => _stopConfig();

  /// 换配置平滑重启。返回 0 成功。
  int restartConfig(
          String configText, String homeDir, String controllerPath,
          String secret) =>
      _restartConfig(
        configText.toNativeUtf8().cast<Char>(),
        homeDir.toNativeUtf8().cast<Char>(),
        controllerPath.toNativeUtf8().cast<Char>(),
        secret.toNativeUtf8().cast<Char>(),
      );

  bool isRunning() => _isRunning() != 0;

  String lastError() {
    final p = _lastError();
    if (p == nullptr) return '';
    final s = p.cast<Utf8>().toDartString();
    _freeC(p);
    return s;
  }

  // --------------------------------------------------------------------------
  // 库文件查找
  // --------------------------------------------------------------------------

  static String _envKey(BridgeCore core) => switch (core) {
        BridgeCore.mihomo => 'BOXHUB_MIHOMO_LIB',
        BridgeCore.singbox => 'BOXHUB_SINGBOX_LIB',
      };

  static String? findLibraryPath(BridgeCore core) {
    final env = Platform.environment[_envKey(core)];
    if (env != null && File(env).existsSync()) return env;

    final base = switch (core) {
      BridgeCore.mihomo => 'boxhub_mihomo',
      BridgeCore.singbox => 'boxhub_singbox',
    };
    final (String, String)? platform = switch (Abi.current()) {
      Abi.macosArm64 => ('lib$base.dylib', 'darwin-arm64'),
      Abi.macosX64 => ('lib$base.dylib', 'darwin-x64'),
      Abi.windowsX64 => ('$base.dll', 'windows-x64'),
      Abi.windowsArm64 => ('$base.dll', 'windows-arm64'),
      Abi.linuxX64 => ('lib$base.so', 'linux-x64'),
      Abi.linuxArm64 => ('lib$base.so', 'linux-arm64'),
      _ => null, // Android / iOS 走 gomobile 通道
    };
    if (platform == null) return null;
    final (libName, dirName) = platform;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir/$libName', // Windows/Linux：与可执行文件同目录
      '$exeDir/../Frameworks/$libName', // macOS bundle: Contents/Frameworks
      '${Directory.current.path}/desktop-libs/$dirName/$libName',
      '${Directory.current.path}/../desktop-libs/$dirName/$libName',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }
}
