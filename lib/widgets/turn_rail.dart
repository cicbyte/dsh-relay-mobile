import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 一轮的导航项（对齐桌面 TurnNavigationItem：turn / prompt / response）。
class TurnRailItem {
  const TurnRailItem({
    required this.turn,
    this.prompt = '',
    this.response = '',
  });

  final int turn;

  /// 提示词摘录（该轮首条人工消息）。
  final String prompt;

  /// 回复摘录（该轮首个助手文本块）。
  final String response;
}

/// 轮次导航轨（对齐桌面 dsh TurnNavigator 的固定间距刻度轨）：
///   - 右缘竖排刻度，每轮一个标记，固定间距 10px；溢出在轨内滚动 + 两端渐隐
///   - 点按刻度 = 跳转到该轮起点（轻震动）
///   - 长按刻度 = 预览卡（prompt + 回复摘录），松手关闭
///   - 高亮当前轮刻度并自动居中（手指在轨上时不跟手）；运行轮用琥珀色
///   - 不足 2 轮不显示
class TurnRail extends StatefulWidget {
  const TurnRail({
    super.key,
    required this.items,
    required this.activeTurn,
    required this.onJump,
    this.runningTurn,
  });

  final List<TurnRailItem> items;
  final int? activeTurn;
  final int? runningTurn;

  /// 点按/预览卡跳转。
  final void Function(int turn) onJump;

  @override
  State<TurnRail> createState() => _TurnRailState();
}

class _TurnRailState extends State<TurnRail> {
  /// 刻度间距（对齐桌面 TURN_SPACING_PX）。
  static const _pitch = 10.0;

  /// 轨宽（触控命中带，视觉刻度更窄）。
  static const _railWidth = 28.0;

  final _scroller = ScrollController();
  final _stackKey = GlobalKey();

  /// 手指在轨上时禁止自动居中（桌面同款防跟手）。
  bool _pointerInside = false;

  TurnRailItem? _preview;
  double _previewDy = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCenter(instant: true));
  }

  @override
  void dispose() {
    _scroller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TurnRail old) {
    super.didUpdateWidget(old);
    if (widget.activeTurn != old.activeTurn ||
        widget.items.length != old.items.length) {
      _autoCenter();
    }
  }

  void _autoCenter({bool instant = false}) {
    final t = widget.activeTurn;
    if (t == null || _pointerInside || !_scroller.hasClients) return;
    final i = widget.items.indexWhere((e) => e.turn == t);
    if (i < 0) return;
    final view = _scroller.position.viewportDimension;
    final target =
        ((i * _pitch + _pitch / 2) - view / 2).clamp(0.0, _scroller.position.maxScrollExtent);
    if (instant) {
      _scroller.jumpTo(target);
      return;
    }
    _scroller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final band = math.min(420.0, math.max(120.0, c.maxHeight - 64));
      return Stack(key: _stackKey, children: [
        // 刻度轨：右缘垂直居中
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => setState(() => _pointerInside = true),
              onPointerUp: (_) => setState(() {
                _pointerInside = false;
                _preview = null; // 保险：抬手必收预览卡
              }),
              onPointerCancel: (_) => setState(() {
                _pointerInside = false;
                _preview = null;
              }),
              child: SizedBox(
                height: band,
                width: _railWidth,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0, 0.08, 0.92, 1],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: SingleChildScrollView(
                    controller: _scroller,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          _mark(context, widget.items[i]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 预览卡：长按时贴刻度左侧弹出
        if (_preview != null)
          Positioned(
            right: _railWidth + 14,
            top: (_previewDy - 56).clamp(8.0, math.max(8.0, c.maxHeight - 132)),
            child: _previewCard(context, _preview!),
          ),
      ]);
    });
  }

  Widget _mark(BuildContext context, TurnRailItem item) {
    final scheme = Theme.of(context).colorScheme;
    final active = item.turn == widget.activeTurn;
    final running = item.turn == widget.runningTurn;
    final color = active
        ? scheme.primary
        : running
            ? Acc.amber(context)
            : scheme.onSurfaceVariant.withValues(alpha: 0.45);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _preview = null);
        widget.onJump(item.turn);
      },
      onLongPressStart: (d) {
        HapticFeedback.mediumImpact();
        final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
        final dy = box == null ? 0.0 : box.globalToLocal(d.globalPosition).dy;
        setState(() {
          _preview = item;
          _previewDy = dy;
        });
      },
      onLongPressEnd: (_) => setState(() => _preview = null),
      onLongPressCancel: () => setState(() => _preview = null),
      child: SizedBox(
        height: _pitch,
        width: _railWidth,
        child: Align(
          alignment: Alignment.centerRight,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: active ? 18 : 12,
            height: active ? 4 : 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.45),
                          blurRadius: 6)
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewCard(BuildContext context, TurnRailItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 8,
      shadowColor: const Color(0x33000000),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 232,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('第 ${item.turn} 轮',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (item.prompt.isNotEmpty) ...[
              Text(item.prompt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
            ],
            if (item.response.isNotEmpty)
              Text(item.response,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
