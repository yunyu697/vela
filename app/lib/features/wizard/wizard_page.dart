/// 配置向导：七步引导生成代理配置。
///
/// 布局随窗口宽度自适应：
///  - 宽屏：左侧步骤导航 + 右侧内容 + Lint 侧栏（三栏）
///  - 中屏：左侧步骤导航 + 右侧内容（两栏）
///  - 窄屏：顶部横向步骤条 + 内容（单栏）
///
/// 步骤切换使用淡入位移动画，底部操作栏固定，所有页面间距统一走
/// [Insets] 令牌，保证跨页面对齐一致。
library;

import 'package:flutter/material.dart';

import '../../core/ir/profile.dart';
import '../../core/ir/rule_set_registry.dart';
import '../../core/lint/lint_engine.dart';
import '../../core/storage/profile_repository.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';
import '../run/run_page.dart';
import 'wizard_controller.dart';

class WizardPage extends StatefulWidget {
  const WizardPage({super.key, this.initialProfileName});

  /// 初始配置名。缺省为带时间戳的自动名；测试传固定值以保证
  /// 黄金图等快照不随运行时刻变化。
  final String? initialProfileName;

  @override
  State<WizardPage> createState() => WizardPageState();
}

/// 向导页面状态。
///
/// 公开以便布局测试直接驱动步骤切换（[controller] 暴露给测试，
/// 正常使用不应依赖它）。
class WizardPageState extends State<WizardPage> {
  late final WizardController _controller =
      WizardController(initialName: widget.initialProfileName);

  /// 向导状态机（测试用）。
  @visibleForTesting
  WizardController get controller => _controller;

  // 输入框用稳定的 controller：整页 setState 重建时保持光标、
  // 选区与右键菜单不被打断（widget 重建不影响 EditableText 状态）
  late final _subUrlCtrl = TextEditingController();
  late final _linksCtrl = TextEditingController();
  late final _nameCtrl = TextEditingController(text: _controller.profileName);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
    _controller.applyDnsPreset(DnsPreset.recommended);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _subUrlCtrl.dispose();
    _linksCtrl.dispose();
    _nameCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    const steps = WizardStep.values;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: VelaBackdrop()),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(context, scope),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!scope.size.isCompact)
                        _buildStepRail(context, steps),
                      Expanded(child: _buildStepArea(context, scope, steps)),
                      if (scope.size.isExpanded)
                        _buildLintSidePanel(context),
                    ],
                  ),
                ),
                _buildBottomBar(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 顶栏

  Widget _buildTopBar(BuildContext context, AdaptiveScope scope) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        Insets.md,
        scope.size.isCompact ? Insets.md : Insets.xl,
        Insets.md,
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
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: '返回',
          ),
          const SizedBox(width: Insets.xs),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: VelaColors.brandGradient,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: const Center(
              child: VelaLogoMark(size: 18, color: Colors.white),
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('配置向导', style: theme.textTheme.titleMedium),
                Text(
                  '第 ${_controller.stepIndex + 1} / ${WizardStep.values.length} 步 · ${_controller.step.label}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!scope.size.isCompact)
            _buildProgressBar(context, scope),
        ],
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, AdaptiveScope scope) {
    final theme = Theme.of(context);
    final total = WizardStep.values.length;
    final progress = (_controller.stepIndex + 1) / total;
    return SizedBox(
      width: scope.size == WindowSize.wide ? 260 : 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${(progress * 100).round()}%',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Insets.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 步骤导航

  Widget _buildStepRail(BuildContext context, List<WizardStep> steps) {
    final theme = Theme.of(context);
    return Container(
      width: 232,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Insets.md, Insets.lg, Insets.md, Insets.lg),
        children: [
          for (var i = 0; i < steps.length; i++)
            _buildStepTile(context, steps[i], i),
        ],
      ),
    );
  }

  Widget _buildStepTile(BuildContext context, WizardStep step, int index) {
    final theme = Theme.of(context);
    final current = index == _controller.stepIndex;
    final done = index < _controller.stepIndex;
    final color = current
        ? theme.colorScheme.primary
        : (done ? VelaColors.emerald : theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Material(
        color: current
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: done ? () => _goTo(index) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.md,
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: Motion.fast),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: current
                        ? theme.colorScheme.primary
                        : (done
                            ? VelaColors.emerald.withValues(alpha: 0.16)
                            : theme.colorScheme.surfaceContainerHighest),
                    border: Border.all(
                      color: current || done ? Colors.transparent : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Center(
                    child: done && !current
                        ? const Icon(Icons.check_rounded, size: 15, color: VelaColors.emerald)
                        : Text(
                            '${index + 1}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: current ? Colors.white : color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    step.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      color: current ? theme.colorScheme.primary : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _goTo(int index) {
    while (_controller.stepIndex > index) {
      _controller.back();
    }
    while (_controller.stepIndex < index) {
      if (!_controller.canAdvance) break;
      _controller.next();
    }
  }

  /// 窄屏用的横向步骤条。
  Widget _buildCompactSteps(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.sm),
        itemCount: WizardStep.values.length,
        itemBuilder: (context, i) {
          final step = WizardStep.values[i];
          final current = i == _controller.stepIndex;
          final done = i < _controller.stepIndex;
          return Padding(
            padding: const EdgeInsets.only(right: Insets.sm),
            child: Material(
              color: current
                  ? theme.colorScheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.pill),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.pill),
                onTap: done ? () => _goTo(i) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: Insets.sm,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: Border.all(
                      color: current
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (done)
                        const Icon(Icons.check_rounded,
                            size: 14, color: VelaColors.emerald)
                      else
                        Text(
                          '${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: current
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const SizedBox(width: Insets.xs),
                      Text(
                        step.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: current
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight:
                              current ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------- 内容区

  Widget _buildStepArea(
      BuildContext context, AdaptiveScope scope, List<WizardStep> steps) {
    return Column(
      children: [
        if (scope.size.isCompact) _buildCompactSteps(context),
        Expanded(
          child: VelaPageTransition(
            // key 随步骤变化，触发转场动画
            key: ValueKey(_controller.step),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                scope.size.isCompact ? Insets.lg : Insets.xxl,
                Insets.xl,
                scope.size.isCompact ? Insets.lg : Insets.xxl,
                Insets.xl,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildStepBody(context, scope),
                      // 宽屏有独立 Lint 侧栏，窄屏/中屏内嵌在内容下方
                      if (!scope.size.isExpanded) _buildLintInline(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStepBody(BuildContext context, AdaptiveScope scope) {
    switch (_controller.step) {
      case WizardStep.core:
        return _buildCoreStep(context);
      case WizardStep.source:
        return _buildSourceStep(context, scope);
      case WizardStep.nodes:
        return _buildNodesStep(context);
      case WizardStep.rules:
        return _buildRulesStep(context);
      case WizardStep.dns:
        return _buildDnsStep(context);
      case WizardStep.inbound:
        return _buildInboundStep(context);
      case WizardStep.review:
        return _buildReviewStep(context);
    }
  }

  Widget _stepCard(BuildContext context, Widget child, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint != null) ...[
          Text(
            hint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: Insets.lg),
        ],
        VelaCard(child: child),
      ],
    );
  }

  Widget _buildCoreStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 配置名称：默认带时间戳保证不重复，向导全程可改。
        _stepCard(
          context,
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '配置名称',
              hintText: '给这份配置起个名字',
              prefixIcon: Icon(Icons.label_outline_rounded),
            ),
            onChanged: _controller.setProfileName,
          ),
          hint: '默认名称带日期时间，连续生成多份配置时不会混淆；'
              '全程都可以在这里改名。',
        ),
        _stepCard(
          context,
          Column(
            children: [
              ChoiceCard(
                title: 'mihomo',
                subtitle: '协议支持最广，SSR / Hysteria v1 等全兼容',
                icon: Icons.hub_outlined,
                selected: _controller.coreKind == CoreKind.mihomo,
                onTap: () => _controller.setCoreKind(CoreKind.mihomo),
              ),
              const SizedBox(height: Insets.md),
              ChoiceCard(
                title: 'sing-box',
                subtitle: '新协议跟进快，性能与内存表现优秀',
                icon: Icons.bolt_rounded,
                selected: _controller.coreKind == CoreKind.singbox,
                onTap: () => _controller.setCoreKind(CoreKind.singbox),
              ),
            ],
          ),
          hint: '选择内核后，向导会按该内核的语法生成配置；运行中也可一键换内核。',
        ),
      ],
    );
  }

  Widget _buildSourceStep(BuildContext context, AdaptiveScope scope) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<SourceKind>(
                segments: const [
                  ButtonSegment(value: SourceKind.subscription, label: Text('订阅')),
                  ButtonSegment(value: SourceKind.links, label: Text('分享链接')),
                  ButtonSegment(value: SourceKind.manual, label: Text('手动')),
                  ButtonSegment(value: SourceKind.file, label: Text('文件')),
                ],
                selected: {_controller.sourceKind},
                onSelectionChanged: (s) =>
                    _controller.setSource(s.first, _subUrlCtrl.text),
              ),
              const SizedBox(height: Insets.lg),
              AnimatedSize(
                duration: const Duration(milliseconds: Motion.normal),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: switch (_controller.sourceKind) {
                  SourceKind.subscription => _buildSubscriptionInput(context),
                  SourceKind.links => _buildLinksInput(context),
                  SourceKind.manual => _buildManualHint(context),
                  SourceKind.file => _buildFileHint(context),
                },
              ),
            ],
          ),
          hint: '导入节点的方式。订阅链接会按所选内核的 User-Agent 拉取，'
              '并自动识别 Base64 / Clash YAML / sing-box JSON 三种格式。',
        ),
      ],
    );
  }

  Widget _buildSubscriptionInput(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _subUrlCtrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '订阅链接',
            hintText: 'https://...',
            prefixIcon: Icon(Icons.link_rounded),
          ),
          onChanged: (v) => _controller.setSource(SourceKind.subscription, v),
        ),
        const SizedBox(height: Insets.md),
        VelaGradientButton(
          label: '拉取节点',
          icon: Icons.cloud_download_outlined,
          expand: true,
          busy: _controller.fetching,
          onPressed: _controller.fetching ? null : _controller.fetchNodes,
        ),
        _buildFetchStatus(context),
      ],
    );
  }

  Widget _buildLinksInput(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _linksCtrl,
          maxLines: 6,
          minLines: 4,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          decoration: const InputDecoration(
            labelText: '分享链接（每行一条）',
            hintText: 'ss://… / vmess://… / vless://… / trojan://…',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: Insets.md),
        VelaGradientButton(
          label: '导入',
          icon: Icons.input_rounded,
          expand: true,
          onPressed: () => _controller.importLinksText(_linksCtrl.text),
        ),
        _buildFetchStatus(context),
      ],
    );
  }

  Widget _buildManualHint(BuildContext context) {
    return _infoNote(
      context,
      Icons.edit_note_rounded,
      '手动模式：保存后可在「配置」页直接编辑节点与规则（该功能将在下个版本开放）。',
    );
  }

  Widget _buildFileHint(BuildContext context) {
    return _infoNote(
      context,
      Icons.folder_open_rounded,
      '文件模式：从本地导入 Clash YAML 或 sing-box JSON 配置文件（下个版本开放）。',
    );
  }

  Widget _infoNote(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: Insets.md),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  Widget _buildFetchStatus(BuildContext context) {
    final theme = Theme.of(context);
    if (_controller.fetchError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: Insets.md),
        child: _statusBanner(
          context,
          color: theme.colorScheme.error,
          icon: Icons.error_outline_rounded,
          text: '错误：${_controller.fetchError}',
        ),
      );
    }
    final info = _controller.subscriptionInfo;
    final count = _controller.importedNodes.length;
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: _statusBanner(
        context,
        color: VelaColors.emerald,
        icon: Icons.check_circle_outline_rounded,
        text: '已解析 $count 个节点'
            '${info != null && info.total > 0 ? ' · 流量 ${_fmtBytes(info.used)}/${_fmtBytes(info.total)}' : ''}',
      ),
    );
  }

  Widget _statusBanner(
      BuildContext context, {required Color color, required IconData icon, required String text}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodesStep(BuildContext context) {
    final nodes = _controller.importedNodes;
    final theme = Theme.of(context);
    if (nodes.isEmpty) {
      return _stepCard(
        context,
        _infoNote(
          context,
          Icons.cloud_off_rounded,
          '还没有节点。请回到「配置来源」步骤拉取订阅或导入分享链接。',
        ),
      );
    }

    // 按协议统计
    final byProtocol = <ProxyProtocol, int>{};
    for (final n in nodes) {
      byProtocol[n.protocol] = (byProtocol[n.protocol] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: Insets.sm,
                      runSpacing: Insets.sm,
                      children: [
                        for (final e in byProtocol.entries)
                          Chip(
                            label: Text('${e.key.name} · ${e.value}'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              Divider(color: theme.colorScheme.outlineVariant),
              const SizedBox(height: Insets.md),
              for (final n in nodes.take(40))
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Icon(
                          Icons.lan_outlined,
                          size: 15,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      Expanded(
                        child: Text(
                          n.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        n.protocol.name,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              if (nodes.length > 40)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    '…以及其余 ${nodes.length - 40} 个节点',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          hint: '共导入 ${nodes.length} 个节点。向导会自动按地区关键词建立分组。',
        ),
      ],
    );
  }

  Widget _buildRulesStep(BuildContext context) {
    final sets = RuleSetRegistry.builtin;
    final activeScenario = RuleScenarios.matching(
      _controller.selectedRuleSetIds,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 常用场景：一键勾选一组规则集，应用后仍可自由增删。
              Text('常用场景', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.md),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  for (final s in RuleScenarios.builtin)
                    _ScenarioChip(
                      scenario: s,
                      selected: activeScenario?.id == s.id,
                      onTap: () => _controller.applyScenario(s.id),
                    ),
                ],
              ),
              const SizedBox(height: Insets.lg),
              Divider(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              const SizedBox(height: Insets.lg),
              Text('规则集明细', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.md),
              for (final rs in sets)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: _RuleSetTile(
                    ruleSet: rs,
                    selected: _controller.selectedRuleSetIds.contains(rs.id),
                    onToggle: () => _controller.toggleRuleSet(rs.id),
                  ),
                ),
            ],
          ),
          hint: '先选一个常用场景快速起步，再在下方明细里微调；'
              '动作标签表示该规则集默认的走向（直连 / 代理 / 拦截）。',
        ),
      ],
    );
  }

  Widget _buildDnsStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            children: [
              for (final preset in DnsPreset.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: ChoiceCard(
                    title: preset.label,
                    subtitle: preset.description,
                    icon: Icons.dns_outlined,
                    selected: _controller.dnsPreset == preset,
                    onTap: () => _controller.applyDnsPreset(preset),
                  ),
                ),
            ],
          ),
          hint: 'DNS 接管会影响系统解析行为。选「推荐（fake-ip）」时，'
              '向导会自动补齐本地服务白名单。',
        ),
      ],
    );
  }

  Widget _buildInboundStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            children: [
              ChoiceCard(
                title: '混合端口（mixed）',
                subtitle: '同时提供 HTTP 与 SOCKS5 代理，兼容性最好，推荐',
                icon: Icons.swap_horiz_rounded,
                selected: _controller.accessMode == AccessMode.mixed,
                onTap: () => _controller.setAccessMode(AccessMode.mixed),
              ),
              const SizedBox(height: Insets.md),
              ChoiceCard(
                title: '系统代理',
                subtitle: '把系统 HTTP/HTTPS 代理指向混合端口',
                icon: Icons.settings_ethernet_rounded,
                selected: _controller.accessMode == AccessMode.systemProxy,
                onTap: () => _controller.setAccessMode(AccessMode.systemProxy),
              ),
              const SizedBox(height: Insets.md),
              ChoiceCard(
                title: 'TUN 模式',
                subtitle: '接管全局流量，需要管理员权限（桌面端）',
                icon: Icons.shield_outlined,
                selected: _controller.accessMode == AccessMode.tun,
                onTap: () => _controller.setAccessMode(AccessMode.tun),
              ),
            ],
          ),
          hint: '入站模式决定流量如何进入内核。',
        ),
      ],
    );
  }

  Widget _buildReviewStep(BuildContext context) {
    final result = _controller.build();
    final theme = Theme.of(context);
    if (!result.success) {
      return _stepCard(
        context,
        _infoNote(
          context,
          Icons.block_rounded,
          '存在阻断级问题，请在右侧「检查结果」中修复后继续。',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepCard(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoRow(label: '配置名', value: result.profile.name),
              InfoRow(
                label: '内核',
                value: result.profile.coreKind == CoreKind.singbox
                    ? 'sing-box'
                    : 'mihomo',
              ),
              InfoRow(label: '节点', value: '${result.profile.nodes.length}'),
              InfoRow(label: '分组', value: '${result.profile.groups.length}'),
              InfoRow(label: '规则', value: '${result.profile.rules.length}'),
              InfoRow(
                label: 'DNS',
                value: result.profile.dns.mode.name,
                monospace: true,
              ),
              InfoRow(
                label: '入站',
                value: result.profile.inbound.mode.name,
                monospace: true,
              ),
            ],
          ),
          hint: '以下是即将生成的配置，确认无误后点击「完成」保存。',
        ),
        const SizedBox(height: Insets.lg),
        Text('配置预览', style: theme.textTheme.titleSmall),
        const SizedBox(height: Insets.sm),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 320),
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                result.configText!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ Lint 面板

  Widget _buildLintSidePanel(BuildContext context) {
    final theme = Theme.of(context);
    final issues = _controller.currentLint;
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.lg, Insets.lg, Insets.md),
            child: Row(
              children: [
                Icon(
                  issues.isEmpty ? Icons.verified_outlined : Icons.warning_amber_rounded,
                  size: 20,
                  color: issues.isEmpty ? VelaColors.emerald : VelaColors.amber,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text('检查结果', style: theme.textTheme.titleSmall),
                ),
                StatusPill(
                  label: '${issues.length}',
                  color: issues.isEmpty ? VelaColors.emerald : VelaColors.amber,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: issues.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Insets.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline_rounded,
                              size: 34, color: VelaColors.emerald.withValues(alpha: 0.7)),
                          const SizedBox(height: Insets.md),
                          Text('未发现问题', style: theme.textTheme.titleSmall),
                          const SizedBox(height: Insets.xs),
                          Text(
                            '配置符合当前内核的要求',
                            style: theme.textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(Insets.md),
                    children: [
                      for (final issue in issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Insets.sm),
                          child: _LintTile(issue: issue),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 窄屏/中屏的 Lint 面板（内嵌在内容下方）。
  Widget _buildLintInline(BuildContext context) {
    final issues = _controller.currentLint;
    if (issues.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Insets.lg),
        for (final issue in issues)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: _LintTile(issue: issue),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 底部操作栏

  Widget _buildBottomBar(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AdaptiveScope.of(context);
    final isLast = _controller.stepIndex == WizardStep.values.length - 1;

    return Container(
      padding: EdgeInsets.fromLTRB(
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        Insets.md,
        scope.size.isCompact ? Insets.lg : Insets.xxl,
        Insets.md,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          if (_controller.stepIndex > 0)
            OutlinedButton.icon(
              onPressed: _controller.back,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('上一步'),
            ),
          const Spacer(),
          if (!scope.size.isCompact)
            Padding(
              padding: const EdgeInsets.only(right: Insets.lg),
              child: Text(
                '第 ${_controller.stepIndex + 1} / ${WizardStep.values.length} 步',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (!isLast)
            VelaGradientButton(
              label: '下一步',
              icon: Icons.arrow_forward_rounded,
              onPressed: _controller.canAdvance ? _controller.next : null,
            )
          else
            VelaGradientButton(
              label: '完成并保存',
              icon: Icons.check_rounded,
              onPressed: () => _finish(context),
            ),
        ],
      ),
    );
  }

  /// 完成向导：生成 + 保存 Profile，成功后跳转「运行」页。
  Future<void> _finish(BuildContext context) async {
    final result = _controller.build();
    if (!result.success) {
      final errors =
          result.issues.where((i) => i.severity == LintSeverity.error).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('生成被阻断：$errors 个错误，请先修复')),
      );
      return;
    }
    // 名称去重兜底：即使用户手动输入了与已有配置相同的名字，
    // 也自动追加序号，避免覆盖旧配置。
    final repo = ProfileRepository.instance;
    final finalName = _dedupeName(repo, result.profile.name);
    final toSave =
        finalName == result.profile.name ? result.profile : result.profile.copyWith(name: finalName);
    await repo.saveProfile(toSave);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${toSave.name}」已保存')),
    );
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => RunPage(initialProfileId: toSave.id)),
    );
  }

  static String _dedupeName(ProfileRepository repo, String name) {
    final existing = repo.profiles.map((p) => p.name).toSet();
    if (!existing.contains(name)) return name;
    for (var i = 2;; i++) {
      final candidate = '$name $i';
      if (!existing.contains(candidate)) return candidate;
    }
  }
}

/// 常用场景芯片：一键应用一组规则集组合。
class _ScenarioChip extends StatelessWidget {
  const _ScenarioChip({
    required this.scenario,
    required this.selected,
    required this.onTap,
  });

  final RuleScenario scenario;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TooltipWrap(
      message: scenario.description,
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.sm + 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: Insets.xs),
                ],
                Text(
                  scenario.name,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tooltip 包一层并带边框色提示（场景芯片悬停说明）。
class _TooltipWrap extends StatelessWidget {
  const _TooltipWrap({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Tooltip(message: message, waitDuration: const Duration(milliseconds: 400), child: child);
}

/// 规则集行：勾选 + 名称 + 说明 + 默认动作标签。
class _RuleSetTile extends StatelessWidget {
  const _RuleSetTile({
    required this.ruleSet,
    required this.selected,
    required this.onToggle,
  });

  final BuiltinRuleSet ruleSet;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionColor = switch (ruleSet.suggestedAction) {
      RuleAction.direct => VelaColors.emerald,
      RuleAction.proxy => VelaColors.violet,
      RuleAction.reject => VelaColors.rose,
    };
    final actionLabel = switch (ruleSet.suggestedAction) {
      RuleAction.direct => '直连',
      RuleAction.proxy => '代理',
      RuleAction.reject => '拦截',
    };

    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.07)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.md,
          ),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ruleSet.name, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(
                      ruleSet.description,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              StatusPill(label: actionLabel, color: actionColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lint 问题卡片。
class _LintTile extends StatelessWidget {
  const _LintTile({required this.issue});

  final LintIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (issue.severity) {
      LintSeverity.error => (theme.colorScheme.error, Icons.error_outline_rounded),
      LintSeverity.warning => (VelaColors.amber, Icons.warning_amber_rounded),
      LintSeverity.info => (VelaColors.azure, Icons.info_outline_rounded),
    };

    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  issue.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (issue.fixHint != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    issue.fixHint!,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
