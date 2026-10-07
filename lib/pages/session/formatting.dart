// 会话页共享格式化工具（时钟/时长/tokens/JSON 美化/等宽样式）。

import 'dart:convert';

import 'package:flutter/material.dart';

/// raw JSON 参数 → 缩进美化（非 JSON 原样返回）。
String prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}

/// 参数单行摘要：见 [_argSummary]（按工具变体取 key 偏好链）。

const TextStyle monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Courier New'],
  fontSize: 12,
);

/// epoch ms → 本地时钟「14:23」（withSeconds → 14:23:05）。
String fmtClock(int ms, {bool withSeconds = false}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String p(int v) => v.toString().padLeft(2, '0');
  return withSeconds
      ? '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
      : '${p(t.hour)}:${p(t.minute)}';
}

/// 毫秒 → 「850ms」「1.2s」「3m05s」。
String fmtDuration(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '${m}m${s.toString().padLeft(2, '0')}s';
}

/// token 数 → 「856」「4.6k」「5.4M」。
String fmtTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}
