/// 响应式布局基础设施。
///
/// 提供三件事：
///  1. 断点判定（紧凑 / 中等 / 宽屏 / 超宽）与横竖屏识别
///  2. [AdaptiveScaffold] 自适应外壳：宽屏左侧导航、中屏图标栏、窄屏底部栏
///  3. [AnimatedSwitcher] 化的内容切换与统一的入场动画
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 是否桌面平台（macOS / Windows / Linux）。
///
/// 桌面端窗口有最小宽度约束，compact 档（底部导航）不应出现；
/// 用于窗口瞬态尺寸的钳制。getter 而非 final：测试里
/// `debugDefaultTargetPlatformOverride` 需要能实时生效。
bool get kIsDesktop => !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// 窗口尺寸档位。
enum WindowSize {
  /// 手机竖屏 / 窄窗口。
  compact,

  /// 中等窗口（平板横屏、小窗桌面）。
  medium,

  /// 宽屏桌面。
  expanded,

  /// 超宽桌面。
  wide;

  bool get isCompact => this == WindowSize.compact;
  bool get isMedium => this == WindowSize.medium;
  bool get isExpanded => this == WindowSize.expanded || this == WindowSize.wide;

  /// 是否双栏布局。
  bool get isTwoPane => index >= WindowSize.expanded.index;
}

/// 依据可用宽度判定尺寸档位。
WindowSize windowSizeFor(double width) {
  // 宽度非正（窗口最小化/恢复过程的瞬时约束）时按中等档处理：
  // 若回落到 compact，侧栏会瞬间消失、底部栏闪现，视觉上像「侧栏丢了」。
  if (width <= 0) return WindowSize.medium;
  if (width >= Breakpoints.wide) return WindowSize.wide;
  if (width >= Breakpoints.expanded) return WindowSize.expanded;
  if (width >= Breakpoints.medium) return WindowSize.medium;
  // 桌面端永不进入 compact：桌面窗口最小宽度（880）远大于
  // compact 阈值（640），compact 本不该出现；但窗口动画、全屏过渡、
  // Stage Manager 等场景可能短暂上报小尺寸，此时钳制为 medium
  // 保证侧栏始终可见（「侧栏消失」的另一来源）。
  if (kIsDesktop) return WindowSize.medium;
  return WindowSize.compact;
}

/// 屏幕方向。
enum VelaOrientation { portrait, landscape }

/// 判定横竖屏：宽高比 > 1 视为横屏。
///
/// 依据的是**内容区**尺寸而非物理屏幕，因此在桌面端把窗口拉宽
/// 同样会切到横屏布局，这是期望行为（窗口形状决定布局）。
VelaOrientation orientationFor(Size size) {
  if (size.width <= 0 || size.height <= 0) return VelaOrientation.portrait;
  return size.width > size.height ? VelaOrientation.landscape : VelaOrientation.portrait;
}

/// 自适应布局上下文。
///
/// 通过 [AdaptiveBuilder] 或 [AdaptiveScope.of] 取得。
class AdaptiveScope extends InheritedWidget {
  const AdaptiveScope({
    super.key,
    required this.size,
    required this.orientation,
    required this.mediaQuery,
    required super.child,
  });

  final WindowSize size;
  final VelaOrientation orientation;
  final MediaQueryData mediaQuery;

  bool get isLandscape => orientation == VelaOrientation.landscape;
  bool get isPortrait => orientation == VelaOrientation.portrait;

  /// 供后代读取的便捷方法。
  ///
  /// 若不在 [AdaptiveBuilder] 内（例如在弹窗、对话框里），退化为
  /// 按当前 MediaQuery 推导的默认值，保证 UI 不会因此崩溃。
  static AdaptiveScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AdaptiveScope>();
    if (scope != null) return scope;
    final mq = MediaQuery.maybeOf(context) ?? const MediaQueryData();
    return AdaptiveScope(
      size: windowSizeFor(mq.size.width),
      orientation: orientationFor(mq.size),
      mediaQuery: mq,
      child: const SizedBox.shrink(),
    );
  }

  @override
  bool updateShouldNotify(AdaptiveScope oldWidget) =>
      size != oldWidget.size ||
      orientation != oldWidget.orientation ||
      // 只比较尺寸相关字段：MediaQueryData 的 == 会逐字段比对整个对象
      // （含 textScaler / platformBrightness 等），在高频重建路径上不划算。
      mediaQuery.size != oldWidget.mediaQuery.size ||
      mediaQuery.padding != oldWidget.mediaQuery.padding;
}

/// 注入自适应上下文的包装器。
class AdaptiveBuilder extends StatelessWidget {
  const AdaptiveBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, AdaptiveScope scope) builder;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = windowSizeFor(constraints.maxWidth);
        final orientation = orientationFor(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        return AdaptiveScope(
          size: size,
          orientation: orientation,
          mediaQuery: mq,
          // 必须用内层 Builder 重新取一次 scope：此处传入的 context 位于
          // 新建的 AdaptiveScope **之上**，直接 AdaptiveScope.of(context)
          // 拿到的是外层（甚至兜底）的档位，而不是按本区域宽度算出的档位。
          child: Builder(
            builder: (inner) => builder(inner, AdaptiveScope.of(inner)),
          ),
        );
      },
    );
  }
}

/// 自适应外壳。
///
/// 根据窗口尺寸在三种导航形态之间切换，切换带过渡动画：
///  - [WindowSize.wide] / [WindowSize.expanded]：左侧扩展导航栏（带文字）
///  - [WindowSize.medium]：左侧图标导航栏（仅图标）
///  - [WindowSize.compact]：底部导航栏
///
/// [content] 是主内容区，[rail] 可选地放在导航栏下方的扩展区
/// （宽屏下作为侧栏，例如向导的步骤列表）。
class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.body,
    this.destinations = const [],
    this.selectedIndex = 0,
    this.onDestinationSelected,
    this.rail,
    this.floatingActionButton,
    this.background,
    this.footer,
  });

  final Widget body;

  /// 导航目的地（标题 + 图标）。
  final List<AdaptiveDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  /// 宽屏侧栏内容。
  final Widget? rail;
  final Widget? floatingActionButton;
  final Widget? background;

  /// 侧栏底部常驻区域（如主题切换、设置入口）。
  ///
  /// 只在非紧凑布局（有侧栏）时渲染：紧凑布局的底部导航已被
  /// 目的地占满，额外的全局入口由调用方自行安排。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (background != null) Positioned.fill(child: background!),
          SafeArea(
            bottom: scope.size.isCompact,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!scope.size.isCompact)
                  _SideNavigation(
                    key: const ValueKey('vela-side-nav'),
                    destinations: destinations,
                    selectedIndex: selectedIndex,
                    onSelected: onDestinationSelected,
                    extended: scope.size == WindowSize.wide ||
                        scope.size == WindowSize.expanded,
                    footer: footer,
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (rail != null && scope.size.isTwoPane) rail!,
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: scope.size.isCompact && destinations.length > 1
          ? _BottomNavigation(
              key: const ValueKey('vela-bottom-nav'),
              destinations: destinations,
              selectedIndex: selectedIndex,
              onSelected: onDestinationSelected,
            )
          : null,
      floatingActionButton: floatingActionButton,
    );
  }
}

/// 导航目的地描述。
class AdaptiveDestination {
  const AdaptiveDestination({
    required this.label,
    required this.icon,
    this.selectedIcon,
    this.badge,
  });

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final String? badge;
}

/// 侧边导航（宽屏 / 中屏）。
class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.extended,
    this.footer,
  });

  final List<AdaptiveDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onSelected;
  final bool extended;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: extended ? 208 : 76,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Insets.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
            child: Row(
              children: [
                const VelaLogoMark(size: 30),
                if (extended) ...[
                  const SizedBox(width: Insets.md),
                  Text(
                    'Vela',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Insets.xl),
          // 导航项固定只有几项，用 Column 而非 ListView：
          // ListView 会引入 viewport / scrollable / cacheExtent 等一整套
          // 滚动机制，对 3 个静态项纯属额外开销。
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.xs),
                      child: _NavItem(
                        destination: destinations[i],
                        selected: i == selectedIndex,
                        extended: extended,
                        onTap: onSelected == null
                            ? null
                            : () => onSelected!(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                Insets.sm,
                Insets.md,
                Insets.md,
              ),
              child: footer,
            ),
          const SizedBox(height: Insets.lg),
        ],
      ),
    );
  }
}

/// 侧栏单个导航项。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final AdaptiveDestination destination;
  final bool selected;
  final bool extended;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
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
            mainAxisAlignment: extended
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                selected
                    ? (destination.selectedIcon ?? destination.icon)
                    : destination.icon,
                size: 22,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              if (extended) ...[
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    destination.label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部导航（窄屏）。
class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<AdaptiveDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: selectedIndex.clamp(0, destinations.length - 1),
      onDestinationSelected: onSelected ?? (_) {},
      destinations: [
        for (final d in destinations)
          NavigationDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon ?? d.icon),
            label: d.label,
          ),
      ],
    );
  }
}

/// Vela 品牌标识：双翼帆形。
///
/// 用 CustomPaint 绘制矢量图形，保证任意尺寸下边缘锐利，
/// 与系统应用图标的绘制语言一致。
class VelaLogoMark extends StatelessWidget {
  const VelaLogoMark({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SailPainter(
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SailPainter extends CustomPainter {
  _SailPainter({required this.color});

  final Color color;

  /// 与应用图标一致：正面双帆 + 中央桅杆细缝 + 外凸帆腹。
  ///
  /// 右帆的三次贝塞尔控制点（左帆为其水平镜像）：
  /// (0.530, 0.175) → (0.557, 0.450) → (0.844, 0.660) → (0.885, 0.790)
  static const _p0 = Offset(0.530, 0.175);
  static const _p1 = Offset(0.557, 0.450);
  static const _p2 = Offset(0.844, 0.660);
  static const _p3 = Offset(0.885, 0.790);

  /// 桅杆底角（帆面内侧下端）。
  static const _pMastBottom = Offset(0.530, 0.790);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (final mirrored in [false, true]) {
      Offset t(Offset p) => Offset(
            mirrored ? (1.0 - p.dx) * w : p.dx * w,
            p.dy * h,
          );
      final path = Path()
        ..moveTo(t(_p0).dx, t(_p0).dy)
        ..cubicTo(
          t(_p1).dx, t(_p1).dy,
          t(_p2).dx, t(_p2).dy,
          t(_p3).dx, t(_p3).dy,
        )
        // 沿底边回到桅杆，再沿桅杆回到顶端，闭合成帆面
        ..lineTo(t(_pMastBottom).dx, t(_pMastBottom).dy)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SailPainter oldDelegate) => oldDelegate.color != color;
}

/// 统一的内容切换动画：淡入 + 轻微位移。
///
/// 页面之间、步骤之间共用，保证转场语感一致。
///
/// 性能要点：不再叠加 [ScaleTransition]。缩放会让整个页面子树在每帧
/// 施加一次仿射变换（含文字栅格化重算），而 0.985→1.0 的幅度在视觉
/// 上几乎不可察。淡入 + 位移已足够表达「切页」这一语义。
class VelaPageTransition extends StatelessWidget {
  const VelaPageTransition({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: Motion.page),
    this.offset = const Offset(0, 0.04),
  });

  final Widget child;
  final Duration duration;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // AnimatedSwitcher 默认把新旧内容居中叠放，会让页面内容整体下沉；
      // 这里改为顶部对齐，符合「内容从顶部开始」的常规阅读习惯。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: offset,
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// 逐项入场动画：列表项按索引依次淡入上浮。
///
/// 性能要点：入场动画只在**首次挂载**时播放一次。
///
/// 之前的实现用 [TweenAnimationBuilder]，它在每一帧都会调用 builder，
/// 于是整棵子树（概览页的 Hero、状态行、能力网格合计数百个 widget）
/// 被重建 30 次——实测概览页入场期 30 帧产生 532 次 widget 重建。
/// 现在改为**一个控制器驱动一次 Transform 变化**：子树只在挂载时构建
/// 一次，动画期间只有 [Transform] 的属性在变，不再触发任何 widget 重建。
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.enabled = true,
  });

  final int index;
  final Widget child;
  final bool enabled;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(
      milliseconds: Motion.normal + widget.index * Motion.stagger,
    ),
  );

  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _animation,
      // 只重建 Transform 本身；子树作为 child 传入，全程复用。
      child: widget.child,
      builder: (context, child) {
        final t = _animation.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

/// 页面背景：柔和的品牌渐变光斑。
///
/// 大面积色块 + 若干低透明度径向渐变，模拟 Apple 系应用的
/// 「材质」观感，同时保证正文对比度。
///
/// 性能要点：三个光斑是 400px 级别的径向渐变，若随内容一起重绘，
/// 每帧都要重新光栅化。这里用 [RepaintBoundary] 把背景隔离成独立层，
/// 内容变化时不会重绘背景。
class VelaBackdrop extends StatelessWidget {
  const VelaBackdrop({super.key, this.child, this.intensity = 1.0});

  final Widget? child;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF161924), Color(0xFF0D1017)]
                : const [Color(0xFFF7F8FC), Color(0xFFEFF1F8)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -140,
              left: -100,
              child: _Glow(
                color: scheme.primary.withValues(alpha: 0.16 * intensity),
                size: 420,
              ),
            ),
            Positioned(
              top: 80,
              right: -140,
              child: _Glow(
                color: scheme.secondary.withValues(alpha: 0.13 * intensity),
                size: 380,
              ),
            ),
            Positioned(
              bottom: -180,
              left: 120,
              child: _Glow(
                color: scheme.tertiary.withValues(alpha: 0.10 * intensity),
                size: 400,
              ),
            ),
            if (child != null) Positioned.fill(child: child!),
          ],
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
