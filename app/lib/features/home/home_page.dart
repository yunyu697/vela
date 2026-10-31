/// 概览页：品牌主视觉 + 运行状态 + 快捷入口 + 功能说明。
library;

import 'package:flutter/material.dart';

import '../../core/cores/core_adapter.dart';
import '../../core/ir/profile.dart';
import '../../core/storage/profile_repository.dart';
import '../run/core_manager.dart';
import '../run/core_quick_actions.dart';
import '../wizard/wizard_page.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.onOpenProfiles,
    required this.onOpenRun,
  });

  final VoidCallback onOpenProfiles;
  final VoidCallback onOpenRun;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _repo = ProfileRepository.instance;

  int _profileCount = 0;
  int _nodeCount = 0;
  bool _loaded = false;

  /// 一键启停进行中（按钮显示转圈并禁用）。
  bool _busyCore = false;

  @override
  void initState() {
    super.initState();
    CoreManager.instance.addListener(_onCoreChanged);
    _repo.addListener(_onRepoChanged);
    _repo.init().then((_) => _load());
  }

  void _onCoreChanged() {
    if (mounted) setState(() {});
  }

  void _onRepoChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final profiles = _repo.profiles;
    setState(() {
      _profileCount = profiles.length;
      _nodeCount = profiles.fold<int>(0, (sum, p) => sum + p.nodes.length);
      _loaded = true;
    });
  }

  @override
  void dispose() {
    CoreManager.instance.removeListener(_onCoreChanged);
    _repo.removeListener(_onRepoChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    final manager = CoreManager.instance;
    final status = manager.status;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        Insets.xxxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StaggeredEntrance(index: 0, child: _buildHero(context, status)),
              const SizedBox(height: Insets.xl),
              StaggeredEntrance(
                index: 1,
                child: _buildStatusRow(context, scope, status),
              ),
              const SizedBox(height: Insets.xl),
              StaggeredEntrance(
                index: 2,
                child: _buildQuickActions(context),
              ),
              const SizedBox(height: Insets.xl),
              StaggeredEntrance(
                index: 3,
                child: _buildFeatureGrid(context, scope),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context, CoreStatus status) {
    final theme = Theme.of(context);
    final scope = AdaptiveScope.of(context);
    return Container(
      padding: EdgeInsets.all(scope.size.isCompact ? Insets.xl : Insets.xxl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xxl),
        gradient: VelaColors.brandGradient,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.28),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: scope.size.isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heroBrand(context, crossAxisAlignment: CrossAxisAlignment.start),
                const SizedBox(height: Insets.lg),
                _heroActions(context, stretch: true),
              ],
            )
          : Row(
              children: [
                Expanded(child: _heroBrand(context)),
                const SizedBox(width: Insets.xl),
                _heroActions(context, stretch: false),
              ],
            ),
    );
  }

  Widget _heroBrand(BuildContext context, {CrossAxisAlignment? crossAxisAlignment}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: crossAxisAlignment ?? CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
              ),
              child: const Center(
                child: VelaLogoMark(size: 26, color: Colors.white),
              ),
            ),
            const SizedBox(width: Insets.md),
            Text(
              'Vela',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.lg),
        Text(
          '一站式双内核代理客户端',
          style: theme.textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          '引导式向导帮你生成配置，sing-box 与 mihomo 双内核随时热切换，'
          '内置规则集与 Lint 检查让分流一目了然。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.88),
            height: 1.55,
          ),
        ),
      ],
    );
  }

  Widget _heroActions(BuildContext context, {required bool stretch}) {
    final create = VelaGradientButton(
      label: '创建新配置',
      icon: Icons.auto_awesome_rounded,
      expand: stretch,
      foregroundColor: VelaColors.indigo,
      gradient: const LinearGradient(
        colors: [Colors.white, Color(0xFFE8E7FF)],
      ),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const WizardPage()),
      ),
    );

    // 一键启停：未运行直接启动最合适的配置；运行中一键停止。
    // 这是「操作繁琐」诉求的核心解法——不进运行页也能启停。
    final manager = CoreManager.instance;
    final isActive = manager.isActive;
    final toggle = _busyCore
        ? OutlinedButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: const Text('处理中…'),
            style: _toggleStyle,
          )
        : OutlinedButton.icon(
            onPressed: _onToggleCore,
            icon: Icon(
              isActive ? Icons.stop_rounded : Icons.bolt_rounded,
              size: 20,
            ),
            label: Text(isActive ? '停止内核' : '一键启动'),
            style: _toggleStyle,
          );

    if (stretch) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [create, const SizedBox(height: Insets.sm), toggle],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [create, const SizedBox(width: Insets.md), toggle],
    );
  }

  ButtonStyle get _toggleStyle => OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xl,
          vertical: Insets.lg,
        ),
      );

  Future<void> _onToggleCore() async {
    setState(() => _busyCore = true);
    final msg = await CoreQuickActions.toggle();
    if (!mounted) return;
    setState(() => _busyCore = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        width: 420,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Widget _buildStatusRow(
      BuildContext context, AdaptiveScope scope, CoreStatus status) {
    final manager = CoreManager.instance;
    final (color, label, icon) = switch (status.kind) {
      CoreStatusKind.running => (VelaColors.emerald, '运行中', Icons.check_circle),
      CoreStatusKind.starting => (VelaColors.amber, '启动中', Icons.pending),
      CoreStatusKind.stopping => (VelaColors.amber, '停止中', Icons.pending),
      CoreStatusKind.error => (VelaColors.rose, '异常', Icons.error_outline),
      CoreStatusKind.stopped => (VelaColors.azure, '已停止', Icons.pause_circle),
    };

    final tiles = [
      StatTile(
        icon: icon,
        label: '内核状态',
        value: label,
        iconColor: color,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.folder_special_outlined,
        label: '已保存配置',
        value: _loaded ? '$_profileCount' : '—',
        iconColor: VelaColors.violet,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.lan_outlined,
        label: '节点总数',
        value: _loaded ? '$_nodeCount' : '—',
        iconColor: VelaColors.azure,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.swap_horiz_rounded,
        label: '当前内核',
        value: manager.activeProfile?.coreKind == CoreKind.singbox
            ? 'sing-box'
            : 'mihomo',
        iconColor: VelaColors.amber,
        compact: scope.size.isCompact,
      ),
    ];

    // 窄屏纵向排列，其余横向等宽，保证对齐
    if (scope.size.isCompact) {
      return Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(height: Insets.sm),
            SizedBox(width: double.infinity, child: tiles[i]),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: Insets.md),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    final actions = [
      (
        icon: Icons.auto_awesome_rounded,
        title: '配置向导',
        desc: '七步生成配置：内核、来源、节点、规则、DNS、入站、检查',
        color: VelaColors.indigo,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const WizardPage()),
        ),
      ),
      (
        icon: Icons.folder_open_rounded,
        title: '配置管理',
        desc: '浏览、编辑、删除已保存的配置，支持覆盖补丁',
        color: VelaColors.violet,
        onTap: widget.onOpenProfiles,
      ),
      (
        icon: Icons.monitor_heart_outlined,
        title: '运行监控',
        desc: '实时流量、连接表、一键切换内核',
        color: VelaColors.emerald,
        onTap: widget.onOpenRun,
      ),
    ];

    if (scope.size.isCompact) {
      return Column(
        children: [
          for (final a in actions)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.md),
              child: _ActionCard(
                icon: a.icon,
                title: a.title,
                desc: a.desc,
                color: a.color,
                onTap: a.onTap,
              ),
            ),
        ],
      );
    }
    // IntrinsicHeight 让三张卡片等高（stretch 需要确定的高度），
    // 在竖向滚动视图内高度本身无界，必须先收敛。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: Insets.md),
            Expanded(
              child: _ActionCard(
                icon: actions[i].icon,
                title: actions[i].title,
                desc: actions[i].desc,
                color: actions[i].color,
                onTap: actions[i].onTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeatureGrid(BuildContext context, AdaptiveScope scope) {
    final features = [
      (
        Icons.bolt_rounded,
        '双内核热切换',
        'mihomo / sing-box 同源配置，一键互换，运行时无感重启。',
        VelaColors.amber,
      ),
      (
        Icons.rule_rounded,
        '12 组内置规则集',
        '国内直连、去广告、流媒体、AI、Telegram…一键勾选。',
        VelaColors.violet,
      ),
      (
        Icons.health_and_safety_outlined,
        'Lint 实时体检',
        'DNS 劫持风险、协议不兼容、规则为空即时提示。',
        VelaColors.rose,
      ),
      (
        Icons.devices_rounded,
        '全平台一致',
        'macOS / Windows / Linux / Android 共用同一套界面。',
        VelaColors.azure,
      ),
    ];

    final columns = scope.size.isCompact
        ? 1
        : (scope.size.isMedium ? 2 : 4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: '核心能力',
          subtitle: '为双内核代理场景设计的完整工具链',
          icon: Icons.auto_awesome_motion_rounded,
        ),
        const SizedBox(height: Insets.lg),
        LayoutBuilder(
          builder: (context, c) {
            const gap = Insets.md;
            final w = (c.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final f in features)
                  SizedBox(
                    width: w,
                    child: _FeatureCard(
                      icon: f.$1,
                      title: f.$2,
                      desc: f.$3,
                      color: f.$4,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.desc,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VelaCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Insets.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Icon(icon, size: 21, color: color),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(desc, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Icon(
            Icons.arrow_forward_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.desc,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String desc;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VelaCard(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: 0.22),
                  color.withValues(alpha: 0.08),
                ],
              ),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(height: Insets.md),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: Insets.xs),
          Text(desc, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
