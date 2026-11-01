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
  const RunPage({
    super.key,
    this.initialProfileId,
    @visibleForTesting this.debugConnections,
  });

  /// 从向导「完成」跳转时预选的 Profile。
  final String? initialProfileId;

  /// 仅测试用：预置连接表。
  ///
  /// 连接数据要靠真实内核跑起来才有，黄金图否则只能截到空状态，
  /// 「窄屏下连接行的密度与截断」这类排版问题就永远没人看得见。
  @visibleForTesting
  final List<ConnectionInfo>? debugConnections;

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
    _connections = widget.debugConnections ?? const [];
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
    final pad = scope.size.isCompact ? Insets.pageCompact : Insets.page;
    final padding = EdgeInsets.fromLTRB(pad, pad, pad, Insets.xxl);

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
                      width: 340,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          pad,
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
                          pad,
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
    final brightness = Theme.of(context).brightness;
    final (color, label) = switch (status.kind) {
      CoreStatusKind.running => (VelaColors.emerald, '运行中'),
      CoreStatusKind.starting => (VelaColors.amber, '启动中'),
      CoreStatusKind.stopping => (VelaColors.amber, '停止中'),
      CoreStatusKind.error => (VelaColors.rose, '异常'),
      CoreStatusKind.stopped => (VelaColors.azure, '已停止'),
    };
    return StatusPill(
      label: label,
      color: VelaColors.resolve(color, brightness),
      pulsing: status.kind == CoreStatusKind.running,
    );
  }

  // ------------------------------------------------------------ 控制台

  Widget _buildConsole(BuildContext context, AdaptiveScope scope) {
    final theme = Theme.of(context);
    final active = _manager.isActive;
    final selected = _selectedProfile;

    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: '控制台',
            subtitle: '选择配置与内核，然后启动',
          ),
          const SizedBox(height: Insets.lg),
          DropdownButtonFormField<String>(
            initialValue: _selectedId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '配置'),
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
          Text(
            '内核',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          _buildCoreSwitch(context, active),
          const SizedBox(height: Insets.lg),
          if (active)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: const Text('停止'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(
                    color: theme.colorScheme.error.withValues(alpha: 0.4),
                  ),
                ),
              ),
            )
          else
            VelaPrimaryButton(
              label: '启动内核',
              icon: Icons.play_arrow_rounded,
              expand: true,
              onPressed: selected == null ? null : _start,
            ),
          if (_startError != null) ...[
            const SizedBox(height: Insets.md),
            Container(
              padding: const EdgeInsets.all(Insets.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: theme.colorScheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 16, color: theme.colorScheme.error),
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
    );
  }

  Widget _buildCoreSwitch(BuildContext context, bool active) {
    final theme = Theme.of(context);
    final current = _manager.activeProfile?.coreKind ??
        _selectedProfile?.coreKind ??
        CoreKind.mihomo;

    Widget option(CoreKind kind, String label, String hint) {
      final selected = current == kind;
      return Expanded(
        child: Tooltip(
          message: hint,
          child: Material(
            color: selected
                ? theme.colorScheme.surfaceContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _switchCore(kind),
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm + 2),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        option(CoreKind.mihomo, 'mihomo', '协议支持最广：SSR / Hysteria v1 等全兼容'),
        const SizedBox(width: Insets.sm),
        option(CoreKind.singbox, 'sing-box', '新协议跟进快，性能与内存表现优秀'),
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
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.upload_rounded,
        label: '实时上传',
        value: stats == null ? '—' : _fmtBps(stats.upBps),
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.data_usage_rounded,
        label: '累计流量',
        value: stats == null
            ? '—'
            : '${_fmtBytes(stats.totalDown)} ↓ ${_fmtBytes(stats.totalUp)} ↑',
        compact: scope.size.isCompact,
      ),
      StatTile(
        icon: Icons.alt_route_rounded,
        label: '活动连接',
        value: '${_connections.length}',
        compact: scope.size.isCompact,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '实时仪表盘', subtitle: '流量与连接统计'),
        const SizedBox(height: Insets.md),
        VelaCard(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.lg,
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth >= 640 ? 4 : (c.maxWidth >= 320 ? 2 : 1);
              const gap = Insets.md;
              final w = (c.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: Insets.lg,
                children: [
                  for (final t in statTiles) SizedBox(width: w, child: t),
                ],
              );
            },
          ),
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
              StatusPill(
                label: '实时刷新',
                color: VelaColors.resolve(VelaColors.emerald, theme.brightness),
                pulsing: true,
              ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        if (_connections.isEmpty)
          VelaCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.xl,
              vertical: Insets.xl,
            ),
            child: Column(
              children: [
                Icon(
                  Icons.swap_vert_rounded,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                const SizedBox(height: Insets.md),
                Text('暂无活动连接', style: theme.textTheme.titleSmall),
                const SizedBox(height: Insets.xs),
                Text(
                  '启动内核并产生流量后，这里会显示域名、命中规则与出入站链路。',
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
    final muted = theme.colorScheme.onSurfaceVariant;
    final chain =
        '${connection.rule.isEmpty ? '-' : connection.rule}'
        ' · ${connection.chain.join(' → ')}';

    return Tooltip(
      // 链路被省略号截断时还能看到完整值（桌面端悬停）。
      message: '${connection.destination}\n$chain',
      waitDuration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.md - 2,
        ),
        child: Row(
          children: [
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
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chain,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.md),
            // 流量单独成列右对齐：此前它接在链路后面，宽屏下埋在长句
            // 末尾、窄屏下必然折行，两边的数字都对不齐也没法扫。
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _TrafficText(
                  icon: '↑',
                  value: _fmtBytes(connection.upload),
                ),
                const SizedBox(height: 2),
                _TrafficText(
                  icon: '↓',
                  value: _fmtBytes(connection.download),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
  }
}

/// 连接行右侧的「↑ 128KB」小字。等宽数字保证上下两行右边缘对齐。
class _TrafficText extends StatelessWidget {
  const _TrafficText({required this.icon, required this.value});

  final String icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '$icon $value',
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: 11,
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
