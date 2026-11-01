/// Vela 应用外壳：主导航 + 页面切换 + 命令面板。
///
/// 导航形态随窗口宽度自动切换（侧栏 ↔ 图标栏 ↔ 底部栏），
/// 页面之间用 PageView 做淡入位移转场，页面状态在切换时保持。
///
/// 全局快捷键（⌘K / ⌘1-3 / ⌘R）定义在 [VelaShortcutLayer]
/// （main.dart 的 MaterialApp.builder 注入），本壳通过
/// [VelaShortcutBus] 注册动作。
library;

import 'package:flutter/material.dart';

import '../core/cores/core_adapter.dart';
import '../core/ir/profile.dart';
import '../core/platform/desktop_integrations.dart';
import '../core/settings/app_settings.dart';
import '../core/storage/kv_store.dart';
import '../core/storage/profile_repository.dart';
import '../features/run/core_manager.dart';
import '../features/run/core_quick_actions.dart';
import '../ui/adaptive.dart';
import '../ui/command_palette.dart';
import '../ui/theme_toggle.dart';
import '../ui/tokens.dart';
import '../ui/vela_shortcuts.dart';
import '../features/home/home_page.dart';
import '../features/profiles/profiles_page.dart';
import '../features/run/run_page.dart';
import '../features/settings/settings_page.dart';
import '../features/wizard/wizard_page.dart';

class VelaShell extends StatefulWidget {
  const VelaShell({super.key});

  @override
  State<VelaShell> createState() => _VelaShellState();
}

class _VelaShellState extends State<VelaShell> {
  int _index = 0;
  bool _busy = false;
  final _repo = ProfileRepository.instance;
  late final PageController _pageController =
      PageController(viewportFraction: 1.0);

  static const _destinations = [
    AdaptiveDestination(
      label: '概览',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard_rounded,
    ),
    AdaptiveDestination(
      label: '配置',
      icon: Icons.tune_outlined,
      selectedIcon: Icons.tune_rounded,
    ),
    AdaptiveDestination(
      label: '运行',
      icon: Icons.play_circle_outline_rounded,
      selectedIcon: Icons.play_circle_rounded,
    ),
    AdaptiveDestination(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    // 配置载入是「自动启动」与命令面板的共同前提，先等它就绪
    _repo.init().then((_) => _maybeAutoStart());
    final bus = VelaShortcutBus.instance;
    bus.onGoTab = _select;
    bus.onOpenPalette = _openPalette;
    bus.onToggleCore = _toggleCore;
    bus.onToggleTheme = _cycleTheme;
    // 桌面端系统集成（托盘 / 系统代理 / 开机自启）。fire-and-forget：
    // 初始化失败不影响主界面。
    DesktopIntegrations.instance.init().catchError((_) {});
  }

  /// 「启动时自动启动上次配置」。
  ///
  /// 只在用户主动打开这个开关后才跑；失败不弹模态框（启动瞬间弹窗打断
  /// 比不启动更烦），改用底部提示条说明原因。
  Future<void> _maybeAutoStart() async {
    if (!AppSettings.instance.autoStartLastProfile) return;
    final manager = CoreManager.instance;
    if (manager.isActive) return;
    final profiles = _repo.profiles;
    if (profiles.isEmpty) return;

    Profile? last;
    DateTime? best;
    for (final p in profiles) {
      final t = _repo.metaOf(p.id).lastUsedAt;
      if (t != null && (best == null || t.isAfter(best))) {
        best = t;
        last = p;
      }
    }
    final target = last ?? profiles.first;
    try {
      await manager.start(target, runDir: await AppPaths.supportDir());
      await _repo.markUsed(target.id);
    } catch (e) {
      if (!mounted) return;
      _toast('自动启动失败：${e is CoreStartException ? e.message : e}');
    }
  }

  @override
  void dispose() {
    VelaShortcutBus.instance.reset();
    _pageController.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: Motion.normal),
      curve: Curves.easeOutCubic,
    );
  }

  // ------------------------------------------------------------ 快捷键动作

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        width: 420,
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// ⌘R / 面板「启停」入口。
  Future<void> _toggleCore() =>
      _busy ? Future.value() : _runAction(CoreQuickActions.toggle);

  /// ⌘⇧D / 侧栏按钮：循环切换主题模式。
  Future<void> _cycleTheme() async {
    final settings = AppSettings.instance;
    await settings.cycleThemeMode();
    _toast('主题：${settings.themeMode.label}');
  }

  /// 面板里点某个配置：启动它（运行中先停止当前）。
  Future<void> _startProfile(Profile profile) => _busy
      ? Future.value()
      : _runAction(() => CoreQuickActions.startProfile(profile));

  Future<void> _runAction(Future<String> Function() action) async {
    setState(() => _busy = true);
    final msg = await action();
    if (mounted) setState(() => _busy = false);
    _toast(msg);
  }

  void _openWizard() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WizardPage()),
    );
  }

  void _openPalette() {
    showVelaCommandPalette(context, _buildCommands());
  }

  List<VelaCommand> _buildCommands() {
    final manager = CoreManager.instance;
    final commands = <VelaCommand>[
      VelaCommand(
        title: '前往概览',
        icon: Icons.dashboard_outlined,
        subtitle: '运行状态与快捷入口',
        shortcut: '⌘1',
        onRun: () => _select(0),
      ),
      VelaCommand(
        title: '前往配置',
        icon: Icons.tune_outlined,
        subtitle: '搜索、分组、导入导出配置',
        shortcut: '⌘2',
        onRun: () => _select(1),
      ),
      VelaCommand(
        title: '前往运行',
        icon: Icons.play_circle_outline_rounded,
        subtitle: '实时流量与连接监控',
        shortcut: '⌘3',
        onRun: () => _select(2),
      ),
      VelaCommand(
        title: '前往设置',
        icon: Icons.settings_outlined,
        subtitle: '外观、启动行为与数据位置',
        shortcut: '⌘4',
        onRun: () => _select(3),
      ),
      VelaCommand(
        title: '新建配置（向导）',
        icon: Icons.auto_awesome_rounded,
        subtitle: '七步引导生成配置',
        onRun: _openWizard,
      ),
    ];

    // 主题模式：三个模式各一条，当前模式在副标题里标注
    final currentMode = AppSettings.instance.themeMode;
    for (final mode in ThemeMode.values) {
      commands.add(VelaCommand(
        title: '主题：${mode.label}',
        icon: mode.icon,
        subtitle: mode == currentMode ? '当前模式' : '切换到${mode.label}',
        onRun: () async {
          await AppSettings.instance.setThemeMode(mode);
          _toast('主题：${mode.label}');
        },
      ));
    }

    // 内核控制
    if (manager.isActive) {
      commands.add(VelaCommand(
        title: '停止内核',
        subtitle: manager.activeProfile?.name ?? '',
        icon: Icons.stop_circle_outlined,
        shortcut: '⌘R',
        dangerous: true,
        onRun: _toggleCore,
      ));
      // 运行时热切换内核
      final kind = manager.activeProfile?.coreKind;
      final other = kind == CoreKind.singbox ? 'mihomo' : 'sing-box';
      commands.add(VelaCommand(
        title: '切换内核到 $other',
        subtitle: '停止当前内核并用 $other 重启同一配置',
        icon: Icons.swap_horiz_rounded,
        onRun: () async {
          try {
            await manager.switchCore(
              kind == CoreKind.singbox ? CoreKind.mihomo : CoreKind.singbox,
            );
            _toast('已切换到 $other');
          } catch (e) {
            _toast('切换失败：$e');
          }
        },
      ));
    } else {
      commands.add(VelaCommand(
        title: '启动内核',
        subtitle: '使用最近使用的配置',
        icon: Icons.play_arrow_rounded,
        shortcut: '⌘R',
        onRun: _toggleCore,
      ));
    }

    // 每个配置一个直接启动入口（排除正在运行的）
    final activeId = manager.activeProfile?.id;
    for (final p in _repo.profiles) {
      if (p.id == activeId) continue;
      commands.add(VelaCommand(
        title: '启动「${p.name}」',
        subtitle:
            '${p.coreKind == CoreKind.singbox ? 'sing-box' : 'mihomo'} · ${p.nodes.length} 节点',
        icon: Icons.rocket_launch_outlined,
        onRun: () => _startProfile(p),
      ));
    }
    return commands;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveBuilder(
      builder: (context, scope) {
        return AdaptiveScaffold(
          destinations: _destinations,
          selectedIndex: _index,
          onDestinationSelected: _select,
          background: const VelaBackdrop(),
          footer: VelaThemeToggle(
            extended: scope.size == WindowSize.wide ||
                scope.size == WindowSize.expanded,
          ),
          body: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              HomePage(
                onOpenProfiles: () => _select(1),
                onOpenRun: () => _select(2),
                // 紧凑布局没有侧栏，主题入口改由概览页 Hero 承担
                showCompactThemeToggle: scope.size.isCompact,
              ),
              ProfilesPage(onOpenRun: () => _select(2)),
              const RunPage(),
              const SettingsPage(),
            ],
          ),
        );
      },
    );
  }
}
