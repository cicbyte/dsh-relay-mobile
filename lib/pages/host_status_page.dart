// 宿主状态看板：进程/窗口清单 + 按窗口截图（宿主机软件运行情况「瞟一眼」）。
//
// 数据走插件 /mobile-bridge/host-status 与 /mobile-bridge/window-capture（经
// relay 隧道通用转发）。capabilities 协商：平台不支持的能力直接隐藏 UI；
// 插件旧版本（路由 404）整页降级为升级提示。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../device_info.dart';
import '../dsh/dsh_client.dart';

class HostStatusPage extends StatefulWidget {
  final DshClient client;
  final String deviceId;
  const HostStatusPage({super.key, required this.client, required this.deviceId});

  @override
  State<HostStatusPage> createState() => _HostStatusPageState();
}

class _HostStatusPageState extends State<HostStatusPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _allProcs = false; // false=有窗口的（默认） true=全部进程
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final d = await widget.client.hostStatus();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (d == null) {
        _error = '插件版本过旧（无宿主状态路由），请在电脑端更新 dsh-relay-plugin 后重试';
      } else {
        _data = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caps = _data?['capabilities'] is Map
        ? Map<String, dynamic>.from(_data!['capabilities'] as Map)
        : const <String, dynamic>{};
    final windowList = caps['windowList'] == true;
    final platform = '${_data?['platform'] ?? '?'}';
    final procs = _visibleProcs();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '宿主状态',
          style: theme.textTheme.titleMedium,
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _error != null
          ? _ErrorView(message: _error!, onRetry: _reload)
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  _header(theme, platform, caps),
                  if (windowList) _viewSwitch(theme),
                  if (_query.isNotEmpty || (_allProcs || !windowList))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: TextField(
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: '按名称/标题过滤',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                    ),
                  if (_loading && _data == null)
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (procs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          '没有匹配的进程',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    for (final p in procs) _procRow(theme, p),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      '共 ${procs.length} 个进程 · ${platform == 'win32' ? 'Windows' : platform == 'darwin' ? 'macOS' : 'Linux'}'
                      '${caps['capture'] != true ? ' · 此平台不支持窗口截图' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  List<Map<String, dynamic>> _visibleProcs() {
    final d = _data;
    if (d == null) return const [];
    final windowList = d['capabilities'] is Map &&
        (d['capabilities'] as Map)['windowList'] == true;
    final raw = d['processes'] is List ? d['processes'] as List : const [];
    var list = raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((p) => _allProcs || !windowList ? true : p['win'] != null)
        .toList();
    if (_query.isNotEmpty) {
      list = list
          .where((p) =>
              '${p['name']}'.toLowerCase().contains(_query.toLowerCase()) ||
              '${p['title']}'.toLowerCase().contains(_query.toLowerCase()))
          .toList();
    }
    list.sort((a, b) {
      final am = (a['memMB'] as num?)?.toDouble() ?? 0;
      final bm = (b['memMB'] as num?)?.toDouble() ?? 0;
      return bm.compareTo(am);
    });
    return list;
  }

  Widget _header(ThemeData theme, String platform, Map<String, dynamic> caps) {
    final scheme = theme.colorScheme;
    final host = '${_data?['host'] ?? ''}';
    final caps2 = caps;
    String capLabel(String k, String on, String off) =>
        caps2[k] == true ? on : off;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            host.isEmpty ? platform : '$host · $platform',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            [
              capLabel('processList', '进程 ✓', '进程 ✗'),
              capLabel('windowList', '窗口 ✓', '窗口 ✗'),
              capLabel('capture', '截图 ✓', '截图 ✗'),
            ].join('  '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewSwitch(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('有窗口'), icon: Icon(Icons.web_asset, size: 16)),
          ButtonSegment(value: true, label: Text('全部进程'), icon: Icon(Icons.list, size: 16)),
        ],
        selected: {_allProcs},
        onSelectionChanged: (s) => setState(() => _allProcs = s.first),
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(
              theme.textTheme.labelMedium),
        ),
      ),
    );
  }

  Widget _procRow(ThemeData theme, Map<String, dynamic> p) {
    final scheme = theme.colorScheme;
    final hasWin = p['win'] != null;
    final mem = (p['memMB'] as num?)?.toDouble() ?? 0;
    final cpu = (p['cpuPct'] as num?)?.toDouble() ?? 0;
    final title = '${p['title'] ?? ''}';
    final captureOn = _data?['capabilities'] is Map &&
        (_data!['capabilities'] as Map)['capture'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: hasWin && captureOn ? () => _capture(p) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  hasWin ? Icons.web_asset : Icons.memory,
                  size: 18,
                  color: hasWin ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              '${p['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'PID ${p['pid']}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (title.isNotEmpty)
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      mem >= 1024
                          ? '${(mem / 1024).toStringAsFixed(1)} GB'
                          : '${mem.toStringAsFixed(0)} MB',
                      style: theme.textTheme.labelMedium,
                    ),
                    Text(
                      'CPU $cpu%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (hasWin && captureOn) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.photo_camera_outlined,
                      size: 15, color: scheme.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _saving = false;

  /// 点击放大：全屏黑底 + 双指缩放/拖动查看。
  void _openViewer(Map<String, dynamic> r) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ImageViewerDialog(bytes: Uint8List.fromList(r['bytes'] as List<int>)),
    ));
  }

  /// 手动保存：写 app 私有目录临时文件 → 系统下载（MediaStore 免权限）→ 删临时文件。
  Future<void> _saveShot(BuildContext sheetCtx, Map<String, dynamic> r) async {
    setState(() => _saving = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = '${r['name']}';
      final tmp = File('${dir.path}/$name');
      await tmp.writeAsBytes(Uint8List.fromList(r['bytes'] as List<int>), flush: true);
      try {
        final loc = await saveFileToDownloads(tmp.path, name);
        if (!sheetCtx.mounted) return;
        ScaffoldMessenger.of(sheetCtx).showSnackBar(SnackBar(
          content: Text(loc.isEmpty ? '已保存到系统下载：$name' : '已保存：$loc'),
        ));
      } finally {
        try { await tmp.delete(); } catch (_) {}
      }
    } catch (e) {
      if (sheetCtx.mounted) {
        ScaffoldMessenger.of(sheetCtx)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _capture(Map<String, dynamic> p) async {
    final theme = Theme.of(context);
    final win = '${p['win']}';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${p['name']} 的窗口画面',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              FutureBuilder<Map<String, dynamic>?>(
                future: widget.client
                    .windowCapture(win, deviceId: widget.deviceId)
                    .then((r) async {
                  if (r == null) return null;
                  final bytes = await widget.client
                      .dlFetch('${r['downloadId']}', widget.deviceId);
                  return bytes == null ? null : {...r, 'bytes': bytes};
                }),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(36),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final r = snap.data;
                  if (r == null) {
                    // 桥端 400（黑帧/最小化/不可见）→ snap.error 带真实文案；
                    // null（404 等）→ 路由不可用。
                    final err = snap.error?.toString() ?? '';
                    final msg = err.isNotEmpty
                        ? err.replaceFirst(RegExp(r'^DshRpcException[^:]*:\s*'), '')
                        : '截图失败：路由不可用（电脑端插件需更新）';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(msg,
                                  style: theme.textTheme.bodySmall),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '提示：窗口被完全遮挡或最小化时，Chrome/VSCode/微信等'
                          '会暂停渲染，抓取会失败；把窗口切到前台再试。',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            Navigator.of(sheetCtx).pop();
                            _capture(p);
                          },
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('重新截取'),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _openViewer(r),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            Uint8List.fromList(r['bytes'] as List<int>),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Text('图片解码失败'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${r['name']} · ${(((r['size'] as num?) ?? 0) / 1024).toStringAsFixed(0)} KB · 临时预览，点图片可放大',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _saving
                                ? null
                                : () => _saveShot(sheetCtx, r),
                            icon: _saving
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.save_alt, size: 16),
                            label: const Text('保存到下载'),
                          ),
                          const SizedBox(width: 4),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.of(sheetCtx).pop();
                              _capture(p);
                            },
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('重新截取'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ).catchError((Object e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    });
  }
}

class _ImageViewerDialog extends StatelessWidget {
  final Uint8List bytes;
  const _ImageViewerDialog({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 8,
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 36, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
