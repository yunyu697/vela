/// 主题模式切换控件。
///
/// 三态循环：跟随系统 → 亮色 → 暗色。放在侧栏底部常驻，
/// 紧凑布局（无侧栏）时由概览页 Hero 右上角的紧凑形态承担。
library;

import 'package:flutter/material.dart';

import '../core/settings/app_settings.dart';
import 'tokens.dart';

class VelaThemeToggle extends StatelessWidget {
  const VelaThemeToggle({
    super.key,
    this.extended = true,
    this.onGradient = false,
  });

  /// 是否显示文字标签（侧栏展开态）。收起态只显示图标。
  final bool extended;

  /// 是否放在渐变/深色背景上：此时用白色前景，避免图标与背景同色。
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final mode = AppSettings.instance.themeMode;
        final fg = onGradient ? Colors.white : theme.colorScheme.onSurfaceVariant;
        final bg = onGradient
            ? Colors.white.withValues(alpha: 0.18)
            : theme.colorScheme.surfaceContainer.withValues(alpha: 0.7);
        final border = onGradient
            ? Border.all(color: Colors.white.withValues(alpha: 0.35))
            : Border.all(color: theme.colorScheme.outlineVariant);

        return Tooltip(
          message: '主题：${mode.label}（点击切换为${mode.next.label}）',
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: AppSettings.instance.cycleThemeMode,
              child: Container(
                height: 42,
                padding: EdgeInsets.symmetric(
                  horizontal: extended ? Insets.md : 0,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: border,
                ),
                child: Row(
                  mainAxisAlignment: extended
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(mode.icon, size: 18, color: fg),
                    if (extended) ...[
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          mode.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
