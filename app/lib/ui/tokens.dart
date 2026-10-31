/// Vela 设计令牌（Design Tokens）。
///
/// 全局间距、圆角、时长、缓动与断点阈值的唯一来源。
/// 页面布局一律引用这里的常量，避免各页面各自为政导致对齐错位。
library;

import 'package:flutter/material.dart';

/// 间距刻度：以 4px 为基准的倍数，页面 padding / gap 只允许取这里值。
abstract final class Insets {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// 圆角刻度。
abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double xl = 24;
  static const double xxl = 32;
  static const double pill = 999;

  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius panel = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius chip = BorderRadius.all(Radius.circular(pill));

  /// 中等圆角（12）。BorderRadius.circular 不是 const 构造，
  /// 需要 const 上下文时用这个常量。
  static const BorderRadius mdRadius = BorderRadius.all(Radius.circular(md));
}

/// 动效时长（毫秒）。
abstract final class Motion {
  static const int instant = 120;
  static const int fast = 200;
  static const int normal = 320;
  static const int slow = 520;

  /// 页面级转场时长。
  static const int page = 380;

  /// 阶梯式延迟步长（用于列表逐项入场）。
  static const int stagger = 45;
}

/// 缓动曲线。
///
/// 命名带 `Vela` 前缀是为了避开 Flutter 内置的 `Curves` 类。
abstract final class VelaCurves {
  /// 标准缓入缓出。
  static const Curve standard = Curves.easeOutCubic;

  /// 强调（弹性收敛，适合按钮与卡片入场）。
  static const Curve emphasized = Curves.easeOutBack;

  /// 快速进入、缓慢退出（用于内容切换）。
  static const Curve content = Cubic(0.2, 0.0, 0.0, 1.0);
}

/// 布局断点阈值（逻辑像素）。
///
/// 宽度小于 [medium] 视为紧凑（手机竖屏）；大于等于 [expanded]
/// 视为宽屏（桌面），使用双栏/三栏布局。
abstract final class Breakpoints {
  static const double medium = 640;
  static const double expanded = 1000;
  static const double wide = 1400;

  /// 桌面窗口最小安全尺寸：低于此值内容会被挤压，
  /// 平台层会限制窗口不能缩到比这更小。
  static const double minWindowWidth = 880;
  static const double minWindowHeight = 600;
}
