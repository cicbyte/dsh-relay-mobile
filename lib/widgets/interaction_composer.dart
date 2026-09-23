import 'package:flutter/material.dart';

import '../dsh/interactions.dart';

/// 待答交互的作答区（替代消息输入框）：询问 = 选项点选 + 自由填 + 提交；
/// 授权 = 允许一次 / 拒绝。协议应答经 [onAnswer]/[onPass] 上行。
class InteractionComposer extends StatefulWidget {
  final PendingInteraction interaction;
  final Future<void> Function(String eventId, Object? value) onAnswer;
  final Future<void> Function(String eventId) onPass;

  const InteractionComposer({
    super.key,
    required this.interaction,
    required this.onAnswer,
    required this.onPass,
  });

  @override
  State<InteractionComposer> createState() => _InteractionComposerState();
}

class _QuestionDraft {
  final Set<String> selected = {};
  final TextEditingController custom = TextEditingController();
  bool skipped = false;
  void dispose() => custom.dispose();
}

class _InteractionComposerState extends State<InteractionComposer> {
  late List<Map<String, dynamic>> _questions;
  late List<_QuestionDraft> _drafts;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant InteractionComposer old) {
    super.didUpdateWidget(old);
    if (old.interaction.eventId != widget.interaction.eventId) {
      for (final d in _drafts) {
        d.dispose();
      }
      _reset();
    }
  }

  void _reset() {
    _questions = widget.interaction.questions;
    _drafts = List.generate(_questions.length, (_) => _QuestionDraft());
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  bool _completed(int i) {
    final d = _drafts[i];
    return d.skipped || d.selected.isNotEmpty || d.custom.text.trim().isNotEmpty;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('应答失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    var missing = -1;
    for (var i = 0; i < _questions.length; i++) {
      if (!_completed(i)) {
        missing = i;
        break;
      }
    }
    if (missing >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('第 ${missing + 1} 题还没作答（可选选项、填文字或跳过）')));
      return;
    }
    final answers = <Map<String, dynamic>>[
      for (var i = 0; i < _questions.length; i++)
        _answerOf(_questions[i], _drafts[i]),
    ];
    _run(() => widget.onAnswer(widget.interaction.eventId, {'answers': answers}));
  }

  Map<String, dynamic> _answerOf(Map<String, dynamic> q, _QuestionDraft d) {
    if (d.skipped) return {'id': '${q['id']}', 'selected': <String>[]};
    final custom = d.custom.text.trim();
    final multi = q['multiSelect'] == true;
    return {
      'id': '${q['id']}',
      // 与 web 端一致：单选且填写了自由文本时 selected 清空（custom 即答案）。
      'selected': custom == '' || multi ? d.selected.toList() : <String>[],
      if (custom != '') 'custom': custom,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = widget.interaction;
    final approval = p.isApproval;
    final accent = approval ? Colors.orangeAccent : scheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(approval ? Icons.lock_outline : Icons.question_answer_outlined,
                size: 15, color: accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                approval ? '工具请求授权' : '等待你回答 · ${_questions.length} 个问题',
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.onPass(p.eventId)),
              child: const Text('留给网页端'),
            ),
          ]),
          if (approval) ...[
            const SizedBox(height: 6),
            Text('${p.request['toolName'] ?? '工具'}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            if ('${p.request['reason'] ?? ''}'.trim().isNotEmpty) ...[
              const SizedBox(height: 2),
              Text('${p.request['reason']}'.trim(),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() =>
                          widget.onAnswer(p.eventId, 'rejected')),
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() =>
                          widget.onAnswer(p.eventId, 'allowed-once')),
                  child: const Text('允许一次'),
                ),
              ),
            ]),
          ] else ...[
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _questions.length; i++)
                      _questionEditor(i),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '提交中…' : '提交回答'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _questionEditor(int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _questions[i];
    final d = _drafts[i];
    final multi = q['multiSelect'] == true;
    final options = (q['options'] as List? ?? []).whereType<Map>().toList();
    final header = '${q['header'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header.isNotEmpty)
          Text(header,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
        Text('${q['question'] ?? ''}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500)),
        if (options.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final o in options)
              FilterChip(
                label: Text('${o['label'] ?? ''}',
                    style: theme.textTheme.labelSmall),
                visualDensity: VisualDensity.compact,
                selected: d.selected.contains('${o['label']}'),
                onSelected: d.skipped
                    ? null
                    : (sel) => setState(() {
                          final label = '${o['label']}';
                          if (multi) {
                            sel ? d.selected.add(label) : d.selected.remove(label);
                          } else {
                            d.selected
                              ..clear()
                              ..add(label);
                            d.custom.clear();
                          }
                        }),
              ),
          ]),
          for (final o in options)
            if ('${o['description'] ?? ''}'.trim().isNotEmpty &&
                d.selected.contains('${o['label']}'))
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2),
                child: Text('${o['description']}'.trim(),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
        ],
        const SizedBox(height: 6),
        TextField(
          controller: d.custom,
          minLines: 1,
          maxLines: 3,
          enabled: !d.skipped,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: options.isEmpty ? '输入回答…' : '或填写自定义回答…',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => setState(() {
              d.skipped = !d.skipped;
              if (d.skipped) {
                d.selected.clear();
                d.custom.clear();
              }
            }),
            icon: Icon(d.skipped ? Icons.undo : Icons.skip_next,
                size: 14, color: scheme.onSurfaceVariant),
            label: Text(d.skipped ? '取消跳过' : '跳过此题',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ),
      ]),
    );
  }
}
