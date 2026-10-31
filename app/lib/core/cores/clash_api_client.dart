/// clash API（external controller）客户端。
///
/// 两种连接方式：
///   - mihomo：仅 unix socket（安全约束：绝不暴露 TCP 端口）
///   - sing-box：v1.14 clashapi 仅支持 TCP 监听，走 127.0.0.1:<port>
///     + Bearer secret
///
/// Dart 的 HttpClient 不支持 unix socket，这里基于原生 [Socket] 实现一个
/// 极简 HTTP/1.1 客户端，覆盖所需端点：
///   GET  /version
///   GET  /connections            连接表 + 流量统计
///   PUT  /proxies/{group}        切换 selector 选中节点
///   GET  /proxies/{name}/delay   测延迟
///
/// Windows 命名管道在 M2 接入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ClashApiException implements Exception {
  ClashApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'ClashApiException($statusCode): $body';
}

class ClashApiClient {
  /// unix socket 连接（mihomo）。
  ClashApiClient.unix(String path, {this.secret = ''})
      : socketPath = path,
        tcpAddr = null;

  /// TCP 连接（sing-box clash API），[addr] 形如 "127.0.0.1:9090"。
  ClashApiClient.tcp(String addr, {this.secret = ''})
      : socketPath = null,
        tcpAddr = addr;

  final String? socketPath;
  final String? tcpAddr;
  final String secret;

  bool get _isUnix => socketPath != null;

  static const _timeout = Duration(seconds: 5);

  Future<Map<String, dynamic>> version() => getJson('/version');

  /// 连接表快照（含 downloadTotal / uploadTotal）。
  Future<Map<String, dynamic>?> connectionsRaw() async {
    final resp = await _request('GET', '/connections');
    if (resp.statusCode != 200) {
      throw ClashApiException(resp.statusCode, resp.body);
    }
    return resp.body.isEmpty ? null : jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// selector 切换选中出口。
  Future<void> selectProxy(String group, String name) async {
    final resp = await _request(
        'PUT', '/proxies/${Uri.encodeComponent(group)}', {'name': name});
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw ClashApiException(resp.statusCode, resp.body);
    }
  }

  /// 节点测延迟；不可达返回 null。
  Future<int?> proxyDelay(
      String name, {String url = 'https://www.gstatic.com/generate_204',
      int timeoutMs = 5000}) async {
    try {
      final resp = await _request(
          'GET',
          '/proxies/${Uri.encodeComponent(name)}/delay'
          '?timeout=$timeoutMs&url=${Uri.encodeComponent(url)}');
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return (json['delay'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final resp = await _request('GET', path);
    if (resp.statusCode != 200) {
      throw ClashApiException(resp.statusCode, resp.body);
    }
    return resp.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --------------------------------------------------------------------------
  // 极简 HTTP/1.1（unix socket 或 TCP 回环）
  // --------------------------------------------------------------------------

  Future<_HttpResponse> _request(String method, String path,
      [Object? body]) async {
    final Socket socket;
    if (_isUnix) {
      socket = await Socket.connect(
        InternetAddress(socketPath!, type: InternetAddressType.unix),
        0,
        timeout: _timeout,
      );
    } else {
      final sep = tcpAddr!.lastIndexOf(':');
      socket = await Socket.connect(
        tcpAddr!.substring(0, sep),
        int.parse(tcpAddr!.substring(sep + 1)),
        timeout: _timeout,
      );
    }
    try {
      final payload = body == null ? '' : jsonEncode(body);
      final auth = secret.isEmpty ? '' : 'Authorization: Bearer $secret\r\n';
      socket.write('$method $path HTTP/1.1\r\n'
          'Host: mihomo\r\n'
          '$auth'
          'Content-Type: application/json\r\n'
          'Connection: close\r\n'
          'Content-Length: ${utf8.encode(payload).length}\r\n'
          '\r\n'
          '$payload');
      await socket.flush();

      // Connection: close —— 服务端响应完毕后会关闭连接，读到 EOF 为止。
      final builder = BytesBuilder(copy: false);
      await for (final chunk in socket) {
        builder.add(chunk);
      }
      return _parseResponse(builder.takeBytes());
    } finally {
      socket.destroy();
    }
  }
}

class _HttpResponse {
  const _HttpResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

_HttpResponse _parseResponse(Uint8List raw) {
  final sep = _indexOf(raw, [13, 10, 13, 10]);
  if (sep < 0) {
    return const _HttpResponse(0, '响应缺少头部结束符');
  }
  final headerText = utf8.decode(raw.sublist(0, sep), allowMalformed: true);
  final bodyBytes = raw.sublist(sep + 4);

  final lines = headerText.split('\r\n');
  final status = int.tryParse(lines.first.split(' ')[1]) ?? 0;
  final headers = <String, String>{
    for (final line in lines.skip(1))
      if (line.contains(':'))
        line.split(':')[0].trim().toLowerCase():
            line.split(':').skip(1).join(':').trim(),
  };

  Uint8List body;
  if ((headers['transfer-encoding'] ?? '').contains('chunked')) {
    body = _decodeChunked(bodyBytes);
  } else {
    final len =
        int.tryParse(headers['content-length'] ?? '') ?? bodyBytes.length;
    body = bodyBytes.length > len ? bodyBytes.sublist(0, len) : bodyBytes;
  }
  return _HttpResponse(status, utf8.decode(body, allowMalformed: true));
}

Uint8List _decodeChunked(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  const crlf = [13, 10];
  while (i < data.length) {
    final lineEnd = _indexOf(data, crlf, i);
    if (lineEnd < 0) break;
    final sizeHex = String.fromCharCodes(data.sublist(i, lineEnd))
        .split(';')
        .first
        .trim();
    final size = int.tryParse(sizeHex, radix: 16);
    if (size == null || size == 0) break;
    out.add(data.sublist(lineEnd + 2, lineEnd + 2 + size));
    i = lineEnd + 2 + size + 2; // 块数据 + CRLF
  }
  return out.toBytes();
}

int _indexOf(Uint8List data, List<int> pattern, [int start = 0]) {
  outer:
  for (var i = start; i <= data.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}
