/// 应用本地存储：零原生插件依赖（替代 shared_preferences / path_provider）。
///
/// 设计动机：应用核心是 FFI + 自管平台层，避免 CocoaPods/Gradle 原生
/// 插件链路（桌面端少一层构建依赖，移动端减少插件审核面）。
/// M2 若引入 sqlite/加密存储，再按平台通道接入。
library;

import 'dart:convert';
import 'dart:io';

/// 简单文件 KV 存储（JSON 全量落盘）。
class KvStore {
  KvStore._(this._file, this._data);

  final File _file;
  final Map<String, Object?> _data;

  static Future<KvStore> open(String path) async {
    final file = File(path);
    var data = <String, Object?>{};
    if (await file.exists()) {
      try {
        data = (jsonDecode(await file.readAsString()) as Map<Object?, Object?>)
            .cast<String, Object?>();
      } catch (_) {
        // 文件损坏时从空开始（M2 接入备份/恢复策略）
      }
    }
    return KvStore._(file, data);
  }

  String? getString(String key) => _data[key] as String?;

  Future<void> setString(String key, String value) async {
    _data[key] = value;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_data), flush: true);
  }

  /// 删除一个键（不存在时为空操作）。
  ///
  /// 用于敏感数据迁移：Profile/补丁迁入 [SecureVault] 后从明文文件清除。
  Future<void> remove(String key) async {
    if (!_data.containsKey(key)) return;
    _data.remove(key);
    await _file.writeAsString(jsonEncode(_data), flush: true);
  }
}

/// 应用数据目录（配置文件、unix socket、KV 存放处）。
class AppPaths {
  AppPaths._();

  /// Android 平台通道取到的 filesDir（main.dart 初始化时写入；
  /// Android 上 HOME 环境变量不可靠，必须由 Kotlin 侧提供真实路径）。
  static String? androidFilesDir;

  /// iOS 的 App Group 容器路径（main.dart 初始化时写入）。
  ///
  /// 内核跑在 PacketTunnel 扩展进程里，与 App 的沙盒互不相通；只有
  /// App Group 目录两边都能读写，所以控制器 socket 与内核工作目录
  /// （geoip.metadb 等）必须放在这里。
  static String? sharedGroupDir;

  /// 测试用：覆盖数据目录（null 表示按平台默认）。
  static String? overrideSupportDir;

  /// 按平台返回应用支持目录；目录不存在时自动创建。
  static Future<String> supportDir() async {
    if (overrideSupportDir != null) {
      final dir = overrideSupportDir!;
      await Directory(dir).create(recursive: true);
      return dir;
    }
    if (Platform.isAndroid && androidFilesDir != null) {
      final dir = androidFilesDir!;
      await Directory(dir).create(recursive: true);
      return dir;
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final String dir;
    if (Platform.isMacOS) {
      // App Sandbox 下该路径自动重定向到应用容器目录
      dir = '$home/Library/Application Support/dev.boxhub.boxhub';
    } else if (Platform.isLinux) {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
      dir = '$dataHome/boxhub';
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? home;
      dir = '$appData\\boxhub';
    } else {
      dir = '$home/.boxhub';
    }
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// 内核 controller 的 unix socket / 命名管道路径。
  ///
  /// macOS 对 socket 路径有 104 字符硬上限，App 沙盒容器路径
  /// （`~/Library/Containers/.../Application Support/...`）必然超限，
  /// 因此固定放在 `$HOME/.boxhub/` 下（沙盒内自动重定向到容器 Data，
  /// 路径约 80 字符；沙盒外即真实家目录，同样很短）。Windows 用命名
  /// 管道，无路径限制。同一时刻仅一个内核实例运行，路径可复用。
  static String coreSocketPath() {
    if (Platform.isWindows) return r'\\.\pipe\boxhub-mihomo';
    if (Platform.isAndroid && androidFilesDir != null) {
      // 应用私有目录，路径短且不受沙盒限制
      return '$androidFilesDir/mihomo.sock';
    }
    if (Platform.isIOS && sharedGroupDir != null) {
      // iOS：内核在扩展进程里创建 socket，App 进程去连，只有 App Group
      // 容器两边都可达。名字取最短（mh.sock），因为 unix socket 路径
      // 有 104 字符硬上限，而 App Group 容器路径本身已约 83 字符。
      return '$sharedGroupDir/mh.sock';
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final dir = Directory('$home/.boxhub')
      ..createSync(recursive: true);
    return '${dir.path}/mihomo.sock';
  }

  /// 内核工作目录（配置、geoip 库、缓存）。
  ///
  /// iOS 上内核进程的工作目录必须是 App Group 容器：App 负责把
  /// geoip.metadb 下载到那里，扩展启动内核时才能直接读到（两个进程的
  /// 沙盒互不可见，放各自目录里等于没准备）。
  static Future<String> coreWorkDir(String profileDir) async {
    if (Platform.isIOS && sharedGroupDir != null) {
      final dir = '$sharedGroupDir/core';
      await Directory(dir).create(recursive: true);
      return dir;
    }
    final dir = '$profileDir/work';
    await Directory(dir).create(recursive: true);
    return dir;
  }
}
