/// SecureVault 功能测试：加密落盘 + 明文迁移。
///
/// 测试环境走密钥文件回退（AppPaths.overrideSupportDir 非空），
/// 不触碰真实 Keychain。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/core/storage/profile_store.dart';
import 'package:vela/core/storage/secure_vault.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_vault_test');
    AppPaths.overrideSupportDir = tmp.path;
  });

  tearDown(() async {
    AppPaths.overrideSupportDir = null;
    await tmp.delete(recursive: true);
  });

  group('SecureVault', () {
    test('写入后落盘为密文，读回一致', () async {
      final vault = await SecureVault.open();
      const secret = 'https://sub.example.com/token?secret=abcdef123456';
      await vault.setString('sub', secret);

      // 磁盘上不能出现明文
      final raw = await File('${tmp.path}/vault.bin').readAsString();
      expect(raw.contains('example.com'), isFalse,
          reason: 'vault.bin 中不应包含明文订阅地址');

      // 读回一致（重开实例模拟重启）
      final vault2 = await SecureVault.open();
      expect(await vault2.readString('sub'), secret);
    });

    test('密钥文件权限 0600（unix）', () async {
      await SecureVault.open();
      if (!Platform.isWindows) {
        final r = await Process.run('stat', ['-f', '%Lp', '${tmp.path}/vault.key']);
        expect(r.stdout.toString().trim(), '600');
      }
    });

    test('明文迁移：KvStore 旧数据写入 vault 后明文被清除', () async {
      // 模拟旧版本：明文 KvStore 里存有 Profile
      final kv = await KvStore.open('${tmp.path}/profiles.json');
      final profile = Profile(
        id: 'p1',
        name: '测试配置',
        coreKind: CoreKind.mihomo,
        source: const ProfileSource(
            type: ProfileSourceType.subscription, url: 'https://sub.example.com/tok'),
      );
      await kv.setString('boxhub.profiles',
          jsonEncode([profile.toJson()]));
      expect(kv.getString('boxhub.profiles'), isNotNull);

      // 带 vault 的 store 首次 load：迁移
      final vault = await SecureVault.open();
      final store = ProfileStore(kv, vault: vault);
      await store.load();

      expect(store.listProfiles().map((p) => p.id), contains('p1'));
      // 明文已清除
      expect(kv.getString('boxhub.profiles'), isNull);
      final raw = await File('${tmp.path}/profiles.json').readAsString();
      expect(raw.contains('boxhub.profiles'), isFalse);
      // 密文存在
      expect(await vault.readString('boxhub.profiles'), isNotNull);
    });

    test('vault 路径下保存/删除走密文', () async {
      final kv = await KvStore.open('${tmp.path}/profiles.json');
      final vault = await SecureVault.open();
      final store = ProfileStore(kv, vault: vault);
      await store.load();

      final p = Profile(
          id: 'p2',
          name: '第二个',
          coreKind: CoreKind.singbox,
          source: const ProfileSource(type: ProfileSourceType.manual));
      await store.saveBase(p);
      expect(store.listProfiles().map((e) => e.id), contains('p2'));

      // 明文文件里没有 profiles 键（文件可能根本未创建）
      final plainFile = File('${tmp.path}/profiles.json');
      if (await plainFile.exists()) {
        expect((await plainFile.readAsString()).contains('p2'), isFalse);
      }

      await store.deleteBase('p2');
      expect(store.listProfiles().map((e) => e.id), isNot(contains('p2')));
    });
  });
}
