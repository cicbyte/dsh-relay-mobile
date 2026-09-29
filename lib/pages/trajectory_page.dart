import 'dart:convert';

import 'package:flutter/material.dart';

import '../dsh/dsh_client.dart';
import '../theme.dart';

/// 轨迹视图（对齐 web 版 TrajectoryView）：全部事件（含 step/ 等协议事件）
/// 按轮次分组的时间线，支持类型/内容搜索，点行展开原始 JSON。
class TrajectoryPage extends StatefulWidget {
  final List<WireRecord> records;
  final String title;

  const TrajectoryPage({super.key, required this.records, this.title = '轨迹'});

  @override
  State<TrajectoryPage> createState() => _TrajectoryPageState();
}

class _TrajectoryPageState extends State<TrajectoryPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(WireRecord r) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return r.type.toLowerCase().contains(q) ||
        jsonEncode(r.data).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = widget.records.where(_matches).toList();

    // 按轮次分桶（事件的 turn 字段缺失时沿用上一个；初始桶 '—'）
    final buckets = <String, List<WireRecord>>{};
    var current = '—';
    for (final r in filtered) {
      final t = r.data['turn'];
      if (t != null) current = '$t';
      buckets.putIfAbsent(current, () => []).add(r);
    }

    return Scaffold(
      appBar: AppBar(flexibleSpace: Builder(builder: skinFlexibleSpace), title: Text(widget.title)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              hintText: '搜索轨迹（类型 / 内容）',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('没有匹配的事件'))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final entry in buckets.entries) ...[
                      _bucketHeader(entry.key, entry.value),
                      for (final r in entry.value) _eventRow(r),
                    ],
                  ],
                ),
        ),
      ]),
    );
  }

  Widget _bucketHeader(String turn, List<WireRecord> rs) {
    final theme = Theme.of(context);
    final first = rs.first.time;
    final last = rs.last.time;
    final tools = rs.where((r) => r.type == 'tool/call').length;
    final range = last > first ? ' · ${_fmtClock(first, true)}–${_fmtClock(last, true)}' : ' · ${_fmtClock(first, true)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Row(children: [
        Text(
          turn == '—' ? '（无轮次标记）' : '第 $turn 轮',
          style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${rs.length} 事件'
            '${tools > 0 ? ' · $tools 次工具' : ''}$range',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
        ),
      ]),
    );
  }

  Widget _eventRow(WireRecord r) {
    final theme = Theme.of(context);
    final color = _typeColor(r.type, theme.colorScheme);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        dense: true,
        leading: Text(
          _fmtClock(r.time, true),
          style: theme.textTheme.labelSmall
              ?.copyWith(fontFeatures: const [], color: theme.colorScheme.onSurfaceVariant),
        ),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(r.type,
                style: theme.textTheme.labelSmall?.copyWith(color: color)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _summary(r),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              const JsonEncoder.withIndent('  ').convert(r.data),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Consolas', 'Courier New'],
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _summary(WireRecord r) {
    switch (r.type) {
      case 'tool/call':
        return '${r.data['name'] ?? ''}';
      case 'tool/result':
        return r.data['error'] != null ? '工具结果（错误）' : '工具结果';
      case 'user/message':
        return _firstLine(_plainText(r.data['content']));
      case 'assistant/message':
        final msg = Map<String, dynamic>.from(r.data['message'] as Map? ?? {});
        return _firstLine(_plainText(msg['content']));
      case 'system/message':
        return _firstLine(_plainText(r.data['content'] ?? r.data['message']));
      case 'todo/write':
        final n = (r.data['todos'] as List? ?? []).length;
        return '任务清单 · $n 项';
      case 'approval/asked':
        return '授权询问 · ${r.data['toolName'] ?? ''}';
      case 'approval/decided':
        return '授权结果 · ${r.data['outcome'] ?? ''}';
      case 'plan/mode':
        return r.data['active'] == true ? '计划模式 · 开启' : '计划模式 · 关闭';
      case 'tool-workflow/run-start':
        return '后台任务 · ${r.data['name'] ?? ''}';
      case 'tool-workflow/run-end':
        return '后台任务结束 · ${r.data['stopReason'] ?? ''}';
      case 'command/run':
        return '命令 · /${r.data['name'] ?? ''}';
      case 'compaction/summary':
        return '上下文压缩 · 完成';
      case 'goal/change':
        final goal = Map<String, dynamic>.from(r.data['goal'] as Map? ?? {});
        return '目标 · ${goal['objective'] ?? goal['goalId'] ?? r.data['operation'] ?? ''}';
      case 'deliverables/presented':
        final n = (r.data['files'] as List? ?? []).length;
        return '交付物 · $n 个文件';
      default:
        return '';
    }
  }

  String _plainText(dynamic content) {
    if (content is! List) return '';
    final out = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text' && b['text'] is String) out.add('${b['text']}');
    }
    return out.join(' ');
  }

  String _firstLine(String s) => s.trim().split('\n').first;

  Color _typeColor(String type, ColorScheme scheme) {
    if (type.startsWith('user/')) return scheme.primary;
    if (type.startsWith('assistant/')) return Acc.tealOf(scheme.brightness);
    if (type.startsWith('tool/')) return Acc.orangeOf(scheme.brightness);
    if (type.startsWith('compaction/')) return Acc.purpleOf(scheme.brightness);
    if (type.startsWith('step/')) return scheme.onSurfaceVariant.withValues(alpha: 0.6);
    if (type.startsWith('todo/')) return Acc.greenOf(scheme.brightness);
    if (type.startsWith('approval/')) return Acc.orangeOf(scheme.brightness);
    if (type.startsWith('plan/')) return Acc.lightBlueOf(scheme.brightness);
    if (type.startsWith('subagent/') || type.startsWith('tool-workflow/')) {
      return Acc.cyanOf(scheme.brightness);
    }
    if (type.startsWith('goal/')) return Acc.pinkOf(scheme.brightness);
    if (type.startsWith('command/')) return Acc.amberOf(scheme.brightness);
    return scheme.onSurfaceVariant;
  }

  String _fmtClock(int ms, bool withSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int v) => v.toString().padLeft(2, '0');
    return withSeconds
        ? '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
        : '${p(t.hour)}:${p(t.minute)}';
  }
}
