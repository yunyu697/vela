import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/settings/app_settings.dart';
import 'core/storage/kv_store.dart';
import 'ui/app_shell.dart';
import 'ui/vela_shortcuts.dart';
import 'ui/vela_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 移动端支持横竖屏自由旋转（桌面端此调用无副作用）：
  // 布局按 AdaptiveScope 的内容区尺寸自适应，无需锁方向。
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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
  // 载入用户偏好（主题模式）。失败时用默认值，不阻塞启动。
  await AppSettings.instance.init();
  runApp(const VelaApp());
}

class VelaApp extends StatelessWidget {
  const VelaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 主题模式是用户可配置项：监听设置单例，切换时整棵树重建。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Vela',
          debugShowCheckedModeBanner: false,
          theme: buildVelaTheme(brightness: Brightness.light),
          darkTheme: buildVelaTheme(brightness: Brightness.dark),
          themeMode: AppSettings.instance.themeMode,
          home: const VelaShell(),
          // 快捷键层必须包在 Navigator 之上：键盘事件从主焦点（通常是
          // ModalScope）向上冒泡，嵌在页面里的 Shortcuts 收不到。
          builder: (context, child) => VelaShortcutLayer(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}
