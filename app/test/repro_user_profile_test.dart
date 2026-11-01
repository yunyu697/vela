// 复现用户 GUI 中「点击启动报错」的真实场景：
// 从应用容器读取保存的 Profile → 编译 → FFI 启动真实内核。
// 注意：纯 Dart 测试，不要 TestWidgetsFlutterBinding。
import 'dart:convert';
import 'dart:io';

import 'package:vela/core/compiler/mihomo_compiler.dart';
import 'package:vela/core/cores/core_adapter.dart';
import 'package:vela/core/cores/mihomo_adapter.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('复现：用户保存的 Profile 启动', () async {
    final kvFile = File(
        '${Platform.environment['HOME']}/Library/Containers/'
        'dev.boxhub.boxhub/Data/Library/Application Support/'
        'dev.boxhub.boxhub/profiles.json');
    if (!kvFile.existsSync()) {
      markTestSkipped('未找到用户 profiles.json');
      return;
    }
    final kv =
        (jsonDecode(kvFile.readAsStringSync()) as Map).cast<String, Object?>();
    // 该文件是**真实用户数据**，键是否存在取决于本机应用当前状态：
    // 只写了 profileMeta（配置列表为空/被清空）时没有 boxhub.profiles，
    // 直接强转会在测试里抛 Null cast，看起来像代码 bug。这里退化为跳过。
    final rawList = kv['boxhub.profiles'];
    if (rawList is! String) {
      markTestSkipped('用户 profiles.json 中没有配置列表（只有元数据）');
      return;
    }
    final list = jsonDecode(rawList) as List;
    if (list.isEmpty) {
      markTestSkipped('用户 profiles.json 为空（尚未保存任何配置）');
      return;
    }
    final raw = list.first as Map<Object?, Object?>;
    final profile = Profile.fromJson(raw.cast<String, Object?>());
    stdout.writeln('profile: ${profile.name}, nodes: ${profile.nodes.length}, '
        'rules: ${profile.rules.length}');

    final yaml = const MihomoCompiler().compileToString(profile);
    File('/tmp/boxhub_repro/config.yaml')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(yaml);
    stdout.writeln('--- compiled config head ---');
    stdout.writeln(yaml.split('\n').take(40).join('\n'));

    final adapter = MihomoAdapter();
    try {
      await adapter.start(CoreRunRequest(
        profile: profile,
        configFile: '/tmp/boxhub_repro/config.yaml',
        workDir: '/tmp/boxhub_repro/work',
        controllerSocketPath: '/tmp/boxhub_repro/mihomo.sock',
      ));
      stdout.writeln('>>> START OK');
      await adapter.stop();
    } catch (e, st) {
      stdout.writeln('>>> START FAILED: $e');
      stdout.writeln(st.toString());
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
