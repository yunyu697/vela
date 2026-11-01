/// 概览页：当前状态 + 最近配置 + 两个入口动作。
///
/// 设计取向（相对上一版的重写）：
///  - 删掉整块渐变 Hero。它是营销位而不是工具界面：占掉首屏近三分之一
///    高度，却只重复了侧栏已有的「Vela」和一句 slogan。
///  - 删掉三张「配置向导 / 配置管理 / 运行监控」入口卡——这三个目的地
///    在左侧导航里已经各占一项，卡片是纯粹的功能重复。
///  - 删掉「核心能力」四宫格。产品自述不属于工具界面，用户第二次打开
///    就再也不会读它。
///  - 留下的是三样有用的东西：一眼可读的状态、最近的配置、两个动作。
library;

import 'package:flutter/material.dart';

import '../../core/cores/core_adapter.dart';
import '../../core/ir/profile.dart';
import '../../core/storage/profile_repository.dart';
import '../run/core_manager.dart';
import '../run/core_quick_actions.dart';
import '../wizard/wizard_page.dart';
import '../../ui/adaptive.dart';
import '../../ui/theme_toggle.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.onOpenProfiles,
    required this.onOpenRun,
    this.showCompactThemeToggle = false,
  });

  final VoidCallback onOpenProfiles;
  final VoidCallback onOpenRun;

  /// 紧凑布局下没有侧栏，主题切换入口放在页头右侧。
  final bool showCompactThemeToggle;

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
    final compact = scope.size.isCompact;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        compact ? Insets.pageCompact : Insets.page,
        compact ? Insets.pageCompact : Insets.page,
        compact ? Insets.pageCompact : Insets.page,
        Insets.xxxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, compact),
              const SizedBox(height: Insets.xl),
              _buildStatusCard(context, compact),
              const SizedBox(height: Insets.xl),
              _buildProfilesSection(context, compact),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 页头

  Widget _buildHeader(BuildContext context, bool compact) {
    final manager = CoreManager.instance;
    final active = manager.isActive;

    final create = VelaPrimaryButton(
      label: '新建配置',
      icon: Icons.add_rounded,
      tone: VelaButtonTone.quiet,
      expand: compact,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const WizardPage()),
      ),
    );

    final toggle = _busyCore
        ? VelaPrimaryButton(
            label: '处理中…',
            busy: true,
            expand: compact,
            onPressed: null,
          )
        : VelaPrimaryButton(
            label: active ? '停止内核' : '一键启动',
            icon: active ? Icons.stop_rounded : Icons.play_arrow_rounded,
            tone: active ? VelaButtonTone.quiet : VelaButtonTone.primary,
            expand: compact,
            onPressed: _onToggleCore,
          );

    final heading = PageHeading(
      title: '概览',
      subtitle: _summary(manager),
      trailing: compact && widget.showCompactThemeToggle
          ? const VelaThemeToggle(extended: false)
          : null,
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              Expanded(child: create),
              const SizedBox(width: Insets.sm),
              Expanded(child: toggle),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: heading),
        const SizedBox(width: Insets.lg),
        create,
        const SizedBox(width: Insets.sm),
        toggle,
      ],
    );
  }

  String _summary(CoreManager manager) {
    if (manager.isActive && manager.activeProfile != null) {
      final p = manager.activeProfile!;
      return '正在运行「${p.name}」· ${p.coreKind == CoreKind.singbox ? 'sing-box' : 'mihomo'}';
    }
    if (!_loaded) return '正在读取本地配置…';
    return '$_profileCount 份配置 · $_nodeCount 个节点';
  }

  // ------------------------------------------------------------------ 状态

  Widget _buildStatusCard(BuildContext context, bool compact) {
    final manager = CoreManager.instance;
    final status = manager.status;
    final theme = Theme.of(context);

    final (label, color) = switch (status.kind) {
      CoreStatusKind.running => ('运行中', VelaColors.emerald),
      CoreStatusKind.starting => ('启动中', VelaColors.amber),
      CoreStatusKind.stopping => ('停止中', VelaColors.amber),
      CoreStatusKind.error => ('异常', VelaColors.rose),
      CoreStatusKind.stopped => ('已停止', null),
    };

    final coreName = manager.activeProfile?.coreKind == CoreKind.singbox
        ? 'sing-box'
        : 'mihomo';

    final tiles = [
      StatTile(
        label: '状态',
        value: label,
        valueColor: color == null
            ? null
            : VelaColors.resolve(color, theme.brightness),
        compact: compact,
      ),
      StatTile(
        label: '配置',
        value: _loaded ? '$_profileCount' : '—',
        compact: compact,
      ),
      StatTile(
        label: '节点',
        value: _loaded ? '$_nodeCount' : '—',
        compact: compact,
      ),
      StatTile(label: '内核', value: coreName, compact: compact),
    ];

    return VelaCard(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? Insets.lg : Insets.xl,
        vertical: compact ? Insets.lg : Insets.lg + 4,
      ),
      child: compact
          ? LayoutBuilder(
              builder: (context, c) {
                const gap = Insets.lg;
                final w = (c.maxWidth - gap) / 2;
                return Wrap(
                  spacing: gap,
                  runSpacing: Insets.lg,
                  children: [
                    for (final t in tiles) SizedBox(width: w, child: t),
                  ],
                );
              },
            )
          : IntrinsicHeight(
              child: Row(
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    if (i > 0)
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(horizontal: Insets.lg),
                        color: theme.colorScheme.outlineVariant,
                      ),
                    Expanded(child: tiles[i]),
                  ],
                ],
              ),
            ),
    );
  }

  // ------------------------------------------------------------------ 配置

  Widget _buildProfilesSection(BuildContext context, bool compact) {
    final recent = _repo.filter(sort: ProfileSort.recent);
    final shown = recent.take(compact ? 3 : 4).toList();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: '配置',
          subtitle: recent.isEmpty ? null : '最近使用优先',
          trailing: TextButton(
            onPressed: widget.onOpenProfiles,
            child: const Text('全部'),
          ),
        ),
        const SizedBox(height: Insets.md),
        VelaCard(
          padding: EdgeInsets.zero,
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.xl,
                    vertical: Insets.xxl,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 26,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.7),
                      ),
                      const SizedBox(height: Insets.md),
                      Text('还没有配置', style: theme.textTheme.titleSmall),
                      const SizedBox(height: Insets.xs),
                      Text(
                        '用向导几步生成第一份配置：选内核、导入订阅、勾规则。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: Insets.lg),
                      VelaPrimaryButton(
                        label: '新建配置',
                        icon: Icons.add_rounded,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const WizardPage()),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant,
                        ),
                      _ProfileRow(
                        profile: shown[i],
                        name: _repo.metaOf(shown[i].id).displayName(shown[i]),
                        active: CoreManager.instance.activeProfile?.id ==
                            shown[i].id,
                        onTap: widget.onOpenProfiles,
                        onOpenRun: widget.onOpenRun,
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

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
}

/// 配置行：名称 + 元信息 + 内核标识。
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.name,
    required this.active,
    required this.onTap,
    required this.onOpenRun,
  });

  final Profile profile;
  final String name;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onOpenRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final core = profile.coreKind == CoreKind.singbox ? 'sing-box' : 'mihomo';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: Insets.sm),
                          StatusPill(
                            label: '运行中',
                            color: VelaColors.resolve(
                              VelaColors.emerald,
                              theme.brightness,
                            ),
                            pulsing: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${profile.nodes.length} 节点 · $core',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (active)
                IconButton(
                  onPressed: onOpenRun,
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                  tooltip: '前往运行页',
                  color: theme.colorScheme.onSurfaceVariant,
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
