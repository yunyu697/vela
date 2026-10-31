/// 一键启停：跨页面共用的内核快捷操作。
///
/// 概览页 Hero 按钮与命令面板 / ⌘R 都走这里，保证行为一致：
///  - 未运行：选「上次运行的配置 → 最近使用 → 第一个」直接启动
///  - 运行中：停止
///
/// 返回给调用方一条可直接展示的提示消息（成功或失败原因）。
library;

import '../../core/ir/profile.dart';
import '../../core/platform/permissions.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/profile_repository.dart';
import 'core_manager.dart';

class CoreQuickActions {
  CoreQuickActions._();

  /// 切换内核运行状态，返回提示消息。
  static Future<String> toggle() async {
    final manager = CoreManager.instance;
    try {
      if (manager.isActive) {
        final name = manager.activeProfile?.name ?? '';
        await manager.stop();
        return '已停止「$name」';
      }
      return await startBest();
    } catch (e) {
      return '操作失败：$e';
    }
  }

  /// 用「最合适」的配置启动内核。
  static Future<String> startBest() async {
    final manager = CoreManager.instance;
    // 权限/平台预检：给出友好提示而不是裸异常文本
    final blocked = await VelaPermissions.canStartCore();
    if (blocked != null) return blocked;
    final repo = ProfileRepository.instance;
    await repo.init();
    final profiles = repo.profiles;
    if (profiles.isEmpty) return '还没有配置，先创建一个吧';

    // 优先上次运行的配置，其次最近使用，最后第一个
    final active = manager.activeProfile;
    final profile = profiles.where((p) => p.id == active?.id).firstOrNull ??
        _recentProfile(repo, profiles) ??
        profiles.first;

    try {
      await manager.start(profile, runDir: await AppPaths.supportDir());
      await repo.markUsed(profile.id);
      return '已启动「${profile.name}」';
    } catch (e) {
      return '启动失败：$e';
    }
  }

  /// 用指定配置启动（运行中先停止）。
  static Future<String> startProfile(Profile profile) async {
    final manager = CoreManager.instance;
    final blocked = await VelaPermissions.canStartCore();
    if (blocked != null) return blocked;
    final repo = ProfileRepository.instance;
    try {
      if (manager.isActive) await manager.stop();
      await manager.start(profile, runDir: await AppPaths.supportDir());
      await repo.markUsed(profile.id);
      return '已启动「${profile.name}」';
    } catch (e) {
      return '启动失败：$e';
    }
  }

  static Profile? _recentProfile(
      ProfileRepository repo, List<Profile> profiles) {
    Profile? best;
    DateTime? bestAt;
    for (final p in profiles) {
      final at = repo.metaOf(p.id).lastUsedAt;
      if (at != null && (bestAt == null || at.isAfter(bestAt))) {
        best = p;
        bestAt = at;
      }
    }
    return best;
  }
}
