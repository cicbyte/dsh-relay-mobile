import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// 扫码页：相机识别 + 相册识别（模拟器无相机时用相册），返回原始 payload。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _popped = false;

  void _pop(String raw) {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).pop(raw);
  }

  Future<void> _fromGallery() async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = pick?.files.single.path;
    if (path == null) return;
    final capture = await _controller.analyzeImage(path);
    final value = capture?.barcodes
        .map((b) => b.rawValue ?? '')
        .where((v) => v.isNotEmpty)
        .firstOrNull;
    if (value != null) {
      _pop(value);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未在图片中识别到二维码')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Builder(builder: skinFlexibleSpace),
        title: const Text('扫码入网'),
        actions: [
          IconButton(
            onPressed: _fromGallery,
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: '从相册识别',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                for (final b in capture.barcodes) {
                  final v = b.rawValue;
                  if (v != null && v.isNotEmpty) {
                    _pop(v);
                    return;
                  }
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '对准二维码自动识别；模拟器可点右上角从相册识别。\n'
              '支持 dshrelay://（云端转发）与 dshlan://（局域网）两种入网码。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
