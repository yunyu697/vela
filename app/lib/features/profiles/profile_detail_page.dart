/// 配置详情页：看这份配置到底装了什么，并在运行中做两件事——
/// 测节点延迟、切手动分组的出口。
///
/// 为什么需要它：配置卡只显示「4 节点 / 3 分组 / 3 规则」四个数字，
/// 用户既看不到节点清单，也无法判断哪个节点是通的。而 `testDelay` 与
/// `selectOutbound` 从适配器一路实现到 CoreManager，界面里一次都没调用过。
///
/// 设计取向：只读为主。这里不做增删改——编辑走向导，重命名 / 标签走
/// 配置卡菜单，把两套编辑入口摆在一起只会让用户不知道改哪边生效。
library;

import 'package:flutter/material.dart';

import '../../core/ir/profile.dart';
import '../../core/storage/profile_repository.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';
import '../run/core_manager.dart';

/// 一次最多直接渲染的节点行数。
///
/// 机场订阅动辄上百个节点，全部铺出来会把页面变成一条无尽列表，
/// 也让首帧变慢；超过这个数先折叠，用户真要找再展开。
const int _nodeRowLimit = 30;

/// 测速并发数。
///
/// 串行测 100 个节点（每个最多 5s 超时）要好几分钟；全并发又会把内核
/// 的探测连接打满，反而集体超时。4 路是「明显更快且不把内核打爆」的折中。
const int _delayConcurrency = 4;

class ProfileDetailPage extends StatefulWidget {
  const ProfileDetailPage({
    super.key,
    required this.profileId,
    @visibleForTesting this.debug,
  });

  final String profileId;

  /// 仅测试用：钉住「是否在运行 / 延迟结果 / 分组当前出口」。
  ///
  /// 这三样都来自真跑起来的内核（clash API），没有这个入口，页面在测试
  /// 里永远停在「已停止 + 全部未测」，等于没被验证过。
  @visibleForTesting
  final ProfileDetailDebug? debug;

  @override
  State<ProfileDetailPage> createState() => _ProfileDetailPageState();
}

/// 仅测试用：见 [ProfileDetailPage.debug]。
@visibleForTesting
class ProfileDetailDebug {
  const ProfileDetailDebug({
    this.runningProfileId,
    this.delays = const {},
    this.selection = const {},
  });

  /// 非 null 视为「这份配置正在运行」。
  final String? runningProfileId;

  /// 节点 id → 延迟毫秒（null 表示超时）。
  final Map<String, int?> delays;

  /// 分组 id → 当前出口名。
  final Map<String, String> selection;
}

class _ProfileDetailPageState extends State<ProfileDetailPage> {
  final _repo = ProfileRepository.instance;
  final _manager = CoreManager.instance;

  /// 节点 id → 延迟（null = 超时）。
  final Map<String, int?> _delays = {};

  /// 正在测的节点 id。
  final Set<String> _testing = {};

  /// 分组 id → 当前出口名。
  final Map<String, String> _selection = {};

  bool _testingAll = false;
  bool _showAllNodes = false;

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepoChanged);
    _manager.addListener(_onCoreChanged);
    // 幂等：不依赖「谁先打开配置页」决定这里能不能读到数据
    _repo.init();
    _delays.addAll(widget.debug?.delays ?? const {});
    _selection.addAll(widget.debug?.selection ?? const {});
    // 当前出口要从内核问，不能靠猜
    if (widget.debug == null) _loadSelection();
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    _manager.removeListener(_onCoreChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  void _onCoreChanged() {
    if (!mounted) return;
    setState(() {});
    // 内核刚启动 → 补问一次当前出口；刚停止 → 延迟结果全部作废
    if (_isRunningHere) {
      if (widget.debug == null) _loadSelection();
    } else {
      _delays.clear();
    }
  }

  // ------------------------------------------------------------ 数据读取

  Profile? get _profile {
    for (final p in _repo.profiles) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  String? get _runningProfileId =>
      widget.debug?.runningProfileId ?? _manager.activeProfile?.id;

  /// 这份配置是不是就是当前在跑的那份。
  ///
  /// 测速与切换都是「按名字问运行中的内核」，跑的若是别的配置，节点名
  /// 对不上，问出来必然是超时——那比不给按钮更糟。
  bool get _isRunningHere => _runningProfileId == widget.profileId;

  Future<void> _loadSelection() async {
    final p = _profile;
    if (p == null || !_isRunningHere) return;
    for (final g in p.groups) {
      if (g.type != ProxyGroupType.select) continue;
      final now = await _manager.currentOutbound(g.name);
      if (!mounted) return;
      if (now != null) setState(() => _selection[g.id] = now);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------ 测延迟

  Future<void> _testAll() async {
    final p = _profile;
    if (p == null || _testingAll || !_isRunningHere) return;
    setState(() {
      _testingAll = true;
      _delays.clear();
    });

    var cursor = 0;
    Future<void> worker() async {
      while (cursor < p.nodes.length) {
        final node = p.nodes[cursor++];
        if (!mounted) return;
        setState(() => _testing.add(node.id));
        final ms = await _manager.testDelay(node.name);
        if (!mounted) return;
        setState(() {
          _testing.remove(node.id);
          _delays[node.id] = ms;
        });
      }
    }

    await Future.wait([
      for (var i = 0; i < _delayConcurrency; i++) worker(),
    ]);
    if (mounted) setState(() => _testingAll = false);
  }

  // ------------------------------------------------------------ 切出口

  /// 把分组成员解析成「能直接交给内核的名字」。
  ///
  /// 成员可能是节点 id、`region:关键词` 过滤器，或另一个分组——内核只认
  /// 名字，所以这里统一翻成名字并去重。
  List<String> _resolveMembers(Profile p, ProxyGroup g) {
    final out = <String>[];
    void add(String name) {
      if (!out.contains(name)) out.add(name);
    }

    for (final m in g.members) {
      if (m.startsWith('region:')) {
        final kw = m.substring('region:'.length);
        for (final n in p.nodes) {
          if (n.name.contains(kw)) add(n.name);
        }
        continue;
      }
      var matched = false;
      for (final n in p.nodes) {
        if (n.id == m) {
          add(n.name);
          matched = true;
          break;
        }
      }
      if (matched) continue;
      for (final sub in p.groups) {
        if (sub.id == m) {
          add(sub.name);
          break;
        }
      }
    }
    return out;
  }

  Future<void> _pickOutbound(Profile p, ProxyGroup g) async {
    final members = _resolveMembers(p, g);
    if (members.isEmpty) {
      _toast('这个分组没有可选成员');
      return;
    }
    final current = _selection[g.id];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _OutboundSheet(
        title: g.name,
        members: members,
        current: current,
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await _manager.selectOutbound(g.name, picked);
      if (!mounted) return;
      setState(() => _selection[g.id] = picked);
      _toast('已切换到「$picked」');
    } catch (e) {
      if (!mounted) return;
      _toast('切换失败：${e is StateError ? e.message : e}');
    }
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    if (p == null) {
      // 配置被删掉（另一个页面删的）——不要留一个空壳页
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(child: VelaBackdrop()),
            SafeArea(
              child: EmptyState(
                icon: Icons.inbox_outlined,
                title: '配置已不存在',
                message: '它可能在别的页面被删除了。',
                action: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回'),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final scope = AdaptiveScope.of(context);
    final pad = scope.size.isCompact ? Insets.pageCompact : Insets.page;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: VelaBackdrop()),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(context, scope, p),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(pad, Insets.lg, pad, Insets.xxxl),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSummaryCard(context, p),
                            const SizedBox(height: Insets.lg),
                            _buildNodesCard(context, p),
                            const SizedBox(height: Insets.lg),
                            _buildGroupsCard(context, p),
                            const SizedBox(height: Insets.lg),
                            _buildRulesCard(context, p),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, AdaptiveScope scope, Profile p) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        scope.size.isCompact ? Insets.sm : Insets.lg,
        Insets.sm,
        scope.size.isCompact ? Insets.md : Insets.page,
        Insets.sm,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            tooltip: '返回',
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${p.coreKind == CoreKind.singbox ? 'sing-box' : 'mihomo'}'
                  ' · ${p.nodes.length} 节点 · ${p.groups.length} 分组',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          StatusPill(
            label: _isRunningHere ? '运行中' : '已停止',
            color: _isRunningHere
                ? VelaColors.resolve(VelaColors.emerald, theme.brightness)
                : theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, Profile p) {
    final meta = _repo.metaOf(p.id);
    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: '概览'),
          const SizedBox(height: Insets.sm),
          InfoRow(
            label: '来源',
            value: switch (p.source.type) {
              ProfileSourceType.subscription => '订阅',
              ProfileSourceType.links => '分享链接',
              ProfileSourceType.manual => '手动创建',
              ProfileSourceType.file => '本地文件',
            },
          ),
          if (meta.syncedAt != null)
            InfoRow(label: '上次更新', value: _ago(meta.syncedAt!)),
          InfoRow(label: '规则', value: '${p.rules.length} 条'),
          InfoRow(label: 'DNS', value: p.dns.mode.label, monospace: true),
          InfoRow(label: '入站', value: p.inbound.mode.label, monospace: true),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 节点

  Widget _buildNodesCard(BuildContext context, Profile p) {
    final theme = Theme.of(context);
    final nodes = _showAllNodes ? p.nodes : p.nodes.take(_nodeRowLimit).toList();
    final hidden = p.nodes.length - nodes.length;

    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: '节点',
            subtitle: _isRunningHere
                ? '共 ${p.nodes.length} 个 · 点「测速」探测当前延迟'
                : '共 ${p.nodes.length} 个 · 启动这份配置后才能测速',
            trailing: TextButton.icon(
              onPressed: _isRunningHere && !_testingAll ? _testAll : null,
              icon: _testingAll
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  : const Icon(Icons.speed_rounded, size: 16),
              label: const Text('测速'),
            ),
          ),
          if (p.nodes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.lg),
              child: Text('这份配置没有节点。', style: theme.textTheme.bodySmall),
            )
          else ...[
            const SizedBox(height: Insets.md),
            for (var i = 0; i < nodes.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
              _NodeRow(
                node: nodes[i],
                delay: _delays[nodes[i].id],
                tested: _delays.containsKey(nodes[i].id),
                testing: _testing.contains(nodes[i].id),
              ),
            ],
            if (hidden > 0) ...[
              const SizedBox(height: Insets.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showAllNodes = true),
                  child: Text('显示全部 ${p.nodes.length} 个节点（还有 $hidden 个）'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 分组

  Widget _buildGroupsCard(BuildContext context, Profile p) {
    final theme = Theme.of(context);
    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: '分组',
            subtitle: _isRunningHere
                ? '手动分组可以切换出口，其余按策略自动选'
                : '启动这份配置后可切换手动分组的出口',
          ),
          if (p.groups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.lg),
              child: Text('这份配置没有分组。', style: theme.textTheme.bodySmall),
            )
          else ...[
            const SizedBox(height: Insets.md),
            for (var i = 0; i < p.groups.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
              _GroupRow(
                group: p.groups[i],
                memberCount: _resolveMembers(p, p.groups[i]).length,
                current: _selection[p.groups[i].id],
                canSwitch:
                    _isRunningHere && p.groups[i].type == ProxyGroupType.select,
                onSwitch: () => _pickOutbound(p, p.groups[i]),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 规则

  Widget _buildRulesCard(BuildContext context, Profile p) {
    final theme = Theme.of(context);
    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: '规则',
            subtitle: '按顺序匹配，命中即停',
          ),
          if (p.rules.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.lg),
              child: Text('没有分流规则，所有流量走默认分组。',
                  style: theme.textTheme.bodySmall),
            )
          else ...[
            const SizedBox(height: Insets.md),
            for (var i = 0; i < p.rules.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
              _RuleRow(
                rule: p.rules[i],
                target: p.rules[i].action == RuleAction.proxy
                    ? (p.outboundGroupNameOf(p.rules[i].outboundGroupId) ?? '默认分组')
                    : null,
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${diff.inDays ~/ 30} 个月前';
  }
}

/// 节点行：名称 + 协议/地址 + 右侧延迟。
class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.delay,
    required this.tested,
    required this.testing,
  });

  final ProxyNode node;
  final int? delay;

  /// 是否测过。`delay == null` 有两种含义——没测过、测了超时，
  /// 只靠 delay 分不开，所以单独传一个标记。
  final bool tested;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm + 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  node.name,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${node.protocol.name} · ${node.server}:${node.port}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          SizedBox(width: 62, child: Center(child: _delayBadge(context))),
        ],
      ),
    );
  }

  Widget _delayBadge(BuildContext context) {
    final theme = Theme.of(context);
    if (testing) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    if (!tested) {
      return Text(
        '—',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      );
    }
    if (delay == null) {
      return Text(
        '超时',
        style: theme.textTheme.bodySmall?.copyWith(
          color: VelaColors.resolve(VelaColors.rose, theme.brightness),
          fontWeight: FontWeight.w600,
        ),
      );
    }
    // 延迟分档：<200 好，<500 一般，其余偏差。只在这三档上用颜色，
    // 不要给每个数字配一个色——一行行彩色数字会把页面搞成仪表盘。
    final color = delay! < 200
        ? VelaColors.resolve(VelaColors.emerald, theme.brightness)
        : delay! < 500
            ? VelaColors.resolve(VelaColors.amber, theme.brightness)
            : VelaColors.resolve(VelaColors.rose, theme.brightness);
    return Text(
      '$delay ms',
      style: theme.textTheme.bodySmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 分组行：名称 + 策略/成员数 + 右侧当前出口。
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.memberCount,
    required this.current,
    required this.canSwitch,
    required this.onSwitch,
  });

  final ProxyGroup group;
  final int memberCount;
  final String? current;
  final bool canSwitch;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelect = group.type == ProxyGroupType.select;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm + 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  group.name,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${group.type.label} · $memberCount 个成员',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (isSelect) ...[
            const SizedBox(width: Insets.md),
            if (canSwitch)
              TextButton(
                onPressed: onSwitch,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        current ?? '选择出口',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.expand_more_rounded, size: 16),
                  ],
                ),
              )
            else
              Text(
                current ?? '启动后可切换',
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ],
      ),
    );
  }
}

/// 规则行：动作胶囊 + 条件 + 目标分组。
class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule, required this.target});

  final RuleEntry rule;
  final String? target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (rule.action) {
      RuleAction.proxy => VelaColors.resolve(VelaColors.azure, theme.brightness),
      RuleAction.direct => VelaColors.resolve(VelaColors.emerald, theme.brightness),
      RuleAction.reject => VelaColors.resolve(VelaColors.rose, theme.brightness),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm + 2),
      child: Row(
        children: [
          StatusPill(label: rule.action.label, color: color),
          const SizedBox(width: Insets.sm + 2),
          Expanded(
            child: Text(
              _condition(),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (target != null) ...[
            const SizedBox(width: Insets.sm),
            Text(
              '→ $target',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  String _condition() {
    final parts = <String>[
      if (rule.ruleSetIds.isNotEmpty) '${rule.ruleSetIds.length} 个规则集',
      if (rule.domains.isNotEmpty) '${rule.domains.length} 个域名',
      if (rule.ipCidrs.isNotEmpty) '${rule.ipCidrs.length} 个网段',
    ];
    if (parts.isEmpty) return rule.enabled ? '无条件' : '已停用';
    return rule.enabled ? parts.join(' · ') : '${parts.join(' · ')}（已停用）';
  }
}

/// 出口选择面板。
class _OutboundSheet extends StatelessWidget {
  const _OutboundSheet({
    required this.title,
    required this.members,
    required this.current,
  });

  final String title;
  final List<String> members;
  final String? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        // 成员可能几十个：给个高度上限，超出部分内部滚动，
        // 否则弹层会顶到屏幕顶端。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('切换出口', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '$title · ${members.length} 个可选',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: Insets.lg),
                itemCount: members.length,
                itemBuilder: (context, i) {
                  final name = members[i];
                  final selected = name == current;
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: Insets.xl),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    trailing: selected
                        ? Icon(Icons.check_rounded,
                            size: 18, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.pop(context, name),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
