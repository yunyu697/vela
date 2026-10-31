import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/storage/kv_store.dart';
import 'ui/app_shell.dart';
import 'ui/vela_shortcuts.dart';
import 'ui/vela_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android：从 Kotlin 侧取应用私有目录（HOME 环境变量不可靠）
  if (Platform.isAndroid) {
    try {
      final res = await const MethodChannel('dev.boxhub.boxhub/core')
          .invokeMethod<Map<dynamic, dynamic>>('getPaths');
      AppPaths.androidFilesDir = res?['filesDir'] as String?;
    } catch (_) {
      // 通道不可用时退回默认路径（不阻塞 UI 启动）
    }
  }
  runApp(const VelaApp());
}

class VelaApp extends StatefulWidget {
  const VelaApp({super.key});

  @override
  State<VelaApp> createState() => _VelaAppState();
}

class _VelaAppState extends State<VelaApp> {
  /// 固定亮色主题。
  ///
  /// Vela 的视觉设计以亮色为基准（靛蓝紫渐变 Hero、白色玻璃卡片），
  /// 暗色主题尚未完整打磨。此前跟随系统（ThemeMode.system）导致
  /// macOS 处于深色模式时整个界面切换成接近纯黑的半成品暗色——
  /// 用户实测反馈的「UI 有时变黑」即由此而来。暗色模式打磨完成前
  /// 固定亮色；届时在这里换成用户可配置项。
  final ThemeMode _themeMode = ThemeMode.light;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vela',
      debugShowCheckedModeBanner: false,
      theme: buildVelaTheme(brightness: Brightness.light),
      darkTheme: buildVelaTheme(brightness: Brightness.dark),
      themeMode: _themeMode,
      home: const VelaShell(),
      // 快捷键层必须包在 Navigator 之上：键盘事件从主焦点（通常是
      // ModalScope）向上冒泡，嵌在页面里的 Shortcuts 收不到。
      builder: (context, child) =>
          VelaShortcutLayer(child: child ?? const SizedBox.shrink()),
    );
  }
}
