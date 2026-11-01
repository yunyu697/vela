/// 配置管理页：多配置的浏览、筛选、批量操作与生命周期管理。
///
/// 布局自适应：
///  - 宽屏：两列卡片网格
///  - 中屏 / 窄屏：单列卡片
///
/// 数据全部来自 [ProfileRepository]（应用级单例），页面只监听变更事件，
/// 不再各自读盘——原先三个页面各开一次 KvStore、各自 JSON 解析全量配置，
/// 是首帧耗时与操作卡顿的共同来源之一。
library;

import 'package:flutter/material.dart';

import '../../core/ir/profile.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/profile_repository.dart';
import '../../ui/adaptive.dart';
import '../../ui/tokens.dart';
import '../../ui/vela_theme.dart';
import '../../ui/widgets.dart';
import '../run/core_manager.dart';
import '../wizard/wizard_page.dart';

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, required this.onOpenRun});

  final VoidCallback onOpenRun;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  final _repo = ProfileRepository.instance;

  /// 搜索关键词。
  String _query = '';

  /// 选中的标签（空 = 不限）。
  String _tag = '';

  /// 只看收藏。
  bool _favoriteOnly = false;

  /// 排序方式。
  ProfileSort _sort = ProfileSort.recent;

  /// 批量选择模式。
  bool _selectMode = false;

  /// 批量选择中已选中的配置 id。
  final Set<String> _selected = {};

  /// 顶部筛选栏是否展开。
  bool _filtersExpanded = false;

  @override
  void initState() {
    super.initState();
    CoreManager.instance.addListener(_onCoreChanged);
    _repo.addListener(_onRepoChanged);
    _repo.init();
  }

  void _onCoreChanged() {
    if (mounted) setState(() {});
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    CoreManager.instance.removeListener(_onCoreChanged);
    _repo.removeListener(_onRepoChanged);
    super.dispose();
  }

  List<Profile> get _visible => _repo.filter(
        query: _query,
        tag: _tag,
        favoriteOnly: _favoriteOnly,
        sort: _sort,
      );

  // ------------------------------------------------------------ 操作

  Future<void> _createNew() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WizardPage()),
    );
  }

  Future<void> _start(Profile profile) async {
    final manager = CoreManager.instance;
    if (manager.isActive) {
      _toast('内核已在运行，请先停止当前内核');
      return;
    }
    try {
      await manager.start(profile, runDir: await AppPaths.supportDir());
      await _repo.markUsed(profile.id);
      if (!mounted) return;
      _toast('「${profile.name}」已启动');
      widget.onOpenRun();
    } catch (e) {
      if (!mounted) return;
      _toast('启动失败：$e');
    }
  }

  Future<void> _delete(Profile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定要删除「${profile.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteProfile(profile.id);
    _selected.remove(profile.id);
  }

  Future<void> _rename(Profile profile) async {
    final controller =
        TextEditingController(text: _repo.metaOf(profile.id).displayName(profile));
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '显示名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _repo.renameProfile(profile.id, name.trim());
  }

  Future<void> _duplicate(Profile profile) async {
    final copy = await _repo.duplicateProfile(profile.id);
    if (!mounted) return;
    _toast('已复制为「${copy.name}」');
  }

  Future<void> _toggleFavorite(Profile profile) async {
    await _repo.toggleFavorite(profile.id);
  }

  Future<void> _editTags(Profile profile) async {
    final meta = _repo.metaOf(profile.id);
    final result = await showDialog<_TagEditResult>(
      context: context,
      builder: (ctx) => _TagEditorDialog(
        initial: meta.tags,
        note: meta.note,
        suggestions: _repo.allTags,
      ),
    );
    if (result == null) return;
    await _repo.updateMeta(
      profile.id,
      tags: result.tags,
      note: result.note,
    );
  }

  Future<void> _export(List<String> ids) async {
    try {
      final path = await _repo.exportToFile(ids);
      if (!mounted) return;
      _toast('已导出到 $path');
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败：$e');
    }
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入配置'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            maxLines: 10,
            minLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              labelText: '粘贴导出的 JSON',
              hintText: '{ "velaProfile": 1, "profile": { ... } }',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      final ids = await _repo.importFromText(text);
      if (!mounted) return;
      _toast('已导入 ${ids.length} 个配置');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    }
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${ids.length} 个配置'),
        content: const Text('此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in ids) {
      await _repo.deleteProfile(id);
    }
    _selected.clear();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final scope = AdaptiveScope.of(context);
    final visible = _visible;

    return Material(
      // 透明 Material：本页根部并非 Scaffold，而搜索框 / FilterChip
      // 都要求祖先存在 Material（否则断言失败、无法绘制水波纹）。
      type: MaterialType.transparency,
      child: Column(
        children: [
          _buildHeader(context, scope, visible.length),
          _buildFilterBar(context),
          Expanded(
            child: visible.isEmpty
                ? _buildEmpty(context, scope)
                : _buildList(context, scope, visible),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
      BuildContext context, AdaptiveScope scope, int count) {
    final pad = scope.size.isCompact ? Insets.pageCompact : Insets.page;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, Insets.md),
      child: Row(
        children: [
          Expanded(
            child: PageHeading(
              title: '配置',
              subtitle: _selectMode
                  ? '已选中 ${_selected.length} 项'
                  : '共 $count 个配置',
            ),
          ),
          const SizedBox(width: Insets.md),
          if (_selectMode) ...[
            OutlinedButton.icon(
              onPressed: _selected.isEmpty
                  ? null
                  : () => _export(_selected.toList()),
              icon: const Icon(Icons.download_rounded, size: 17),
              label: const Text('导出'),
            ),
            const SizedBox(width: Insets.sm),
            OutlinedButton.icon(
              onPressed:
                  _selected.isEmpty ? null : () => _deleteSelected(),
              icon: const Icon(Icons.delete_outline_rounded, size: 17),
              label: const Text('删除'),
              style: OutlinedButton.styleFrom(
                // 边框跟文字同色：只染文字会得到「灰框红字」，像是两套样式
                // 拼在一起。
                foregroundColor: Theme.of(context).colorScheme.error,
                side: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .error
                      .withValues(alpha: 0.45),
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            IconButton(
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '退出多选',
            ),
          ] else ...[
            IconButton(
              onPressed: () => setState(() => _selectMode = true),
              icon: const Icon(Icons.checklist_rounded, size: 20),
              tooltip: '多选',
            ),
            IconButton(
              onPressed: _import,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: '导入配置',
            ),
            const SizedBox(width: Insets.sm),
            VelaPrimaryButton(
              label: '新建',
              icon: Icons.add_rounded,
              onPressed: _createNew,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final theme = Theme.of(context);
    final tags = _repo.allTags;
    final scope = AdaptiveScope.of(context);
    final pad = scope.size.isCompact ? Insets.pageCompact : Insets.page;

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: theme.textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    hintText: '搜索配置名称、标签或备注',
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: Insets.md,
                      vertical: Insets.md,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              IconButton(
                onPressed: () =>
                    setState(() => _filtersExpanded = !_filtersExpanded),
                icon: Icon(
                  _filtersExpanded
                      ? Icons.expand_less_rounded
                      : Icons.tune_rounded,
                  size: 20,
                ),
                tooltip: '筛选与排序',
                style: IconButton.styleFrom(
                  backgroundColor: _filtersExpanded
                      ? theme.colorScheme.surfaceContainerHigh
                      : Colors.transparent,
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  minimumSize: const Size(40, 40),
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: Motion.fast),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _filtersExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: Insets.md),
                    child: _buildFilters(context, tags),
                  )
                : const SizedBox.shrink(),
          ),
          if (_tag.isNotEmpty || _favoriteOnly) ...[
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                if (_favoriteOnly)
                  Padding(
                    padding: const EdgeInsets.only(right: Insets.sm),
                    child: InputChip(
                      label: const Text('仅收藏'),
                      avatar: const Icon(Icons.star_rounded, size: 16),
                      onDeleted: () => setState(() => _favoriteOnly = false),
                    ),
                  ),
                if (_tag.isNotEmpty)
                  InputChip(
                    label: Text(_tag),
                    avatar: const Icon(Icons.label_rounded, size: 16),
                    onDeleted: () => setState(() => _tag = ''),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context, List<String> tags) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: const Text('仅收藏'),
              avatar: const Icon(Icons.star_rounded, size: 16),
              selected: _favoriteOnly,
              onSelected: (v) => setState(() => _favoriteOnly = v),
            ),
            for (final t in tags)
              FilterChip(
                label: Text(t),
                avatar: const Icon(Icons.label_rounded, size: 16),
                selected: _tag == t,
                onSelected: (v) => setState(() => _tag = v ? t : ''),
              ),
          ],
        ),
        const SizedBox(height: Insets.md),
        Row(
          children: [
            Text('排序', style: theme.textTheme.labelLarge),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Wrap(
                spacing: Insets.xs,
                children: [
                  for (final s in ProfileSort.values)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: _sort == s,
                      onSelected: (_) => setState(() => _sort = s),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context, AdaptiveScope scope) {
    final hasFilters =
        _query.isNotEmpty || _tag.isNotEmpty || _favoriteOnly;
    if (hasFilters) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有匹配的配置',
        message: '换个关键词，或清除筛选条件试试。',
        action: OutlinedButton.icon(
          onPressed: () => setState(() {
            _query = '';
            _tag = '';
            _favoriteOnly = false;
          }),
          icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
          label: const Text('清除筛选'),
        ),
      );
    }
    return EmptyState(
      icon: Icons.folder_open_rounded,
      title: '还没有配置',
      message: '用引导式向导创建第一个配置：选择内核、导入订阅、'
          '挑选规则集，几步即可生成。',
      action: VelaPrimaryButton(
        label: '创建新配置',
        icon: Icons.add_rounded,
        onPressed: _createNew,
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AdaptiveScope scope,
    List<Profile> visible,
  ) {
    final columns = scope.size.isCompact ? 1 : (scope.size.isMedium ? 1 : 2);

    // 注意：LayoutBuilder 必须放在 ListView **内部**。
    // 若放在外面，拿到的 maxWidth 不含 ListView 的左右内边距，
    // 算出的列宽会大于实际可用宽度，Wrap 判定放不下就提前换行，
    // 宽屏下右半屏会整片空置。
    return ListView(
      padding: EdgeInsets.fromLTRB(
        scope.size.isCompact ? Insets.pageCompact : Insets.page,
        0,
        scope.size.isCompact ? Insets.pageCompact : Insets.page,
        Insets.xxl,
      ),
      children: [
        LayoutBuilder(
          builder: (context, c) {
            const gap = Insets.md;
            final w = (c.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < visible.length; i++)
                  SizedBox(
                    width: w,
                    child: StaggeredEntrance(
                      index: i,
                      child: _ProfileCard(
                        profile: visible[i],
                        meta: _repo.metaOf(visible[i].id),
                        running: CoreManager.instance.isActive,
                        active: CoreManager.instance.activeProfile?.id ==
                            visible[i].id,
                        selectMode: _selectMode,
                        selected: _selected.contains(visible[i].id),
                        onToggleSelect: () => _toggleSelect(visible[i]),
                        onStart: () => _start(visible[i]),
                        onFavorite: () => _toggleFavorite(visible[i]),
                        onRename: () => _rename(visible[i]),
                        onDuplicate: () => _duplicate(visible[i]),
                        onTags: () => _editTags(visible[i]),
                        onExport: () => _export([visible[i].id]),
                        onDelete: () => _delete(visible[i]),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  void _toggleSelect(Profile profile) {
    setState(() {
      if (!_selected.remove(profile.id)) _selected.add(profile.id);
    });
  }
}

/// 配置卡片。
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.meta,
    required this.running,
    required this.active,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onStart,
    required this.onFavorite,
    required this.onRename,
    required this.onDuplicate,
    required this.onTags,
    required this.onExport,
    required this.onDelete,
  });

  final Profile profile;
  final ProfileMeta meta;
  final bool running;
  final bool active;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onStart;
  final VoidCallback onFavorite;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onTags;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSingbox = profile.coreKind == CoreKind.singbox;
    final coreColor = VelaColors.resolve(
      isSingbox ? VelaColors.azure : VelaColors.violet,
      theme.brightness,
    );
    final accent = Color(
      ProfileMetaPalette.colorAt(meta.colorIndex),
    );

    return VelaCard(
      // 点击卡片 = 启动（卡片上没有别的高频动作，空着反而让人以为坏了）
      onTap: selectMode ? onToggleSelect : onStart,
      borderColor: selected
          ? theme.colorScheme.primary
          : (meta.favorite ? accent.withValues(alpha: 0.45) : null),
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectMode)
                Padding(
                  padding: const EdgeInsets.only(right: Insets.sm, top: 1),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            meta.displayName(profile),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (meta.favorite) ...[
                          const SizedBox(width: Insets.xs + 2),
                          Icon(Icons.star_rounded, size: 14, color: accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: Insets.sm - 2),
                    Row(
                      children: [
                        StatusPill(
                          label: isSingbox ? 'sing-box' : 'mihomo',
                          color: coreColor,
                        ),
                        if (active) ...[
                          const SizedBox(width: Insets.xs + 2),
                          StatusPill(
                            label: '运行中',
                            color: VelaColors.resolve(
                              VelaColors.emerald,
                              theme.brightness,
                            ),
                            pulsing: true,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (!selectMode)
                _ProfileMenu(
                  favorite: meta.favorite,
                  onFavorite: onFavorite,
                  onRename: onRename,
                  onDuplicate: onDuplicate,
                  onTags: onTags,
                  onExport: onExport,
                  onDelete: onDelete,
                ),
            ],
          ),
          if (meta.tags.isNotEmpty || meta.note.isNotEmpty) ...[
            const SizedBox(height: Insets.sm + 2),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final t in meta.tags)
                  _TagChip(label: t, color: accent),
              ],
            ),
            if (meta.note.isNotEmpty) ...[
              const SizedBox(height: Insets.xs + 2),
              Text(
                meta.note,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
          const SizedBox(height: Insets.md),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: Insets.md),
          // 四项关键指标压成一行，替代原来四行「虚线牵引」的信息行：
          // 同样的信息量，高度从约 110px 降到 40px。
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '节点',
                  value: '${profile.nodes.length}',
                  compact: true,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: '分组',
                  value: '${profile.groups.length}',
                  compact: true,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: '规则',
                  value: '${profile.rules.length}',
                  compact: true,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'DNS',
                  value: profile.dns.mode.label,
                  compact: true,
                ),
              ),
            ],
          ),
          // 多选时不显示动作行：右上角的 ⋮ 菜单已经藏起来了，这里再留一颗
          // 「启动」按钮既不一致，也容易在勾选时误触。
          if (!selectMode) ...[
            const SizedBox(height: Insets.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    meta.useCount > 0
                        ? '已启动 ${meta.useCount} 次'
                            '${meta.lastUsedAt != null ? ' · ${_ago(meta.lastUsedAt!)}' : ''}'
                        : '尚未启动过',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Insets.sm),
                if (running && !active)
                  Text(
                    '已有内核在运行',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  )
                else
                  VelaPrimaryButton(
                    label: active ? '查看' : '启动',
                    icon: active
                        ? Icons.chevron_right_rounded
                        : Icons.play_arrow_rounded,
                    tone: active ? VelaButtonTone.quiet : VelaButtonTone.primary,
                    onPressed: onStart,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${diff.inDays ~/ 30} 个月前';
  }
}

/// 配置卡片右上角的更多操作菜单。
class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu({
    required this.favorite,
    required this.onFavorite,
    required this.onRename,
    required this.onDuplicate,
    required this.onTags,
    required this.onExport,
    required this.onDelete,
  });

  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onTags;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, size: 19),
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'favorite':
            onFavorite();
          case 'rename':
            onRename();
          case 'duplicate':
            onDuplicate();
          case 'tags':
            onTags();
          case 'export':
            onExport();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'favorite',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              favorite ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 19,
            ),
            title: Text(favorite ? '取消收藏' : '收藏'),
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_rounded, size: 19),
            title: Text('重命名'),
          ),
        ),
        const PopupMenuItem(
          value: 'duplicate',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy_rounded, size: 19),
            title: Text('复制'),
          ),
        ),
        const PopupMenuItem(
          value: 'tags',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.label_outline_rounded, size: 19),
            title: Text('标签与备注'),
          ),
        ),
        const PopupMenuItem(
          value: 'export',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download_rounded, size: 19),
            title: Text('导出'),
          ),
        ),
        // 破坏性操作与上面四项之间隔一条线：只靠红色区分，在
        // 「导出」正下方紧挨着「删除」时仍容易点错。
        const PopupMenuDivider(height: 9),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.delete_outline_rounded,
              size: 19,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ],
    );
  }
}

/// 小标签胶囊。
class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        // 只留描边 + 彩色文字：标签是二级信息，填充色块一多，
        // 卡片顶部就会形成一条彩色噪点带。
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Insets.xs + 1),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签 + 备注编辑对话框。
class _TagEditResult {
  const _TagEditResult(this.tags, this.note);
  final List<String> tags;
  final String note;
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({
    required this.initial,
    required this.note,
    required this.suggestions,
  });

  final List<String> initial;
  final String note;
  final List<String> suggestions;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final Set<String> _tags = widget.initial.toSet();
  late final _noteCtrl = TextEditingController(text: widget.note);
  final _inputCtrl = TextEditingController();

  @override
  void dispose() {
    _noteCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  void _add(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return;
    setState(() => _tags.add(t));
    _inputCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('标签与备注'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_tags.isNotEmpty) ...[
              Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: [
                  for (final t in _tags)
                    InputChip(
                      label: Text(t),
                      onDeleted: () => setState(() => _tags.remove(t)),
                    ),
                ],
              ),
              const SizedBox(height: Insets.md),
            ],
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    decoration: const InputDecoration(
                      labelText: '添加标签',
                      isDense: true,
                    ),
                    onSubmitted: _add,
                  ),
                ),
                const SizedBox(width: Insets.sm),
                IconButton(
                  onPressed: () => _add(_inputCtrl.text),
                  icon: const Icon(Icons.add_rounded),
                  tooltip: '添加',
                ),
              ],
            ),
            if (widget.suggestions.isNotEmpty) ...[
              const SizedBox(height: Insets.md),
              Text('已有标签', style: theme.textTheme.labelMedium),
              const SizedBox(height: Insets.xs),
              Wrap(
                spacing: Insets.xs,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(
                      label: Text(s),
                      onPressed: () => setState(() => _tags.add(s)),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Insets.lg),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '例如：给公司网络用',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _TagEditResult(_tags.toList(), _noteCtrl.text.trim()),
          ),
          child: const Text('保存标签'),
        ),
      ],
    );
  }
}
