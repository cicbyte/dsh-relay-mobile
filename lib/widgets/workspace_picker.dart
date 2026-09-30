import 'package:flutter/material.dart';

import '../dsh/dsh_client.dart';

/// 工作区选择结果：null=用默认（不传 cwd）；否则=选定的绝对路径。
typedef WorkspacePicked = void Function(String? path);

/// 工作区选择 BottomSheet：快速路径（置顶）+ 分层浏览（多盘符/单根并列、逐层下钻、面包屑返回）。
/// 跨平台：Windows 多盘符并列；mac/Linux 单根不显示盘符层。目录列表走插件 /mobile-bridge/workspace-list。
/// 效率优先：不搜索，纯浏览 + 快捷路径一键选。
class WorkspacePicker extends StatefulWidget {
  final DshClient client;
  final WorkspacePicked onPicked;
  final String? initialPath;
  // dir=选目录（默认）；file=选文件（列文件、点文件即选中，用于附件下载）
  final bool pickFile;

  const WorkspacePicker({
    super.key,
    required this.client,
    required this.onPicked,
    this.initialPath,
    this.pickFile = false,
  });

  /// 弹出选择器，返回选中路径（null=取消/用默认）。
  static Future<String?> show(BuildContext context, DshClient client, {String? initialPath, bool pickFile = false}) {
    return showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => WorkspacePicker(
          client: client,
          initialPath: initialPath,
          pickFile: pickFile,
          onPicked: (p) => Navigator.of(ctx).pop(p),
        ),
      ),
    );
  }

  @override
  State<WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends State<WorkspacePicker> {
  // 浏览栈：空 = 根层（列盘符/根）；否则 = 当前目录的子目录列表。
  List<Map<String, dynamic>> _dirs = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _quick = [];
  List<Map<String, dynamic>> _roots = [];
  String? _current; // 当前浏览目录（null=根层）
  String? _selected; // 已选路径
  bool _loading = true;
  String? _error;
  // 隐藏目录开关：当前固定 false（默认隐藏）；将来加「显示隐藏」开关时切换并重载。
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialPath;
    _loadRoots();
  }

  Future<void> _loadRoots() async {
    setState(() {
      _loading = true;
      _error = null;
      _current = null;
    });
    final r = await widget.client.workspaceRoots();
    if (!mounted) return;
    if (r == null) {
      setState(() {
        _loading = false;
        _error = '无法获取工作区（插件旧版本或未连接）';
      });
      return;
    }
    setState(() {
      _quick = List<Map<String, dynamic>>.from(r['quick'] ?? []);
      _roots = List<Map<String, dynamic>>.from(r['roots'] ?? []);
      _loading = false;
    });
  }

  Future<void> _open(String dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.client.workspaceList(dir, showHidden: _showHidden, withFiles: widget.pickFile);
    if (!mounted) return;
    if (r == null || r['ok'] != true) {
      setState(() {
        _loading = false;
        _error = '${r?['error'] ?? '无法读取目录'}';
      });
      return;
    }
    setState(() {
      _current = '${r['path']}';
      _dirs = List<Map<String, dynamic>>.from(r['dirs'] ?? []);
      _files = List<Map<String, dynamic>>.from(r['files'] ?? []);
      _loading = false;
    });
  }

  void _back() {
    // 根层无处可退；有 parent 回上层，无 parent（盘符/根的下一层）回根层
    final parent = _current == null ? null : _parentOf(_current!);
    if (parent == null) {
      setState(() {
        _current = null;
        _dirs = [];
      });
    } else {
      _open(parent);
    }
  }

  String? _parentOf(String p) {
    final norm = p.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) {
      // Windows 盘符根（C:/）回根层
      return null;
    }
    return norm.substring(0, idx);
  }

  void _pick(String path) {
    setState(() => _selected = path);
    widget.onPicked(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Column(
        children: [
          // 顶部把手 + 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('选择工作区', style: theme.textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => _pick(''),
                  child: const Text('用默认'),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => widget.onPicked(null),
                ),
              ],
            ),
          ),
          // 面包屑 / 返回
          if (_current != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: '上一层',
                    onPressed: _back,
                  ),
                  Expanded(
                    child: Text(
                      _current!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          // 列表
          Expanded(child: _buildList(theme)),
          // 底部：已选 + 确认
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selected == null || _selected!.isEmpty
                          ? '默认工作区'
                          : _selected!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => widget.onPicked(_selected),
                    child: const Text('确认'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final items = <Widget>[];

    // 根层：快路径置顶 + 盘符/根
    if (_current == null) {
      if (_quick.isNotEmpty) {
        items.add(_sectionHeader(theme, '快速工作区'));
        for (final q in _quick) {
          items.add(_dirTile('${q['path']}', '${q['label']}', Icons.bookmark_outline, quick: true));
        }
      }
      items.add(_sectionHeader(theme, _roots.length > 1 ? '磁盘' : '根目录'));
      for (final r in _roots) {
        items.add(_dirTile('${r['path']}', '${r['label']}', Icons.computer_outlined));
      }
    } else {
      // 子目录层：目录可下钻；file 模式下文件可选中（点选 = 下载目标）
      if (!widget.pickFile) {
        items.add(ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('（选择当前目录）'),
          onTap: () => _pick(_current!),
        ));
      }
      for (final d in _dirs) {
        items.add(_dirTile('${d['path']}', '${d['label']}', Icons.folder_outlined));
      }
      // file 模式：列文件，点选即选中
      for (final f in _files) {
        items.add(_fileTile('${f['path']}', '${f['label']}', f['size'] ?? 0));
      }
      if (_dirs.isEmpty && (_files.isEmpty || !widget.pickFile)) {
        items.add(const Padding(
          padding: EdgeInsets.all(24),
          child: Text('（空目录，可选当前目录或返回上层）', textAlign: TextAlign.center),
        ));
      }
    }

    return ListView(children: items);
  }

  Widget _sectionHeader(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title, style: theme.textTheme.labelLarge),
      );

  Widget _fileTile(String path, String label, dynamic size) {
    final selected = _selected == path;
    return ListTile(
      leading: Icon(Icons.insert_drive_file_outlined, color: Theme.of(context).colorScheme.primary),
      title: Text(label),
      subtitle: Text(_fmtSize(size), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected ? const Icon(Icons.check) : const Icon(Icons.download_outlined),
      selected: selected,
      onTap: () => _pick(path), // 文件点选即选中（下载目标）
    );
  }

  String _fmtSize(dynamic size) {
    final n = size is num ? size.toInt() : 0;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Widget _dirTile(String path, String label, IconData icon, {bool quick = false}) {
    final selected = _selected == path;
    return ListTile(
      leading: Icon(icon, color: quick ? Theme.of(context).colorScheme.primary : null),
      title: Text(label),
      subtitle: quick ? Text(path, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
      trailing: selected ? const Icon(Icons.check) : const Icon(Icons.chevron_right),
      selected: selected,
      onTap: () {
        // 快路径/盘符/目录均可下钻；下钻即浏览，不立即选中
        _open(path);
      },
      onLongPress: () => _pick(path), // 长按直接选中（快捷）
    );
  }
}
