/// 命令面板（⌘K）：把高频操作压平成一次搜索 + 一次回车。
///
/// 设计动机：此前「启动某个配置」要 概览 → 配置 → 回到运行 → 选配置 →
/// 启动，四跳。有了面板后任意页面 ⌘K → 输入名字 → 回车直达。
///
/// 交互遵循桌面惯例：
///  - ↑/↓ 移动高亮，Enter 执行，Esc 关闭
///  - 输入即过滤（标题 / 副标题包含匹配，大小写不敏感）
///  - 高亮项自动滚动进可视区
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// 一条可执行命令。
class VelaCommand {
  const VelaCommand({
    required this.title,
    required this.icon,
    this.subtitle,
    this.shortcut,
    this.dangerous = false,
    required this.onRun,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final String? shortcut;

  /// 破坏性命令（如停止内核）用红色标注。
  final bool dangerous;
  final VoidCallback onRun;
}

/// 弹出命令面板。返回值无意义（命令自带回调）。
Future<void> showVelaCommandPalette(
  BuildContext context,
  List<VelaCommand> commands,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => _CommandPaletteDialog(commands: commands),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.commands});

  final List<VelaCommand> commands;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _queryCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  int _highlight = 0;

  List<VelaCommand> get _filtered {
    final q = _queryCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.commands;
    return widget.commands
        .where((c) =>
            c.title.toLowerCase().contains(q) ||
            (c.subtitle ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _queryCtrl.addListener(() => setState(() => _highlight = 0));
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _run(VelaCommand c) {
    Navigator.of(context).pop();
    // 等路由关闭动画开始后再执行，避免命令里再弹路由时的上下文时序问题
    WidgetsBinding.instance.addPostFrameCallback((_) => c.onRun());
  }

  void _move(int delta) {
    final list = _filtered;
    if (list.isEmpty) return;
    setState(() {
      _highlight = (_highlight + delta) % list.length;
      if (_highlight < 0) _highlight += list.length;
    });
    // 粗略滚动跟随：每项约 64px
    final target = _highlight * 64.0;
    if (target < _scrollCtrl.offset ||
        target > _scrollCtrl.offset + 320) {
      _scrollCtrl.jumpTo(
        (target - 160).clamp(0.0, _scrollCtrl.position.maxScrollExtent),
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final list = _filtered;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (list.isNotEmpty && _highlight < list.length) {
        _run(list[_highlight]);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final list = _filtered;

    return Focus(
      onKeyEvent: (_, event) => _onKey(_focusNode, event),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                  ? theme.colorScheme.surfaceContainerHigh
                  : Colors.white,
              borderRadius: BorderRadius.circular(Radii.xl),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.14),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
                  child: TextField(
                    controller: _queryCtrl,
                    autofocus: true,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: '搜索命令：前往页面、启动配置、切换内核…',
                      prefixIcon: const Icon(Icons.bolt_rounded, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? theme.colorScheme.surfaceContainerLow
                          : theme.colorScheme.surfaceContainerLowest,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.sm),
                Flexible(
                  child: list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Insets.xxl),
                          child: Center(
                            child: Text(
                              '没有匹配的命令',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Insets.sm,
                            vertical: Insets.xs,
                          ),
                          itemCount: list.length,
                          itemExtent: 64,
                          itemBuilder: (context, i) {
                            final c = list[i];
                            final selected = i == _highlight;
                            final color = c.dangerous
                                ? theme.colorScheme.error
                                : (selected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface);
                            return InkWell(
                              borderRadius: BorderRadius.circular(Radii.md),
                              onTap: () => _run(c),
                              onHover: (h) {
                                if (h && _highlight != i) {
                                  setState(() => _highlight = i);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: Insets.md,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.10)
                                      : Colors.transparent,
                                  borderRadius:
                                      BorderRadius.circular(Radii.md),
                                ),
                                child: Row(
                                  children: [
                                    Icon(c.icon, size: 20, color: color),
                                    const SizedBox(width: Insets.md),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            c.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyLarge
                                                ?.copyWith(
                                              color: color,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                          if (c.subtitle != null)
                                            Text(
                                              c.subtitle!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                color: theme.colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (c.shortcut != null)
                                      _ShortcutChip(label: c.shortcut!),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Insets.lg, Insets.xs, Insets.lg, Insets.sm),
                  child: Row(
                    children: [
                      const _ShortcutChip(label: '↑↓'),
                      const SizedBox(width: Insets.xs),
                      Text('选择',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )),
                      const SizedBox(width: Insets.md),
                      const _ShortcutChip(label: '↵'),
                      const SizedBox(width: Insets.xs),
                      Text('执行',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )),
                      const SizedBox(width: Insets.md),
                      const _ShortcutChip(label: 'Esc'),
                      const SizedBox(width: Insets.xs),
                      Text('关闭',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )),
                    ],
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

class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
