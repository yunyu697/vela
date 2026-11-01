/// Vela 共享 UI 组件库。
///
/// 设计约定（全库统一）：
///  - **卡片 = 白纸 + 发丝线**：无投影、无渐变、无半透明叠加。
///  - **图标不做彩色底块**：彩色小方块一多，界面就变成「图标墙」。
///    图标只在语义状态（运行中/错误）时才着色。
///  - **数字优先**：统计项用「小标签 + 大数字」，而不是图标 + 数字。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 卡片：表面色 + 1px 发丝线，无投影。
class VelaCard extends StatelessWidget {
  const VelaCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Insets.lg),
    this.onTap,
    this.borderColor,
    this.radius = Radii.lg,
    this.tinted = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// 覆盖描边色（例如「已选中」「收藏」态）。
  final Color? borderColor;
  final double radius;

  /// 用略深的表面色填充（用于次级信息块，如连接表头）。
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    final surface = tinted
        ? theme.colorScheme.surfaceContainer
        : (isDark ? theme.colorScheme.surfaceContainerLow : theme.colorScheme.surface);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: shape,
        border: Border.all(color: borderColor ?? theme.colorScheme.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: shape,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 章节标题：标题 + 可选副标题 + 可选尾部动作。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Insets.md),
          trailing!,
        ],
      ],
    );
  }
}

/// 统计项：小标签在上、数字在下。
///
/// 相比「彩色圆形图标 + 数字」的磁贴，这种排法占位更小、信息密度更高，
/// 也不会让页面出现四五个互不相干的颜色。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.accent,
    this.valueColor,
    this.compact = false,
  });

  final String label;
  final String value;
  final IconData? icon;

  /// 仅作用于前置小图标；不传则用次要文字色。
  final Color? accent;

  /// 数值颜色。只在状态类数值（运行中 / 异常）上传入。
  final Color? valueColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: accent ?? muted),
              const SizedBox(width: Insets.xs + 2),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: compact ? 11 : 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs + 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: (compact
                    ? theme.textTheme.titleSmall
                    : theme.textTheme.titleMedium)
                ?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: valueColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 状态胶囊：色点 + 文字，1px 描边，无填充。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.pulsing = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm + 2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulsing)
            _PulseDot(color: color)
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          if (icon != null) ...[
            const SizedBox(width: Insets.xs),
            Icon(icon, size: 13, color: color),
          ],
          const SizedBox(width: Insets.sm - 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w500,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行状态呼吸灯。
///
/// 性能要点：动画只改变**颜色透明度**，不改变几何与阴影。
/// 之前的实现每帧都重算 `boxShadow` 的 blurRadius（0→6），这会让每个
/// 呼吸灯每帧都触发一次模糊采样与离屏缓冲。现在阴影固定，只有圆点
/// 自身的 alpha 在变化，成本几乎为零。
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 + 0.65 * t),
            ),
          );
        },
      ),
    );
  }
}

/// 空状态：图标 + 标题 + 描述 + 动作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 28,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              const SizedBox(height: Insets.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              if (message != null) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: Insets.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 信息行：左标签右数值，中间用虚线填充。
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 9, left: Insets.xs),
              child: CustomPaint(
                painter: _DottedLinePainter(
                  color: theme.colorScheme.outlineVariant,
                ),
                size: const Size(double.infinity, 1),
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: valueColor ?? theme.colorScheme.onSurface,
              fontFamily: monospace ? 'monospace' : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _DottedLinePainter extends CustomPainter {
  _DottedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 2.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, 0),
        Offset((x + dash).clamp(0, size.width), 0),
        paint,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DottedLinePainter oldDelegate) => oldDelegate.color != color;
}

/// 主按钮：实心主色，无投影。
class VelaPrimaryButton extends StatelessWidget {
  const VelaPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
    this.tone = VelaButtonTone.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool busy;

  /// [VelaButtonTone.primary] 实心主色；[VelaButtonTone.quiet] 描边。
  final VelaButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null && !busy;
    final isPrimary = tone == VelaButtonTone.primary;
    final fg = isPrimary ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(fg),
            ),
          )
        else if (icon != null)
          Icon(icon, size: 18, color: fg),
        if (busy || icon != null) const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: fg,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isPrimary ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          border: isPrimary
              ? null
              : Border.all(color: theme.colorScheme.outline),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: enabled ? onPressed : null,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              // 刻意不给 alignment：Container 一旦有 alignment 就会在
              // 有界约束下撑满父级宽度，导致「未要求 expand 的按钮」也被拉长。
              // 居中由 Row 的 mainAxisAlignment 负责。
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 按钮基调。
enum VelaButtonTone { primary, quiet }

/// 可选卡片项（用于内核选择、DNS 预设等）。
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: Motion.instant),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.surfaceContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.md,
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: Insets.md),
                ] else if (icon != null) ...[
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? theme.colorScheme.primary : muted,
                  ),
                  const SizedBox(width: Insets.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: selected ? theme.colorScheme.onSurface : null,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: Insets.sm),
                  trailing!,
                ] else if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部标题区（页面级标题 + 副标题）。
class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Insets.lg),
          trailing!,
        ],
      ],
    );
  }
}
