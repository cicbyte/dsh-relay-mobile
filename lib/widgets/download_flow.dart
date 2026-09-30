import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dsh/dsh_client.dart';
import 'workspace_picker.dart';

/// 附件下载流程：选文件 → 选有效期 → 生成链接 → app 内下载 / 复制。
/// 链接随机唯一 + 绑定设备（x-device-id）+ 默认 30min、上限 7 天。
class DownloadFlow {
  /// 入口：弹完整流程。[deviceId] 为当前配对设备（绑定用）。
  static Future<void> start(BuildContext context, DshClient client, String deviceId) async {
    // 1. 选文件
    final file = await WorkspacePicker.show(context, client, pickFile: true);
    if (file == null || file.isEmpty || !context.mounted) return;
    // 2. 选有效期
    final ttl = await _pickTtl(context);
    if (ttl == null || !context.mounted) return;
    // 3. 生成链接 + 下载
    await _createAndDownload(context, client, file, deviceId, ttl);
  }

  /// 有效期选择（默认 30min，上限 7 天）。返回秒；null=取消。
  static Future<int?> _pickTtl(BuildContext context) {
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

  static Future<void> _createAndDownload(
    BuildContext context,
    DshClient client,
    String file,
    String deviceId,
    int ttl,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('生成下载链接…')));
    final out = await client.dlCreate(file, expiresInSec: ttl, deviceId: deviceId);
    if (out == null) {
      messenger.showSnackBar(const SnackBar(content: Text('生成下载链接失败')));
      return;
    }
    final downloadId = '${out['downloadId']}';
    final name = file.split(RegExp(r'[\\/]')).last;

    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DownloadSheet(
        client: client,
        deviceId: deviceId,
        downloadId: downloadId,
        fileName: name,
        expiresAt: out['expiresAt'],
      ),
    );
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
  String? _done;

  Future<void> _download() async {
    setState(() => _downloading = true);
    final bytes = await widget.client.dlFetch(widget.downloadId, widget.deviceId);
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _done = bytes == null ? '下载失败' : '已下载 ${widget.fileName}（${bytes.length} 字节）';
    });
    // 实际落盘到手机存储可后续接 path_provider + File.writeAsBytes；
    // 当前先确认 app 内拉取字节成功（传输层二进制验证）。
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
              if (_done != null) ...[
                const SizedBox(height: 8),
                Text(_done!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _downloading ? null : _download,
                      icon: _downloading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download),
                      label: Text(_downloading ? '下载中…' : '下载'),
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
