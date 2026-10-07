// 会话弹层：@ 引用面板、队列消息改写对话框。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../dsh/dsh_client.dart';

/// @ 提及弹层：文件（fileReferences/list）在前、会话
/// （sessionReferenceResolver/candidates）在后；一域失败另一域照常。
/// 选中 pop 插入串：文件=@path/@"p s"/@dir/，会话=候选自带 mention。
class ReferenceSheet extends StatefulWidget {
  const ReferenceSheet({required this.client, required this.sessionId});
  final DshClient client;
  final String sessionId;
  @override
  State<ReferenceSheet> createState() => _ReferenceSheetState();
}

class _ReferenceSheetState extends State<ReferenceSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<dynamic> _files = const [];
  List<dynamic> _sessions = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _q.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.removeListener(_onQueryChanged);
    _q.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final q = _q.text.trim();
    // 并行双域；单域失败回落空数组（对齐桌面失败行为）。
    final results = await Future.wait<dynamic>([
      widget.client
          .fileReferenceCandidates(widget.sessionId, q)
          .catchError((Object _) => const <dynamic>[]),
      widget.client
          .sessionReferenceCandidates(widget.sessionId, q)
          .catchError((Object _) => const <dynamic>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _files = results[0] as List<dynamic>;
      _sessions = results[1] as List<dynamic>;
      _loading = false;
    });
  }

  /// 文件行 → 插入串（桌面 @path 语法：空格路径加引号、目录带尾斜杠）。
  String _fileMention(Map<String, dynamic> item) {
    final path = '${item['path'] ?? ''}';
    if ('${item['kind']}' == 'directory') {
      return path.endsWith('/') ? '@$path' : '@$path/';
    }
    return path.contains(RegExp(r'\s')) ? '@"$path"' : '@$path';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _q,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.alternate_email, size: 18),
                  hintText: '搜索文件或对话…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                children: [
                  if (_files.isNotEmpty)
                    _groupHeader(scheme, Icons.folder_outlined, '文件'),
                  for (final raw in _files)
                    if (raw is Map)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          '${raw['kind']}' == 'directory'
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          '${raw['path'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () => Navigator.pop(
                          context,
                          _fileMention(Map<String, dynamic>.from(raw)),
                        ),
                      ),
                  if (_sessions.isNotEmpty)
                    _groupHeader(scheme, Icons.forum_outlined, '会话'),
                  for (final raw in _sessions)
                    if (raw is Map)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.chat_bubble_outline,
                          size: 20,
                        ),
                        title: Text(
                          '${raw['label'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: raw['cwd'] == null
                            ? null
                            : Text(
                                '${raw['cwd']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10),
                              ),
                        onTap: () =>
                            Navigator.pop(context, '${raw['mention'] ?? ''}'),
                      ),
                  if (!_loading && _files.isEmpty && _sessions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '无匹配候选',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(ColorScheme scheme, IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 队列改写弹窗：自持 controller，pop 返回编辑文本（null=取消）。
class QueueEditDialog extends StatefulWidget {
  const QueueEditDialog({required this.initial});
  final String initial;
  @override
  State<QueueEditDialog> createState() => _QueueEditDialogState();
}

class _QueueEditDialogState extends State<QueueEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('改写队列消息'),
      content: TextField(controller: _ctrl, maxLines: 5, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
