/// 设置页：把散落在托盘菜单、快捷键与配置文件里的开关收进一处。
///
/// 设计取向：**只放用户真的会改的开关**。端口、DNS 服务器、分流规则这些
/// 属于「配置」维度（每份配置各自不同），不该混进应用设置里——那样用户
/// 会分不清改的是全局还是当前配置。
///
/// 这里的每一项都是「应用级、全局唯一」的：外观、启动行为、数据位置。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/desktop_integrations.dart';
import '../../core/platform/system_proxy.dart';
import '../../core/settings/app_settings.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/profile_repository.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// 与 pubspec.yaml 的 version 保持一致（没有引入 package_info_plus：
/// 为一个字符串加一个原生插件不划算，改版本号时同步改这里）。
const String kAppVersion = '0.1.0';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, @visibleForTesting this.debugDataDir});

  /// 仅测试用：钉住「数据目录」那一行。
  ///
  /// 真实路径里带着随机临时目录名，黄金图每次都不同——不钉住的话这条
  /// 断言只能靠 --update-goldens 一遍遍刷新，等于没守住。
  @visibleForTesting
  final String? debugDataDir;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = AppSettings.instance;
  final _desktop = DesktopIntegrations.instance;
  final _repo = ProfileRepository.instance;

  String _dataDir = '';

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _desktop.addListener(_onChanged);
    _repo.addListener(_onChanged);
    // 仓库通常由外壳先初始化好，但这里再调一次是幂等的：
    // 页面自己也不该依赖「谁先打开」来决定统计数是不是 0。
    _repo.init();
    _loadPath();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPath() async {
    final pinned = widget.debugDataDir;
    if (pinned != null) {
      setState(() => _dataDir = pinned);
      return;
    }
    try {
      final dir = await AppPaths.supportDir();
      if (mounted) setState(() => _dataDir = dir);
    } catch (_) {
      // 拿不到路径就不显示这一行，不影响其它设置
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _desktop.removeListener(_onChanged);
    _repo.removeListener(_onChanged);
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _copyPath() async {
    if (_dataDir.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _dataDir));
    _toast('已复制数据目录');
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    final compact = scope.size.isCompact;
    final pad = compact ? Insets.pageCompact : Insets.page;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, Insets.xxxl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHeading(
                title: '设置',
                subtitle: '外观、启动行为与数据位置',
              ),
              const SizedBox(height: Insets.xl),
              _appearanceCard(context),
              const SizedBox(height: Insets.lg),
              _startupCard(context),
              const SizedBox(height: Insets.lg),
              _dataCard(context),
              const SizedBox(height: Insets.lg),
              _aboutCard(context),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 外观

  Widget _appearanceCard(BuildContext context) {
    final theme = Theme.of(context);
    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: '外观',
            subtitle: '跟随系统时按操作系统的明暗自动切换',
          ),
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              for (final mode in ThemeMode.values) ...[
                if (mode != ThemeMode.values.first)
                  const SizedBox(width: Insets.sm),
                Expanded(
                  child: _Segment(
                    label: mode.label,
                    selected: _settings.themeMode == mode,
                    onTap: () => _settings.setThemeMode(mode),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Insets.md),
          Text(
            '当前：${_settings.themeMode.label}'
            '${_settings.themeMode == ThemeMode.system ? '（由系统决定）' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 启动行为

  Widget _startupCard(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[
      _SwitchRow(
        title: '启动时自动启动上次配置',
        subtitle: '打开应用即连接，不必每次手动点启动；关闭时只打开界面。',
        value: _settings.autoStartLastProfile,
        onChanged: (v) => _settings.setAutoStartLastProfile(v),
      ),
    ];

    // 下面两项只有桌面端有意义：移动端没有「系统代理」这个概念
    // （靠 TUN 接管），也不支持开机自启。
    if (_desktop.isDesktop) {
      if (SystemProxy.supported) {
        rows.add(_divider(theme));
        rows.add(_SwitchRow(
          title: '系统代理',
          subtitle: '内核运行时把系统代理指向 mixed 端口，停止时自动还原。',
          value: _desktop.sysProxyPref,
          onChanged: (v) => _desktop.setSysProxyPref(v),
        ));
      }
      rows.add(_divider(theme));
      rows.add(_SwitchRow(
        title: '开机自启',
        subtitle: '登录系统后在后台启动 Vela，不打开主窗口。',
        value: _desktop.autostartPref,
        onChanged: (v) async {
          await _desktop.setAutostartPref(v);
          // 系统侧注册失败时 setAutostartPref 会把状态回滚，
          // 这里补一句提示，否则用户会以为开关坏了。
          if (_desktop.autostartPref != v) {
            _toast('系统没有接受开机自启设置，请检查权限');
          }
        },
      ));
    }

    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: '启动与网络'),
          const SizedBox(height: Insets.md),
          ...rows,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 数据

  Widget _dataCard(BuildContext context) {
    final theme = Theme.of(context);
    final nodeCount =
        _repo.profiles.fold<int>(0, (sum, p) => sum + p.nodes.length);

    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: '数据',
            subtitle: '全部存放在本机，不上传任何服务器',
          ),
          const SizedBox(height: Insets.md),
          if (_dataDir.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('数据目录', style: theme.textTheme.bodySmall),
                      const SizedBox(height: Insets.xs),
                      Tooltip(
                        message: _dataDir,
                        waitDuration: const Duration(milliseconds: 500),
                        child: Text(
                          _dataDir,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                IconButton(
                  onPressed: _copyPath,
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  tooltip: '复制路径',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            _divider(theme),
          ],
          InfoRow(label: '配置', value: '${_repo.profiles.length} 份'),
          InfoRow(label: '节点', value: '$nodeCount 个'),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 关于

  Widget _aboutCard(BuildContext context) {
    final theme = Theme.of(context);
    return VelaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: '关于'),
          const SizedBox(height: Insets.md),
          InfoRow(label: '版本', value: kAppVersion, monospace: true),
          const InfoRow(label: '内核', value: 'mihomo · sing-box'),
          const SizedBox(height: Insets.sm),
          Text(
            'Vela 只在本机运行，配置与节点凭据用系统钥匙串加密保存。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _divider(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.md),
        child: Divider(height: 1, color: theme.colorScheme.outlineVariant),
      );
}

/// 分段选择：一排等宽选项，选中项用主色描边 + 实心圆点。
///
/// 与运行页的内核切换保持同一套视觉，避免「同一个交互两种长相」。
class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? theme.colorScheme.surfaceContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: Insets.xs + 2),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开关行：左标题 + 说明，右开关。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.textTheme.bodyMedium),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
        const SizedBox(width: Insets.md),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
