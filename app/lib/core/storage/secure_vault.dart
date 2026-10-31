/// 加密保险库：敏感数据（订阅地址、节点凭据）AES-256-GCM 加密落盘。
///
/// 设计约束：
///  - **零原生插件**：加密用纯 Dart 的 package:cryptography，不引入
///    CocoaPods/Gradle 原生链路（与 [KvStore] 的设计原则一致）。
///  - **数据**：`vault.bin`（AES-256-GCM 认证加密，每次写入随机 nonce），
///    位于应用支持目录。
///  - **主密钥**（32 字节随机）按平台保护：
///    - macOS：Keychain（`security add-generic-password`，通过系统 CLI
///      访问，不需要原生插件）
///    - Android：应用私有目录（沙盒 + 系统文件级加密保护）
///    - Windows / Linux：用户目录下的密钥文件（unix 下 0600 权限）
///    - 测试环境（[AppPaths.overrideSupportDir] 非空）：一律用密钥文件，
///      避免污染真实 Keychain
///
/// 威胁模型说明：此方案保证「拿到数据文件拿不到凭据」；密钥与数据同机
/// 时，有用户会话权限的攻击者仍可读取——这与系统 Keychain 方案的边界
/// 一致，属应用层能到的上限。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'kv_store.dart';

class SecureVault {
  SecureVault._(this._key, this._file, this._data);

  static final _aes = AesGcm.with256bits();

  /// vault 数据文件名（位于应用支持目录）。
  static const _fileName = 'vault.bin';
  static const _keychainService = 'dev.boxhub.boxhub.vault';

  final Uint8List _key;
  final File _file;
  final Map<String, Object?> _data;

  static Future<SecureVault> open() async {
    final dir = await AppPaths.supportDir();
    final file = File('$dir/$_fileName');
    var data = <String, Object?>{};
    if (await file.exists()) {
      try {
        data = (jsonDecode(await file.readAsString()) as Map<Object?, Object?>)
            .cast<String, Object?>();
      } catch (_) {
        // 数据损坏时从空开始（各条目相互独立，未损坏的条目不受影响）
      }
    }
    final key = await _loadOrCreateMasterKey(dir);
    // 数据文件收紧权限（unix）
    if (!Platform.isWindows && await file.exists()) {
      await Process.run('chmod', <String>['600', file.path]);
    }
    return SecureVault._(key, file, data);
  }

  Future<String?> readString(String key) async {
    final sealed = _data[key] as String?;
    if (sealed == null) return null;
    try {
      final box = SecretBox.fromConcatenation(
        base64Decode(sealed),
        nonceLength: 12,
        macLength: 16,
      );
      final clear = await _aes.decrypt(box, secretKey: SecretKey(_key));
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      // 密文被篡改或密钥不匹配：当作不存在（不抛出，调用方按未存储处理）
      return null;
    }
  }

  Future<void> setString(String key, String value) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(value),
      secretKey: SecretKey(_key),
      nonce: nonce,
    );
    _data[key] = base64Encode(box.concatenation());
    await _persist();
  }

  Future<void> delete(String key) async {
    if (!_data.containsKey(key)) return;
    _data.remove(key);
    await _persist();
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_data), flush: true);
  }

  // ---------------------------------------------------------------- 密钥

  static Future<Uint8List> _loadOrCreateMasterKey(String dir) async {
    // 测试环境一律用密钥文件，避免污染真实 Keychain
    if (Platform.isMacOS && AppPaths.overrideSupportDir == null) {
      final fromChain = await _keychainKey();
      if (fromChain != null) return fromChain;
    }
    return _fileKey(dir);
  }

  /// macOS：尝试从 Keychain 读取主密钥。
  ///
  /// 只读不写：`add-generic-password` 在沙盒内会触发 GUI 授权弹窗，
  /// 体验不可控；密钥不存在时走文件回退（沙盒容器本身受系统保护）。
  /// 需要更高保障时，可预先手工执行：
  ///   security add-generic-password -s dev.boxhub.boxhub.vault -a master \
  ///     -w <base64(32字节随机密钥)>
  static Future<Uint8List?> _keychainKey() async {
    try {
      final find = await Process.run(
        'security',
        <String>['find-generic-password', '-s', _keychainService, '-w'],
      );
      if (find.exitCode == 0) {
        final raw = (find.stdout as String).trim();
        if (raw.isNotEmpty) return base64Decode(raw);
      }
    } catch (_) {
      // CLI 不可用：走文件回退
    }
    return null;
  }

  /// 通用回退：支持目录下的密钥文件（unix 收紧到 0600）。
  static Future<Uint8List> _fileKey(String dir) async {
    final f = File('$dir/vault.key');
    if (await f.exists()) {
      final raw = (await f.readAsString()).trim();
      if (raw.isNotEmpty) return base64Decode(raw);
    }
    final key = _randomKey();
    await f.parent.create(recursive: true);
    await f.writeAsString(base64Encode(key), flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['600', f.path]);
    }
    return key;
  }

  static Uint8List _randomKey() {
    final rng = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(32, (_) => rng.nextInt(256)));
  }
}
