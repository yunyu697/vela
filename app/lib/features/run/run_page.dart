/// 运行页：选择 Profile → 启停内核 → 状态 / 流量 / 连接表。
///
/// 布局自适应：
///  - 宽屏：左侧控制台（配置 + 内核 + 启停）+ 右侧实时仪表盘
///  - 中屏 / 窄屏：上下堆叠，控制台在上
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cores/core_adapter.dart';
import '../../core/ir/profile.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/profile_repository.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';
import 'core_manager.dart';

class RunPage extends StatefulWidget {
  const RunPage({super.key, this.initialProfileId});

  /// 从向导「完成」跳转时预选的 Profile。
  final String? initialProfileId;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final _repo = ProfileRepository.instance;

  List<Profile> _profiles = [];
  String? _selectedId;
  StatsSnapshot? _latestStats;
  List<ConnectionInfo> _connections = [];
  Timer? _refreshTimer;
  StreamSubscription<StatsSnapshot>? _statsSub;
  String? _startError;

  CoreManager get _manager => CoreManager.instance;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialProfileId;
    _manager.addListener(_onCoreChanged);
    _repo.addListener(_onRepoChanged);
    _repo.init().then((_) => _load());
  }

  void _onRepoChanged() {
    if (!mounted) return;
    setState(() {
      _profiles = _repo.profiles;
      if (_selectedId == null ||
          !_profiles.any((p) => p.id == _selectedId)) {
        _selectedId = _profiles.firstOrNull?.id;
      }
    });
  }

  Future<void> _load() async {
    // 等待仓库就绪（内部只读一次磁盘），避免页面各自解析全量配置。
    await _repo.init();
    if (!mounted) return;
    setState(() {
      _profiles = _repo.profiles;
      if (_selectedId == null ||
          !_profiles.any((p) => p.id == _selectedId)) {
        _selectedId = _profiles.firstOrNull?.id;
      }
    });
    _subscribeStats();
  }

  void _onCoreChanged() {
    if (!mounted) return;
    setState(() {});
    _subscribeStats();
  }

  void _subscribeStats() {
    _statsSub?.cancel();
    _latestStats = null;
    final stream = _manager.stats;
    if (stream == null) return;
    _statsSub = stream.listen((s) {
      if (!mounted) return;
      setState(() => _latestStats = s);
    });
  }

  Future<void> _start() async {
    final profile = _profiles.where((p) => p.id == _selectedId).firstOrNull;
    if (profile == null) return;
    setState(() => _startError = null);
    try {
      await _manager.start(profile, runDir: await AppPaths.supportDir());
      await _repo.markUsed(profile.id);
      _startAutoRefresh();
    } catch (e) {
      if (mounted) setState(() => _startError = e.toString());
    }
  }

  Future<void> _stop() async {
    _refreshTimer?.cancel();
    try {
      await _manager.stop();
    } catch (e) {
      if (mounted) setState(() => _startError = e.toString());
    }
  }

  Profile? get _selectedProfile =>
      _profiles.where((p) => p.id == _selectedId).firstOrNull;

  /// 运行中：热切换内核（停止 → 换编译器 → 重启）；未运行：改待启动内核。
  Future<void> _switchCore(CoreKind kind) async {
    setState(() => _startError = null);
    try {
      if (_manager.isActive) {
        await _manager.switchCore(kind);
      } else {
        final profile = _selectedProfile;
        if (profile != null) {
          // 持久化内核选择，下次启动用新内核
          await _repo.saveProfile(profile.copyWith(coreKind: kind));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _startError = '切换内核失败: $e');
    }
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_manager.isActive) return;
      try {
        final conns = await _manager.connections();
        if (mounted) setState(() => _connections = conns);
      } catch (_) {}
    });
  }

  static String _fmtBps(int bps) {
    if (bps >= 1 << 20) return '${(bps / (1 << 20)).toStringAsFixed(1)}MB/s';
    if (bps >= 1 << 10) return '${(bps / (1 << 10)).toStringAsFixed(0)}KB/s';
    return '$bps B/s';
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    return '$bytes B';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _statsSub?.cancel();
    _manager.removeListener(_onCoreChanged);
    _repo.removeListener(_onRepoChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    final padding = EdgeInsets.fromLTRB(
      scope.size.isCompact ? Insets.lg : Insets.xxl,
      scope.size.isCompact ? Insets.lg : Insets.xxl,
      scope.size.isCompact ? Insets.lg : Insets.xxl,
      Insets.xxl,
    );

    if (_profiles.isEmpty) {
      return Column(
        children: [
          Padding(
            padding: padding,
            child: const PageHeading(
              title: '运行',
              subtitle: '启动内核并实时监控流量与连接',
            ),
          ),
          const Expanded(
            child: EmptyState(
              icon: Icons.play_circle_outline_rounded,
              title: '还没有可运行的配置',
              message: '先在「配置」页创建一个配置，或用向导快速生成一份。',
            ),
          ),
        ],
      );
    }

    final control = _buildConsole(context, scope);
    final dashboard = _buildDashboard(context, scope);

    return Column(
      children: [
        Padding(
          padding: padding,
          child: PageHeading(
            title: '运行',
            subtitle: _manager.activeProfile != null
                ? '当前：${_manager.activeProfile!.name}'
                : '选择配置并启动内核',
            trailing: _buildStatusPill(context),
          ),
        ),
        Expanded(
          child: scope.size.isTwoPane
              // 宽屏：左右双栏
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 380,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          scope.size.isCompact ? Insets.lg : Insets.xxl,
                          0,
                          Insets.lg,
                          Insets.xxl,
                        ),
                        child: control,
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          Insets.lg,
                          0,
                          scope.size.isCompact ? Insets.lg : Insets.xxl,
                          Insets.xxl,
                        ),
                        child: dashboard,
                      ),
                    ),
                  ],
                )
              // 窄屏 / 中屏：上下堆叠
              : SingleChildScrollView(
                  padding: padding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      control,
                      const SizedBox(height: Insets.lg),
                      dashboard,
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildStatusPill(BuildContext context) {
    final status = _manager.status;
    final (color, label) = switch (status.kind) {
      CoreStatusKind.running => (VelaColors.emerald, '运行中'),
      CoreStatusKind.starting => (VelaColors.amber, '启动中'),
      CoreStatusKind.stopping => (VelaColors.amber, '停止中'),
      CoreStatusKind.error => (VelaColors.rose, '异常'),
      CoreStatusKind.stopped => (VelaColors.azure, '已停止'),
    };
    return StatusPill(
      label: label,
      color: color,
      pulsing: status.kind == CoreStatusKind.running,
    );
  }

  // ------------------------------------------------------------ 控制台

  Widget _buildConsole(BuildContext context, AdaptiveScope scope) {
    final theme = Theme.of(context);
    final active = _manager.isActive;
    final selected = _selectedProfile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VelaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: '控制台',
                subtitle: '选择配置、内核并启停',
                icon: Icons.tune_rounded,
              ),
              const SizedBox(height: Insets.lg),
              DropdownButtonFormField<String>(
                initialValue: _selectedId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '配置',
                  prefixIcon: Icon(Icons.folder_special_outlined),
                ),
                items: [
                  for (final p in _profiles)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: active ? null : (v) => setState(() => _selectedId = v),
              ),
              const SizedBox(height: Insets.lg),
              Text('内核', style: theme.textTheme.labelLarge),
              const SizedBox(height: Insets.sm),
              _buildCoreSwitch(context, active),
              const SizedBox(height: Insets.lg),
              SizedBox(
                width: double.infinity,
                child: active
                    ? OutlinedButton.icon(
                        onPressed: _stop,
                        icon: const Icon(Icons.stop_rounded, size: 19),
                        label: const Text('停止'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          side: BorderSide(
                            color: theme.colorScheme.error.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : VelaGradientButton(
                        label: '启动内核',
                        icon: Icons.play_arrow_rounded,
                        expand: true,
                        onPressed: selected == null ? null : _start,
                      ),
              ),
              if (_startError != null) ...[
                const SizedBox(height: Insets.md),
                Container(
                  padding: const EdgeInsets.all(Insets.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: Border.all(
                      color: theme.colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 17, color: theme.colorScheme.error),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          _startError!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoreSwitch(BuildContext context, bool active) {
    final theme = Theme.of(context);
    final current = _manager.activeProfile?.coreKind ??
        _selectedProfile?.coreKind ??
        CoreKind.mihomo;

    Widget tile(CoreKind kind, String label, String desc, IconData icon, Color color) {
      final selected = current == kind;
      return Expanded(
        child: Material(
          color: selected
              ? color.withValues(alpha: 0.12)
              : theme.colorScheme.surfaceContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => _switchCore(kind),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.md,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: selected ? color : theme.colorScheme.outlineVariant,
                  width: selected ? 1.6 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(icon,
                          size: 18,
                          color: selected
                              ? color
                              : theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: Insets.xs),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: selected ? color : null,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile(CoreKind.mihomo, 'mihomo', '协议最全', Icons.hub_outlined,
            VelaColors.violet),
        const SizedBox(width: Insets.sm),
        tile(CoreKind.singbox, 'sing-box', '性能更优', Icons.bolt_rounded,
            VelaColors.azure),
      ],
    );
  }

  // ------------------------------------------------------------ 仪表盘

  Widget _buildDashboard(BuildContext context, AdaptiveScope scope) {
    final theme = Theme.of(context);
    final stats = _latestStats;

    final statTiles = [
      StatTile(
        icon: Icons.download_rounded,
        label: '实时下载',
        value: stats == null ? '—' : _fmtBps(stats.downBps),
        gradient: VelaColors.coolGradient,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.upload_rounded,
        label: '实时上传',
        value: stats == null ? '—' : _fmtBps(stats.upBps),
        iconColor: VelaColors.emerald,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.data_usage_rounded,
        label: '累计流量',
        value: stats == null
            ? '—'
            : '${_fmtBytes(stats.totalDown)} ↓ / ${_fmtBytes(stats.totalUp)} ↑',
        iconColor: VelaColors.amber,
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.alt_route_rounded,
        label: '活动连接',
        value: '${_connections.length}',
        iconColor: VelaColors.violet,
        compact: scope.size.isCompact,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: '实时仪表盘',
          subtitle: '流量与连接统计',
          icon: Icons.speed_rounded,
        ),
        const SizedBox(height: Insets.lg),
        LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth >= 720 ? 4 : (c.maxWidth >= 380 ? 2 : 1);
            const gap = Insets.sm;
            final w = (c.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final t in statTiles)
                  SizedBox(width: w, child: t),
              ],
            );
          },
        ),
        const SizedBox(height: Insets.xl),
        Row(
          children: [
            Expanded(
              child: Text(
                '连接（${_connections.length}）',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (_manager.isActive)
              const StatusPill(
                label: '实时刷新',
                color: VelaColors.emerald,
                pulsing: true,
              ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        if (_connections.isEmpty)
          VelaCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.xl,
              vertical: Insets.xxl,
            ),
            child: Column(
              children: [
                Icon(
                  Icons.travel_explore_rounded,
                  size: 30,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(height: Insets.md),
                Text(
                  '暂无活动连接',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  '启动内核并产生流量后，这里会实时显示域名、命中规则与出入站链路。',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          VelaCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < _connections.take(40).length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
                  _ConnectionTile(connection: _connections[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.connection});

  final ConnectionInfo connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: (connection.network == 'udp'
                      ? VelaColors.amber
                      : VelaColors.azure)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Icon(
              connection.network == 'udp'
                  ? Icons.blur_on_rounded
                  : Icons.swap_vert_rounded,
              size: 16,
              color: connection.network == 'udp'
                  ? VelaColors.amber
                  : VelaColors.azure,
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  connection.destination,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${connection.rule.isEmpty ? '-' : connection.rule}'
                  ' · ${connection.chain.join(' → ')}'
                  ' · ↑${_fmtBytes(connection.upload)} ↓${_fmtBytes(connection.download)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
