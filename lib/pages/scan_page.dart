import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zxing2/qrcode.dart';
import 'package:zxing2/zxing2.dart';

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

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 相册识别：纯 Dart zxing2 解码（不依赖 MLKit）。
  ///
  /// 背景：MLKit（mobile_scanner 的 analyzeImage 与相机识别）在本项目
  /// 的所有真机/模拟器上均以 `getClass() on null` NPE 告终（相机启动与
  /// 图片解码同源），故图像识别改走 zxing2，零原生依赖、任何 ROM 可用。
  Future<void> _fromGallery() async {
    try {
      final pick = await FilePicker.platform.pickFiles(type: FileType.image);
      final path = pick?.files.single.path;
      if (path == null) return;
      final raw = await File(path).readAsBytes();
      final image = imglib.decodeImage(raw);
      if (image == null) {
        _snack('无法读取图片');
        return;
      }
      // 大图缩到 ≤1400px：纯 Dart 解码耗时可控
      final scaled = (image.width > 1400 || image.height > 1400)
          ? (image.width >= image.height
                ? imglib.copyResize(image, width: 1400)
                : imglib.copyResize(image, height: 1400))
          : image;
      final bytes = scaled.getBytes(order: imglib.ChannelOrder.rgba);
      final pixels = Int32List(scaled.width * scaled.height);
      for (int o = 0, p = 0; o + 3 < bytes.length; o += 4, p++) {
        // zxing2 期望 R<<16 | G<<8 | B
        pixels[p] = (bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2];
      }
      final source = RGBLuminanceSource(scaled.width, scaled.height, pixels);
      final hints = DecodeHints()..put(DecodeHintType.tryHarder);
      String? text;
      try {
        text = QRCodeReader()
            .decode(BinaryBitmap(HybridBinarizer(source)), hints: hints)
            .text;
      } on NotFoundException {
        // 黑底白码：反转亮度再试一次
        try {
          text = QRCodeReader()
              .decode(
                BinaryBitmap(HybridBinarizer(InvertedLuminanceSource(source))),
                hints: hints,
              )
              .text;
        } on NotFoundException {
          text = null;
        }
      }
      if (text != null && text.isNotEmpty) {
        _pop(text);
      } else {
        _snack('未在图片中识别到二维码');
      }
    } catch (e) {
      _snack('识别失败：$e');
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
              // 相机启动失败（权限被拒/相机被占/部分 ROM 相机栈异常）时给出
              // 明确提示与重试入口，而不是默认的黑屏+感叹号。
              errorBuilder: (context, error, child) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.camera_alt_outlined, size: 42),
                        const SizedBox(height: 12),
                        Text(
                          '相机启动失败',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '可点右上角从相册识别，或稍后重试。\n'
                          '${error.errorCode.name}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: () async {
                            try {
                              await _controller.start();
                            } catch (_) {
                              // MIUI 相机 HAL 偶发占用：稍候重试一次
                              await Future.delayed(
                                const Duration(milliseconds: 800),
                              );
                              if (!mounted) return;
                              try {
                                await _controller.start();
                              } catch (_) {}
                            }
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                );
              },
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
