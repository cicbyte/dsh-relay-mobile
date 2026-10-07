import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dsh/dsh_client.dart';
import '../theme.dart';

/// 工作区文件浏览（宿主 workspaceFiles/list|read；scope 在 wire 上是会话 id，
/// 服务端按会话 cwd 解析工作区根并做越界约束）。
///
/// 目录模式逐层下钻；点文件进阅读页（5000 行/页，1-based offset，可续页）。
/// [initialPath] 传绝对路径时直接打开该文件（轮尾「已编辑」卡点入的场景）。
class WorkspacePage extends StatefulWidget {
  final DshClient client;
  final String sessionId;

  /// 会话 cwd（仅展示用；路径解析全在服务端）。
  final String? cwd;
  final String title;

  /// 直接打开的文件路径（绝对路径或相对会话 cwd），空则从根目录开始浏览。
  final String? initialPath;

  const WorkspacePage({
    super.key,
    required this.client,
    required this.sessionId,
    required this.title,
    this.cwd,
    this.initialPath,
  });

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  String _rel = '';
  List<Map<String, dynamic>> _entries = const [];
  bool _truncated = false;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final init = widget.initialPath;
    if (init != null && init.trim().isNotEmpty) {
      // 已编辑卡点入：直接进文件阅读页（浏览栈从工作区根开始）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
          ..pop()
          ..push(MaterialPageRoute(
            builder: (_) => _WorkspaceFilePage(
              client: widget.client,
              sessionId: widget.sessionId,
              path: init,
              rootTitle: _rootLabel,
            ),
          ));
      });
    }
    _reload();
  }

  String get _rootLabel {
    final cwd = widget.cwd;
    if (cwd == null || cwd.trim().isEmpty) return '工作区';
    final norm = cwd.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i == -1 ? norm : norm.substring(i + 1);
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final v = await widget.client.workspaceFileList(
        widget.sessionId,
        _rel.isEmpty ? '.' : _rel,
      );
      if (!mounted) return;
      final raw = v['entries'] as List? ?? const [];
      final entries = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
        ..sort((a, b) {
          final da = a['type'] == 'directory';
          final db = b['type'] == 'directory';
          if (da != db) return da ? -1 : 1;
          return '${a['name']}'.compareTo('${b['name']}');
        });
      setState(() {
        _entries = entries;
        _truncated = v['truncated'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _enter(Map<String, dynamic> e) {
    final name = '${e['name']}';
    final child = _rel.isEmpty ? name : '$_rel/$name';
    if (e['type'] == 'directory') {
      setState(() => _rel = child);
      _reload();
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _WorkspaceFilePage(
        client: widget.client,
        sessionId: widget.sessionId,
        path: child,
        rootTitle: _rootLabel,
      ),
    ));
  }

  void _up() {
    if (_rel.isEmpty) return;
    final i = _rel.lastIndexOf('/');
    setState(() => _rel = i == -1 ? '' : _rel.substring(0, i));
    _reload();
  }

  String _sizeLabel(Object? size) {
    final n = size is num ? size.toInt() : null;
    if (n == null) return '';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('工作区 · $_rootLabel', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          // 当前相对路径 + 上一级
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _rel.isEmpty ? '(根目录)' : _rel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '上一级',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: _rel.isEmpty || _loading ? null : _up,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text('读取失败', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(_error,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                        ],
                      )
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _entries.length + (_truncated ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            if (i >= _entries.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text('条目过多，列表已截断',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: scheme.onSurfaceVariant)),
                              );
                            }
                            final e = _entries[i];
                            final dir = e['type'] == 'directory';
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(
                                dir
                                    ? Icons.folder_outlined
                                    : Icons.description_outlined,
                                size: 18,
                                color: dir
                                    ? Acc.lightBlue(context)
                                    : scheme.onSurfaceVariant,
                              ),
                              title: Text('${e['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium),
                              trailing: dir
                                  ? const Icon(Icons.chevron_right, size: 16)
                                  : Text(_sizeLabel(e['size']),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                              color: scheme.onSurfaceVariant)),
                              onTap: () => _enter(e),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// 文件阅读页：按页读文本（服务端 5000 行/页上限，eof 标记收尾）。
class _WorkspaceFilePage extends StatefulWidget {
  final DshClient client;
  final String sessionId;

  /// 相对会话 cwd 的路径，或绝对路径（已编辑卡点入）。
  final String path;
  final String rootTitle;

  const _WorkspaceFilePage({
    required this.client,
    required this.sessionId,
    required this.path,
    required this.rootTitle,
  });

  @override
  State<_WorkspaceFilePage> createState() => _WorkspaceFilePageState();
}

class _WorkspaceFilePageState extends State<_WorkspaceFilePage> {
  final _buf = StringBuffer();
  final _ctrl = ScrollController();
  String _absPath = '';
  int _bytes = 0;
  int _nextOffset = 1;
  bool _eof = false;
  bool _loading = true;
  bool _loadingMore = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_eof || _loadingMore) return;
    setState(() {
      if (_nextOffset == 1) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = '';
    });
    try {
      final v = await widget.client.workspaceFileRead(
        widget.sessionId,
        widget.path,
        offset: _nextOffset,
        limit: 2000,
      );
      if (!mounted) return;
      _buf.write('${v['text'] ?? ''}');
      _absPath = '${v['absolutePath'] ?? widget.path}';
      _bytes = v['bytes'] is num ? (v['bytes'] as num).toInt() : _bytes;
      final lines = v['lines'] is num ? (v['lines'] as num).toInt() : 0;
      _nextOffset += lines;
      _eof = v['eof'] == true;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$e';
      });
    }
  }

  String _displayPath(String p) {
    final home = Platform.environment['USERPROFILE']?.replaceAll('\\', '/');
    final norm = p.replaceAll('\\', '/');
    if (home != null && home.isNotEmpty && norm.toLowerCase().startsWith(home.toLowerCase())) {
      return '~${norm.substring(home.length)}';
    }
    return norm;
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _buf.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已复制全部已加载内容'),
        duration: Duration(seconds: 1),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = _absPath.isEmpty
        ? widget.path.replaceAll('\\', '/').split('/').last
        : _absPath.replaceAll('\\', '/').split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text(name, overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          IconButton(
            tooltip: '复制内容',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: _buf.isEmpty ? null : _copyAll,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Text(
              _displayPath(_absPath.isEmpty ? widget.path : _absPath),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty && _buf.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text('读取失败', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(_error,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                        ],
                      )
                    : SingleChildScrollView(
                        controller: _ctrl,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: SelectableText(
                          _buf.toString(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            height: 1.45,
                          ),
                        ),
                      ),
          ),
          if (!_eof && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: OutlinedButton.icon(
                icon: _loadingMore
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.expand_more, size: 16),
                label: Text(
                    '加载更多（已 ${(_buf.length / 1024).toStringAsFixed(1)} KB / ${(_bytes / 1024).toStringAsFixed(1)} KB）'),
                onPressed: _loadingMore ? null : _loadMore,
              ),
            ),
          if (_error.isNotEmpty && _buf.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('续页失败：$_error',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.error)),
            ),
        ],
      ),
    );
  }
}
