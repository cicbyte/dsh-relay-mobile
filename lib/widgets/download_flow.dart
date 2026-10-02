import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../device_info.dart';
import '../dsh/download_client.dart';
import '../dsh/dsh_client.dart';
import '../main.dart';

/// 附件下载流程（只读下载池模型）：手机只能下载「下载池」内文件——
/// 工作区池 `<会话cwd>/.dsh-download` 与 全局池 `$DSH_HOME/.dsh-download`。
/// 池内容只由桌面侧放入（资源管理器/终端/DSH 会话直接写池目录），手机无入池入口；
/// 桥端 dl-create 强制校验池内路径，绕过 UI 也拿不到池外任何字节。
class DownloadFlow {
  /// 入口：弹下载池面板。[workspaceRoot] 为当前会话 cwd；空/无工作区会话只有全局池。
  static Future<void> start(
    BuildContext context,
    DshClient client,
    String deviceId, {
    String? workspaceRoot,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => PoolSheet(
          client: client,
          deviceId: deviceId,
          workspaceRoot: (workspaceRoot == null || workspaceRoot.isEmpty) ? null : workspaceRoot,
        ),
      ),
    );
  }

  /// 有效期选择（默认 30min，上限 7 天）。返回秒；null=取消。
  static Future<int?> pickTtl(BuildContext context) {
    const options = [
      ('30 分钟', 1800),
      ('1 小时', 3600),
      ('1 天', 86400),
      ('7 天', 604800),
    ];
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Material(
        color: Theme.of(ctx).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('链接有效期', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final (label, sec) in options)
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(label),
                  trailing: sec == 1800 ? const Text('默认') : null,
                  onTap: () => Navigator.of(ctx).pop(sec),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下载池面板（只读池）：列出工作区池 + 全局池，点选下载、可删池内副本。
/// 入池只能由桌面侧完成（资源管理器/终端/DSH 会话直接往 .dsh-download 放文件），
/// 手机端没有任何入池入口——配对手机拿不到池外任何字节。
class PoolSheet extends StatefulWidget {
  final DshClient client;
  final String deviceId;
  final String? workspaceRoot; // 当前会话 cwd；null = 仅全局池

  const PoolSheet({
    super.key,
    required this.client,
    required this.deviceId,
    this.workspaceRoot,
  });

  @override
  State<PoolSheet> createState() => _PoolSheetState();
}

class _PoolSheetState extends State<PoolSheet> {
  Map<String, dynamic>? _pool;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.client.dlPool(workspaceRoot: widget.workspaceRoot);
    if (!mounted) return;
    if (r == null) {
      setState(() {
        _loading = false;
        _error = '无法获取下载池（插件旧版本或未连接）';
      });
      return;
    }
    setState(() {
      _pool = r;
      _loading = false;
    });
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final name = '${f['name']}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从下载池删除'),
        content: Text('删除池内副本「$name」？\n（仅删除 .dsh-download 里的副本，不影响原文件）'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await widget.client.dlPoolDelete(
      name,
      deviceId: widget.deviceId,
      workspaceRoot: widget.workspaceRoot,
      fromWorkspace: '${f['pool']}' == 'workspace',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? '已删除 $name' : '删除失败')));
    await _load();
  }

  /// 点选池内文件：选有效期 → 生成设备绑定链接 → 打开下载面板。
  Future<void> _download(Map<String, dynamic> f) async {
    final ttl = await DownloadFlow.pickTtl(context);
    if (ttl == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('生成下载链接…')));
    final out = await widget.client.dlCreate(
      '${f['path']}',
      expiresInSec: ttl,
      deviceId: widget.deviceId,
      workspaceRoot: widget.workspaceRoot,
    );
    if (out == null) {
      messenger.showSnackBar(const SnackBar(content: Text('生成下载链接失败')));
      return;
    }
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DownloadSheet(
        client: widget.client,
        deviceId: widget.deviceId,
        downloadId: '${out['downloadId']}',
        fileName: '${f['name']}',
        expiresAt: out['expiresAt'],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('下载附件', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _loading ? null : _load,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '只读下载池：文件由桌面端放入 .dsh-download 目录，手机仅可下载/删除池内副本',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 8),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
      );
    }
    final pool = _pool;
    if (pool == null) return const SizedBox.shrink();
    final items = List<Map<String, dynamic>>.from((pool['items'] as List? ?? []).cast<Map<String, dynamic>>());
    final wsItems = items.where((e) => '${e['pool']}' == 'workspace').toList();
    final gItems = items.where((e) => '${e['pool']}' == 'global').toList();
    final ws = pool['workspace'] as Map<String, dynamic>?;
    final g = pool['global'] as Map<String, dynamic>;

    final tiles = <Widget>[
      if (ws != null) ..._section(theme, '工作区下载池', '${ws['dir']}', wsItems),
      ..._section(theme, '全局下载池', '${g['dir']}', gItems),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('下载池为空。在电脑上把文件放入 .dsh-download 目录后点右上角刷新。', textAlign: TextAlign.center),
        ),
    ];
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: tiles);
  }

  List<Widget> _section(ThemeData theme, String title, String dir, List<Map<String, dynamic>> files) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.labelLarge),
          const SizedBox(height: 2),
          Text(dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        ]),
      ),
      if (files.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('（空）', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        )
      else
        for (final f in files) _fileTile(theme, f),
    ];
  }

  Widget _fileTile(ThemeData theme, Map<String, dynamic> f) {
    final size = f['size'] is num ? (f['size'] as num).toInt() : 0;
    final mtime = f['mtime'] is num ? (f['mtime'] as num).toInt() : 0;
    final date = mtime > 0 ? DateTime.fromMillisecondsSinceEpoch(mtime) : null;
    return ListTile(
      dense: true,
      leading: Icon(Icons.insert_drive_file_outlined, color: theme.colorScheme.primary),
      title: Text('${f['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_fmtSize(size)}${date != null ? ' · ${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '从下载池删除',
        onPressed: () => _delete(f),
      ),
      onTap: () => _download(f),
    );
  }

  String _fmtSize(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 下载操作面板：下载到本地 / 复制链接 + 剩余有效期。
class _DownloadSheet extends StatefulWidget {
  final DshClient client;
  final String deviceId;
  final String downloadId;
  final String fileName;
  final dynamic expiresAt;

  const _DownloadSheet({
    required this.client,
    required this.deviceId,
    required this.downloadId,
    required this.fileName,
    required this.expiresAt,
  });

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  bool _downloading = false;
  double? _progress; // 0..1；total 未知时为 null
  String? _done;
  bool _downloadOk = false; // 下载成功后才给「保存到系统下载」入口
  bool _savingDl = false;
  String? _savedTo;
  bool _cancelled = false; // 用户取消（区别于失败：已下载部分保留可续传）

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _done = null;
      _downloadOk = false;
      _savedTo = null;
      _cancelled = false;
    });
    try {
      // 落盘 app 私有目录（应用文档目录）
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/${widget.fileName}');
      // 隧道流式（分块 + Range 断点续传）优先；直连不可用时回退 HttpClient。
      // total 由 fetchToFile 经 meta 帧算好传入（206 时 = 断点 + 剩余）。
      final ok = await DownloadClient(widget.client.downloadBase).fetchToFile(
        widget.downloadId,
        widget.deviceId,
        dest,
        streamFactory: (offset, onMeta) => widget.client.dlStream(
          widget.downloadId,
          widget.deviceId,
          offset: offset,
          onMeta: onMeta,
        ),
        cancelled: () => _cancelled,
        onProgress: (received, t) {
          if (!mounted) return;
          setState(() => _progress = t > 0 ? received / t : null);
        },
      );
      if (!mounted) {
        // 面板已被关掉：下载仍在后台跑完，用全局 messenger 发完成通知
        rootMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(_cancelled
              ? '已取消下载：${widget.fileName}（断点已保留）'
              : (ok ? '下载完成：${widget.fileName}' : '下载失败：${widget.fileName}')),
        ));
        return;
      }
      setState(() {
        _downloading = false;
        _downloadOk = ok;
        _done = _cancelled
            ? '已取消（已下载部分保留，可断点续传）'
            : (ok ? '已保存到 ${dest.path}' : '下载失败');
      });
    } catch (e) {
      if (!mounted) {
        rootMessengerKey.currentState?.showSnackBar(
            SnackBar(content: Text('下载失败：${widget.fileName}')));
        return;
      }
      setState(() {
        _downloading = false;
        _done = _cancelled ? '已取消（已下载部分保留，可断点续传）' : '下载失败：$e';
      });
    }
  }

  /// 把 app 私有目录里的成品复制到系统「下载」（MediaStore，免权限），
  /// 否则 Android 10+ 用户摸不到 app 私有文件。
  Future<void> _saveToDownloads() async {
    if (_savingDl) return;
    if (!Platform.isAndroid) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('仅 Android 支持保存到系统下载')));
      return;
    }
    setState(() => _savingDl = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final loc =
          await saveFileToDownloads('${dir.path}/${widget.fileName}', widget.fileName);
      if (!mounted) return;
      setState(() {
        _savingDl = false;
        _savedTo = loc.isEmpty ? '已保存到系统下载' : '已保存到系统下载：$loc';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingDl = false;
        _savedTo = '保存到系统下载失败：$e';
      });
    }
  }

  void _copyLink() {
    final url = '/mobile-bridge/dl/${widget.downloadId}?d=${Uri.encodeComponent(widget.deviceId)}';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制下载路径')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('下载附件', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(widget.fileName, style: theme.textTheme.bodyLarge),
              if (_downloading) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress),
              ],
              if (_done != null) ...[
                const SizedBox(height: 8),
                Text(_done!, style: theme.textTheme.bodySmall),
              ],
              if (_downloadOk) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _savingDl ? null : _saveToDownloads,
                    icon: _savingDl
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_alt),
                    label: Text(_savingDl ? '保存中…' : '保存到系统下载'),
                  ),
                ),
              ],
              if (_savedTo != null) ...[
                const SizedBox(height: 8),
                Text(_savedTo!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      // 下载中变身「取消」（保留断点）；空闲时开始/续传下载
                      onPressed: _downloading
                          ? () => setState(() => _cancelled = true)
                          : _download,
                      icon: _downloading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download),
                      label: Text(_downloading ? '取消' : '下载'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copyLink,
                      icon: const Icon(Icons.copy),
                      label: const Text('复制路径'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
