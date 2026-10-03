import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zxing2/qrcode.dart';
import 'package:zxing2/zxing2.dart';

/// 扫码页：全屏沉浸相机 + 取景框/扫描线特效（支付宝风格）。
///
/// - 相机实扫走 mobile_scanner（MLKit；release 需关闭 R8 压缩，见
///   android/app/build.gradle.kts 的说明）。
/// - 相机失败降级为错误卡；相册识别走纯 Dart zxing2（不依赖 MLKit）。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage>
    with SingleTickerProviderStateMixin {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _popped = false;
  bool _torchOn = false;
  bool _cameraFailed = false;

  /// 扫描线往返动画
  late final AnimationController _line = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _line.dispose();
    _controller.dispose();
    super.dispose();
  }

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

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {
      _snack('当前设备不支持手电筒');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('扫码入网'),
        actions: [
          IconButton(
            onPressed: _fromGallery,
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: '从相册识别',
          ),
        ],
      ),
      body: _cameraFailed
          ? _buildErrorBody()
          : Stack(
              fit: StackFit.expand,
              children: [
                // 全屏相机
                MobileScanner(
                  controller: _controller,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, child) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_cameraFailed) {
                        setState(() => _cameraFailed = true);
                      }
                    });
                    return const SizedBox.shrink();
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
                // 取景框遮罩 + 四角括号 + 扫描线 + 提示/手电筒
                LayoutBuilder(
                  builder: (context, constraints) {
                    final side = math.min(constraints.maxWidth - 64.0, 300.0);
                    final window = Rect.fromCenter(
                      center: Offset(
                        constraints.maxWidth / 2,
                        constraints.maxHeight / 2 - 56,
                      ),
                      width: side,
                      height: side,
                    );
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ViewfinderPainter(window),
                          ),
                        ),
                        // 扫描线：蓝光渐变，在框内往返
                        AnimatedBuilder(
                          animation: _line,
                          builder: (context, _) {
                            final t = Curves.easeInOut.transform(_line.value);
                            final y =
                                window.top + 10 + t * (window.height - 20);
                            return Positioned(
                              left: window.left + 12,
                              width: window.width - 24,
                              top: y - 2,
                              height: 4,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2),
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.blueAccent.withValues(alpha: 0),
                                      Colors.blueAccent,
                                      Colors.blueAccent.withValues(alpha: 0),
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.blueAccent.withValues(
                                        alpha: 0.75,
                                      ),
                                      blurRadius: 14,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        // 框下提示
                        Positioned(
                          left: 24,
                          right: 24,
                          top: window.bottom + 28,
                          child: Text(
                            '将二维码放入框内，即可自动识别\n'
                            '支持 dshrelay://（云端转发）与 dshlan://（局域网）',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  height: 1.5,
                                ),
                          ),
                        ),
                        // 手电筒（轻触照亮）
                        Positioned(
                          left: 0,
                          right: 0,
                          top: window.bottom + 108,
                          child: Center(
                            child: IconButton(
                              onPressed: _toggleTorch,
                              icon: Icon(
                                _torchOn
                                    ? Icons.flashlight_on
                                    : Icons.flashlight_off,
                                size: 30,
                              ),
                              color: _torchOn
                                  ? Colors.blueAccent
                                  : Colors.white.withValues(alpha: 0.9),
                              tooltip: '轻触照亮',
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }

  /// 相机失败兜底：错误卡 + 相册/重试入口
  Widget _buildErrorBody() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 42,
                color: Colors.white70,
              ),
              const SizedBox(height: 12),
              Text(
                '相机启动失败',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                '可点右上角从相册识别，或稍后重试。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () async {
                  try {
                    await _controller.start();
                    if (mounted) setState(() => _cameraFailed = false);
                  } catch (_) {
                    // MIUI 相机 HAL 偶发占用：稍候重试一次
                    await Future.delayed(const Duration(milliseconds: 800));
                    if (!mounted) return;
                    try {
                      await _controller.start();
                      if (mounted) setState(() => _cameraFailed = false);
                    } catch (_) {}
                  }
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 取景框遮罩：窗口外压暗，窗口四角画白色括号
class _ViewfinderPainter extends CustomPainter {
  final Rect window;

  _ViewfinderPainter(this.window);

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(window, const Radius.circular(18)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, hole),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    // 四角括号
    final bracket = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    const len = 30.0;
    final l = window.left;
    final t = window.top;
    final r = window.right;
    final b = window.bottom;
    final path = Path()
      ..moveTo(l, t + len)
      ..lineTo(l, t)
      ..lineTo(l + len, t)
      ..moveTo(r - len, t)
      ..lineTo(r, t)
      ..lineTo(r, t + len)
      ..moveTo(l, b - len)
      ..lineTo(l, b)
      ..lineTo(l + len, b)
      ..moveTo(r - len, b)
      ..lineTo(r, b)
      ..lineTo(r, b - len);
    canvas.drawPath(path, bracket);
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter old) => old.window != window;
}
