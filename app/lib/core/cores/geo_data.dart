/// GeoIP 数据库预置（mihomo 启动引导）。
///
/// 背景（真机/模拟器实测发现）：mihomo 在 DNS 初始化阶段就要加载 GeoIP
/// 数据库——编译产物里带 `dns.fallback-filter.geoip: true`，内核会立刻
/// 解析 MMDB。文件缺失时 mihomo 会**在启动过程中同步下载**，而 Android
/// / iOS 的 TUN 在 `VpnService.Builder.establish()` 那一刻就已经把系统
/// DNS 指向 TUN 网关（198.18.0.2），此时内核还没起来、TUN 里没有任何
/// DNS 服务在听，于是下载用的域名解析必然失败：
///
///   start mihomo: load GeoIP dns fallback filter error, can't download
///   MMDB: ... dns resolve failed: couldn't find ip
///
/// 结论：这是个「先有鸡还是先有蛋」的启动顺序问题，靠重试解决不了。
/// 正确做法是在建立 TUN **之前**（应用还有正常网络时）把 geoip.metadb
/// 预置到内核工作目录，内核启动时直接读文件，不再联网。
///
/// 预置失败不阻断启动：桌面端（非 TUN）本来就能联网下载，移动端也会
/// 在错误信息里如实暴露原因，比静默降级更好排查。
library;

import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart' show visibleForTesting;

abstract final class GeoData {
  /// mihomo 期望的文件名（`constant.SetHomeDir` 指定的工作目录下）。
  static const fileName = 'geoip.metadb';

  /// mihomo 默认的下载地址（与内核内置 geox-url 保持一致）。
  static const downloadUrl =
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb';

  /// 小于该体积视为损坏或不完整的占位文件。
  static const minBytes = 1 << 20; // 1 MB

  /// 测试用：替换真实下载。返回 null 表示下载失败。
  @visibleForTesting
  static Future<List<int>?> Function()? downloadOverride;

  /// 确保 [workDir] 下存在可用的 GeoIP 数据库。
  ///
  /// 返回 true 表示文件已就绪（本来就有或刚下载成功），false 表示预置
  /// 失败——调用方应继续启动内核，让内核自己报出可读的错误。
  static Future<bool> ensureMihomoGeoIp(String workDir) async {
    final file = File('$workDir/$fileName');
    try {
      if (await file.exists() && await file.length() >= minBytes) {
        return true;
      }
      await Directory(workDir).create(recursive: true);
      final bytes = await (downloadOverride ?? _download)();
      if (bytes == null || bytes.length < minBytes) return false;
      // 先写临时文件再 rename：下载中断不会留下半个文件骗过体积检查
      final tmp = File('$workDir/.$fileName.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<int>?> _download() async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..userAgent = 'Vela';
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
