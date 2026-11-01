/// 主题模式切换控件。
///
/// 三态循环：跟随系统 → 亮色 → 暗色。放在侧栏底部常驻，
/// 紧凑布局（无侧栏）时由概览页标题栏承担。
///
/// 形态上刻意做成「静默按钮」：无填充、无描边，只有悬停时才浮出底色。
/// 它是个低频设置项，不该和导航项抢视觉权重。
library;

import 'package:flutter/material.dart';

import '../core/settings/app_settings.dart';
import 'tokens.dart';

class VelaThemeToggle extends StatelessWidget {
  const VelaThemeToggle({super.key, this.extended = true});

  /// 是否显示文字标签（侧栏展开态）。收起态只显示图标。
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final mode = AppSettings.instance.themeMode;
        final fg = theme.colorScheme.onSurfaceVariant;
        return Tooltip(
          message: '主题：${mode.label}（点击切换为${mode.next.label}）',
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: AppSettings.instance.cycleThemeMode,
              child: Container(
                height: 36,
                padding: EdgeInsets.symmetric(
                  horizontal: extended ? Insets.md : 0,
                ),
                child: Row(
                  mainAxisAlignment: extended
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(mode.icon, size: 17, color: fg),
                    if (extended) ...[
                      const SizedBox(width: Insets.sm + 2),
                      Expanded(
                        child: Text(
                          mode.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: fg),
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
