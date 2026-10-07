import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../device_info.dart';
import '../dsh/download_client.dart';
import '../dsh/dsh_client.dart';
import '../main.dart';

/// 对端下发的文件名消毒：basename 化（防路径穿越 ../、//绝对路径）、剥控制字符
/// 与 Windows 保留字符、限长保扩展名；[existingDir] 给定目录时同名自动加 (n)
/// 后缀（防覆盖已有下载）。
String sanitizeFileName(String raw, {String? existingDir}) {
  final parts = raw
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .toList();
  var n = parts.isNotEmpty ? parts.last : '';
  n = n.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '').trim();
  if (n.isEmpty || n == '..') n = 'download.bin';
  if (n.length > 120) n = n.substring(n.length - 120); // 保扩展名在尾部
  var candidate = n;
  var i = 0;
  if (existingDir != null) {
    while (File('$existingDir/$candidate').existsSync()) {
      i++;
      final dot = n.lastIndexOf('.');
      candidate = dot > 0
          ? '${n.substring(0, dot)} ($i)${n.substring(dot)}'
          : '$n ($i)';
    }
  }
  return candidate;
}

/// 共享文件区流程（双向共享模型）：手机 ⇄ 桌面（含 agent）的文件交换区——
/// 工作区区 `<会话cwd>/.dsh-share` 与 全局区 `$DSH_HOME/.dsh-share`。
/// 下行：手机下载区内文件（dl-create 强制区内路径，绕过 UI 也拿不到区外字节）。
/// 上行：手机分块上传进区（share-upload-*，唯一写通道），agent 直接读写该目录。
class DownloadFlow {
  /// 入口：弹共享文件区面板。[workspaceRoot] 为当前会话 cwd；空/无工作区会话只有全局区。
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

/// 共享文件区面板：工作区区 + 全局区列表；手机上传（分块/断点/可取消）/
/// 点选下载 / 删除副本 / 长按复制路径。桌面侧（人或 agent）直接读写 .dsh-share 目录。
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
  // 上传状态（分块 + 断点续传，可取消）
  bool _uploading = false;
  bool _upCancel = false;
  String _upName = '';
  int _upSent = 0;
  int _upTotal = 0;

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
        _error = '无法获取共享区（插件旧版本或未连接）';
      });
      return;
    }
    setState(() {
      _pool = r;
      _loading = false;
    });
  }

  /// 从手机上传文件到共享区（agent 可直接读）：
  /// init（同名 .part 自动断点续传）→ 256KB 分块 base64 追加 → done 转正。
  /// 有会话工作区传工作区区（该会话 agent 直接可见），否则传全局区。
  Future<void> _upload() async {
    if (_uploading) return;
    final picked = await FilePicker.platform.pickFiles(allowMultiple: false, withData: false);
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final pf = picked.files.first;
    if (pf.path == null || pf.path!.isEmpty) return;
    final local = File(pf.path!);
    final size = pf.size;
    final hasWs = widget.workspaceRoot != null;
    setState(() {
      _uploading = true;
      _upCancel = false;
      _upName = pf.name;
      _upSent = 0;
      _upTotal = size;
    });
    String? uploadId;
    String? failMsg;
    String? donePath;
    try {
      final init = await widget.client.shareUploadInit(
        pf.name,
        size,
        deviceId: widget.deviceId,
        workspaceRoot: widget.workspaceRoot,
        toWorkspace: hasWs,
      );
      if (init == null) {
        failMsg = '初始化失败（插件旧版本？）';
      } else if (init['done'] == true) {
        donePath = '${init['path']}'; // 空文件：init 直接落盘
      } else {
        uploadId = '${init['uploadId']}';
        var offset = (init['offset'] as num?)?.toInt() ?? 0;
        if (offset > 0) setState(() => _upSent = offset); // 断点续传起点
        final raf = await local.open(mode: FileMode.read);
        try {
          if (offset > 0) await raf.setPosition(offset);
          const chunkSize = 256 * 1024;
          while (offset < size && mounted && !_upCancel) {
            final data = await raf.read(chunkSize);
            if (data.isEmpty) break;
            final r = await widget.client.shareUploadChunk(uploadId, offset, base64Encode(data));
            if (r == null) {
              failMsg = '块上传失败（会话过期/网络断）：重试将自动续传';
              break;
            }
            offset = (r['offset'] as num?)?.toInt() ?? (offset + data.length);
            if (mounted) setState(() => _upSent = offset);
            if (r['done'] == true) {
              donePath = '${r['path']}';
              break;
            }
          }
        } finally {
          await raf.close();
        }
      }
    } catch (e) {
      failMsg = '上传失败：$e';
    }
    // 取消：删服务端半成品（留着也行——下次同名续传，但明确清理更干净）
    if (_upCancel && uploadId != null && uploadId.isNotEmpty) {
      await widget.client.shareUploadAbort(uploadId, deviceId: widget.deviceId);
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    final messenger = ScaffoldMessenger.of(context);
    if (_upCancel) {
      messenger.showSnackBar(const SnackBar(content: Text('已取消上传（已传部分将在下次同名上传时续用）')));
    } else if (failMsg != null) {
      messenger.showSnackBar(SnackBar(content: Text(failMsg)));
    } else {
      messenger.showSnackBar(SnackBar(content: Text('已上传到共享区：$_upName\n（agent 可直接读取：$donePath）')));
      await _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final name = '${f['name']}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从共享区删除'),
        content: Text('删除共享区文件「$name」？\n（仅删除 .dsh-share 里的这个文件）'),
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
                  child: Text('共享文件区', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  icon: _uploading
                      ? const Icon(Icons.stop_circle_outlined)
                      : const Icon(Icons.upload_outlined),
                  tooltip: _uploading ? '取消上传' : '从手机上传文件',
                  onPressed: _loading
                      ? null
                      : () {
                          if (_uploading) {
                            setState(() => _upCancel = true);
                          } else {
                            _upload();
                          }
                        },
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
                    '双向共享：手机可⬆上传/下载；电脑侧（含 agent）直接读写 .dsh-share 目录',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ],
            ),
          ),
          // 上传进度：文件名 + 已传/总量（分块续传，可中途取消）
          if (_uploading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _upTotal > 0 ? _upSent / _upTotal : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _upTotal > 0
                          ? '上传中：$_upName（${_fmtSize(_upSent)} / ${_fmtSize(_upTotal)}）'
                          : '上传中：$_upName…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
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
      if (ws != null) ..._section(theme, '工作区共享区', '${ws['dir']}', wsItems),
      ..._section(theme, '全局共享区', '${g['dir']}', gItems),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('共享区为空：电脑上把文件放进 .dsh-share 目录，或点右上角⬆从手机上传。', textAlign: TextAlign.center),
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
        tooltip: '从共享区删除',
        onPressed: () => _delete(f),
      ),
      onTap: () => _download(f),
      // 长按复制服务器路径：贴给 agent / 会话直接引用共享区文件
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: '${f['path']}'));
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制路径：${f['path']}')));
      },
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

  /// 下载实际落盘的文件名（消毒+同名避让后）。保存到系统下载必须复用这个名字
  /// ——再跑一遍 sanitizeFileName 会因文件已存在追加 " (1)"，源路径错位导致
  /// 保存恒失败（第二轮审查 #915）。
  String? _diskFileName;

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
      // 对端下发的文件名消毒（路径穿越/控制字符/同名覆盖）
      final safe = sanitizeFileName(widget.fileName, existingDir: dir.path);
      _diskFileName = safe;
      final dest = File('${dir.path}/$safe');
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
      // 复用下载时的实际文件名（消毒+同名避让只做一次）；理论兜底：字段缺失时
      // 再消毒一次（不带 existingDir，不产生 (n) 错位）
      final safe = _diskFileName ??
          sanitizeFileName(widget.fileName);
      final loc = await saveFileToDownloads('${dir.path}/$safe', safe);
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
