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
  int _page = 0;

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
    _page = 0;
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
      setState(() => _page = missing);
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

  /// 单选且非末题：点选项自动进下一题（与 web 端一致）。
  void _select(Map<String, dynamic> q, _QuestionDraft d, String label) {
    final multi = q['multiSelect'] == true;
    setState(() {
      if (multi) {
        d.selected.contains(label)
            ? d.selected.remove(label)
            : d.selected.add(label);
      } else {
        d.selected
          ..clear()
          ..add(label);
        d.custom.clear();
      }
    });
    if (!multi && _page < _questions.length - 1) {
      Future.delayed(const Duration(milliseconds: 220), () {
        if (mounted && d.selected.contains(label)) {
          setState(() => _page++);
        }
      });
    }
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
      // 限高：选项多时内部滚动，不把页面底部顶溢出（曾溢出 68px）。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
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
                approval
                    ? '工具请求授权'
                    : '回答询问 · 第 ${_page + 1}/${_questions.length} 题',
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
            // 一屏一题（与 web 端一致）：选项天然不用滚动，底部翻页/提交。
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_questionEditor(_page)],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              if (_page > 0)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _page--),
                  child: const Text('上一题'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: _busy
                    ? null
                    : (_page < _questions.length - 1
                        ? () => setState(() => _page++)
                        : _submit),
                child: Text(_busy
                    ? '提交中…'
                    : _page < _questions.length - 1
                        ? '下一题'
                        : '提交回答'),
              ),
            ]),
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
          // 选项一列一行：标签 + 描述常显，整行可点选/取消。
          for (final o in options)
            Builder(builder: (context) {
              final label = '${o['label'] ?? ''}';
              final desc = '${o['description'] ?? ''}'.trim();
              final isSel = d.selected.contains(label);
              return InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: d.skipped
                    ? null
                    : () => _select(q, d, label),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSel
                        ? scheme.primary.withValues(alpha: 0.16)
                        : scheme.surfaceContainerHighest
                            .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                        color: isSel
                            ? scheme.primary.withValues(alpha: 0.55)
                            : scheme.outlineVariant.withValues(alpha: 0.4)),
                  ),
                  child:
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                          multi
                              ? (isSel
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank)
                              : (isSel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked),
                          size: 13,
                          color: isSel
                              ? scheme.primary
                              : scheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight:
                                        isSel ? FontWeight.w600 : null)),
                            if (desc.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text(desc,
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                            color:
                                                scheme.onSurfaceVariant)),
                              ),
                          ]),
                    ),
                  ]),
                ),
              );
            }),
          if (multi)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('（可多选）',
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
