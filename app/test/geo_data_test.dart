/// GeoIP 预置逻辑测试。
///
/// 这里只测「是否重复下载」和「损坏文件是否重下」这类本地判断：
/// 真实下载走网络，在测试里由 flutter_test 的 HttpClient 桩拦成 400，
/// 因此下载分支天然是「失败」路径，正好覆盖「失败不抛异常」的契约。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/cores/geo_data.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vela_geo_test');
  });

  tearDown(() async {
    GeoData.downloadOverride = null;
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('已存在且体积正常时不重复下载', () async {
    final file = File('${dir.path}/${GeoData.fileName}');
    await file.writeAsBytes(List<int>.filled(GeoData.minBytes + 1024, 7));
    final before = (await file.stat()).modified;

    expect(await GeoData.ensureMihomoGeoIp(dir.path), isTrue);

    final after = (await file.stat()).modified;
    expect(
      after,
      before,
      reason: '文件已就绪时不该再联网，也不该改写文件',
    );
  });

  test('体积不足的文件视为损坏并尝试重下（失败时返回 false 且不抛异常）', () async {
    GeoData.downloadOverride = () async => null; // 模拟下载失败
    final file = File('${dir.path}/${GeoData.fileName}');
    await file.writeAsBytes(List<int>.filled(1024, 0));

    final ok = await GeoData.ensureMihomoGeoIp(dir.path);

    expect(ok, isFalse, reason: '下载失败应返回 false 而不是假装成功');
    expect(
      await file.length(),
      1024,
      reason: '下载失败不能破坏原文件（先写临时文件再 rename）',
    );
  });

  test('下载成功时原子写入并返回 true', () async {
    final payload = List<int>.filled(GeoData.minBytes + 1, 3);
    GeoData.downloadOverride = () async => payload;

    expect(await GeoData.ensureMihomoGeoIp(dir.path), isTrue);
    final file = File('${dir.path}/${GeoData.fileName}');
    expect(await file.length(), payload.length);
    expect(
      File('${dir.path}/.${GeoData.fileName}.tmp').existsSync(),
      isFalse,
      reason: '临时文件必须被 rename 掉，不能留在目录里',
    );
  });

  test('下载体积不足视为失败', () async {
    GeoData.downloadOverride = () async => List<int>.filled(64, 0);
    expect(await GeoData.ensureMihomoGeoIp(dir.path), isFalse);
  });

  test('工作目录不存在时自动创建', () async {
    GeoData.downloadOverride = () async => null;
    final nested = '${dir.path}/a/b/c';
    final ok = await GeoData.ensureMihomoGeoIp(nested);
    expect(ok, isFalse);
    expect(Directory(nested).existsSync(), isTrue);
  });
}
