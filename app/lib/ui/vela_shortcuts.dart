/// 全局快捷键层。
///
/// 放置位置很讲究：必须包在 [MaterialApp.builder]（即 Navigator 之上），
/// 因为键盘事件从「主焦点」向上冒泡，而主焦点通常是 Navigator 的
/// ModalScope——若 Shortcuts 嵌在某个页面内部，事件根本到不了它。
///
/// 快捷键 → 总线回调（由 VelaShell 注册）：
///  - ⌘K / Ctrl+K：命令面板
///  - ⌘1 / ⌘2 / ⌘3：前往概览 / 配置 / 运行
///  - ⌘R：一键启停
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 页面 → 外壳 的快捷键动作总线。
class VelaShortcutBus {
  VelaShortcutBus._();
  static final VelaShortcutBus instance = VelaShortcutBus._();

  ValueChanged<int>? onGoTab;
  VoidCallback? onOpenPalette;
  VoidCallback? onToggleCore;

  void reset() {
    onGoTab = null;
    onOpenPalette = null;
    onToggleCore = null;
  }
}

/// 包在 MaterialApp.builder 里的快捷键拦截层。
class VelaShortcutLayer extends StatelessWidget {
  const VelaShortcutLayer({super.key, required this.child});

  final Widget child;

  static bool get _isMac =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static SingleActivator _mod(LogicalKeyboardKey key) => _isMac
      ? SingleActivator(key, meta: true)
      : SingleActivator(key, control: true);

  @override
  Widget build(BuildContext context) {
    final bus = VelaShortcutBus.instance;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        _mod(LogicalKeyboardKey.keyK): const _OpenPaletteIntent(),
        _mod(LogicalKeyboardKey.digit1): const _GoTabIntent(0),
        _mod(LogicalKeyboardKey.digit2): const _GoTabIntent(1),
        _mod(LogicalKeyboardKey.digit3): const _GoTabIntent(2),
        _mod(LogicalKeyboardKey.keyR): const _ToggleCoreIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenPaletteIntent: CallbackAction<_OpenPaletteIntent>(
            onInvoke: (_) {
              bus.onOpenPalette?.call();
              return null;
            },
          ),
          _GoTabIntent: CallbackAction<_GoTabIntent>(
            onInvoke: (intent) {
              bus.onGoTab?.call(intent.index);
              return null;
            },
          ),
          _ToggleCoreIntent: CallbackAction<_ToggleCoreIntent>(
            onInvoke: (_) {
              bus.onToggleCore?.call();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _OpenPaletteIntent extends Intent {
  const _OpenPaletteIntent();
}

class _GoTabIntent extends Intent {
  const _GoTabIntent(this.index);
  final int index;
}

class _ToggleCoreIntent extends Intent {
  const _ToggleCoreIntent();
}
