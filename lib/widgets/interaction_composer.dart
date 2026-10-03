import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

import '../dsh/interactions.dart';
import 'markdown_text.dart';

/// 询问文案的中文显示映射（仅显示层翻译，提交值保持原 label）。
/// 文案对齐桌面端 dsh-client-ui-user-questions 的 zh 文案表。
String questionLabel(Map q, String text) {
  final intent = (q['intent'] as Map?)?['kind'];
  if (intent == 'plan-review') {
    switch (text) {
      case 'Approve':
        return '确认执行';
      case 'Keep planning':
        return '拒绝';
      case 'Plan review':
        return '计划待审';
    }
  }
  return text;
}

/// 计划评审询问的自由填提示（决策卡无自由填，仅通用流兜底时用）。
String questionCustomHint(Map q) {
  final intent = (q['intent'] as Map?)?['kind'];
  return intent == 'plan-review' ? '反馈意见（可选）' : '补充说明（可选）';
}

/// 计划评审收窄判定（对齐 web `planReviewOf`）：单题、intent.plan-review、
/// 带 detail、非多选、≤2 选项、intent.approve 命中其一。命中则走决策卡，
/// 否则退回通用问答流。
Map<String, dynamic>? planReviewOf(List<Map<String, dynamic>> questions) {
  if (questions.length != 1) return null;
  final q = questions[0];
  final intent = q['intent'];
  if (intent is! Map || intent['kind'] != 'plan-review') return null;
  final plan = '${q['detail'] ?? ''}';
  if (plan.trim().isEmpty) return null;
  if (q['multiSelect'] == true) return null;
  final options = (q['options'] as List? ?? []).whereType<Map>().toList();
  if (options.length > 2) return null;
  final approveLabel = '${intent['approve'] ?? ''}';
  Map? approve;
  Map? decline;
  for (final o in options) {
    if ('${o['label']}' == approveLabel) {
      approve = o;
    } else {
      decline = o;
    }
  }
  if (approve == null) return null;
  return {
    'id': '${q['id']}',
    'question': '${q['question'] ?? ''}',
    'plan': plan,
    'approveLabel': '${approve['label']}',
    'approveDesc': '${approve['description'] ?? ''}',
    if (decline != null) 'declineLabel': '${decline['label']}',
    if (decline != null) 'declineDesc': '${decline['description'] ?? ''}',
  };
}

/// 待答交互的作答区（替代消息输入框）：询问 = 选项点选 + 自由填 + 提交；
/// 授权 = 允许一次 / 拒绝；计划评审 = 决策卡（对齐 web PlanReviewPanel）。
/// 协议应答经 [onAnswer]/[onPass]/[onDismiss] 上行。
class InteractionComposer extends StatefulWidget {
  final PendingInteraction interaction;
  final Future<void> Function(String eventId, Object? value) onAnswer;
  final Future<void> Function(String eventId) onPass;
  final Future<void> Function(String eventId) onDismiss;

  const InteractionComposer({
    super.key,
    required this.interaction,
    required this.onAnswer,
    required this.onPass,
    required this.onDismiss,
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
    return d.skipped ||
        d.selected.isNotEmpty ||
        d.custom.text.trim().isNotEmpty;
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
        SnackBar(content: Text('第 ${missing + 1} 题还没作答（可选选项、填文字或跳过）')),
      );
      return;
    }
    final answers = <Map<String, dynamic>>[
      for (var i = 0; i < _questions.length; i++)
        _answerOf(_questions[i], _drafts[i]),
    ];
    _run(
      () => widget.onAnswer(widget.interaction.eventId, {'answers': answers}),
    );
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
    // 单选末题不自动提交：与桌面一致「选完点提交」——误触即提交容错太差；
    // 提交按钮可见性由 session_page 的 Flexible 包裹保证（键盘弹出也收缩）。
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
    // 计划评审走决策卡（对齐 web PlanReviewPanel），不复用问答流。
    final review = approval ? null : planReviewOf(_questions);
    if (review != null) return _planReviewCard(context, review, p.eventId);
    final accent = approval ? Acc.orange(context) : scheme.primary;
    debugPrint(
      '[composer] build q=${_questions.length} page=$_page approval=$approval '
      'mqH=${MediaQuery.of(context).size.height.toStringAsFixed(0)} '
      'insets=${MediaQuery.of(context).viewInsets.bottom.toStringAsFixed(0)}',
    );
    return LayoutBuilder(
      builder: (context, cons) {
        debugPrint(
          '[composer] cons w=${cons.maxWidth.toStringAsFixed(0)} '
          'h=${cons.maxHeight == double.infinity ? 'INF' : cons.maxHeight.toStringAsFixed(0)} '
          'minH=${cons.minHeight == double.infinity ? 'INF' : cons.minHeight.toStringAsFixed(0)}',
        );
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          padding: const EdgeInsets.all(12),
          // 限高交给外层 Flexible 槽（随键盘/可用空间收缩），内容超高走内部
          // 滚动；此处不再写死 60% 屏高——那会在键盘弹出时超出可用空间，
          // 把底部按钮行裁出屏幕。
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    approval
                        ? Icons.lock_outline
                        : Icons.question_answer_outlined,
                    size: 15,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      approval
                          ? '工具请求授权'
                          : '回答询问 · 第 ${_page + 1}/${_questions.length} 题',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => widget.onPass(p.eventId)),
                    child: const Text('留给网页端'),
                  ),
                ],
              ),
              if (approval) ...[
                const SizedBox(height: 6),
                Text(
                  '${p.request['toolName'] ?? '工具'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ('${p.request['reason'] ?? ''}'.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${p.request['reason']}'.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => widget.onAnswer(p.eventId, 'rejected'),
                              ),
                        child: const Text('拒绝'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () =>
                                    widget.onAnswer(p.eventId, 'allowed-once'),
                              ),
                        child: const Text('允许一次'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // 一屏一题（与 web 端一致）：选项天然不用滚动，底部翻页/提交。
                // 滚动区限高 = 可用高度（键盘感知）− 卡片固定部分，保证
                // 「提交回答」按钮行始终贴在内容下方、可见可点——不能用
                // Flexible（继承到的约束在页面不同状态下时宽时紧，按钮行
                // 会被挤到屏外；真机实测两代构建均如此）。
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(
                      140.0,
                      math.min(
                        560.0,
                        MediaQuery.of(context).size.height -
                            MediaQuery.of(context).viewInsets.bottom -
                            320,
                      ),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [_questionEditor(_page)],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (_page > 0)
                      OutlinedButton(
                        onPressed: _busy ? null : () => setState(() => _page--),
                        child: const Text('上一题'),
                      ),
                    const Spacer(),
                    FilledButton(
                      // 主题 filledButtonStyle 的 minimumSize 是
                      // Size.fromHeight(48)（宽度=无穷大，供对话框通栏按钮）。
                      // 放进带 Spacer 的 Row 会要求最小宽 ∞、挤爆整行布局，
                      // release 下整行静默渲染成空白——「提交按钮不可见」的
                      // 根因。此处显式收窄为有限宽度。
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(88, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: _busy
                          ? null
                          : (_page < _questions.length - 1
                                ? () => setState(() => _page++)
                                : _submit),
                      child: Text(
                        _busy
                            ? '提交中…'
                            : _page < _questions.length - 1
                            ? '下一题'
                            : '提交回答',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 计划评审决策卡（对齐 web PlanReviewPanel）：
  /// 「计划待审」条 + 计划 Markdown 全文 + 去聊天里说 / 拒绝 / 确认执行。
  /// 无选项列表、无自由填、无「提交回答」。
  Widget _planReviewCard(
    BuildContext context,
    Map<String, dynamic> review,
    String eventId,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final plan = '${review['plan']}';
    final declineLabel = review['declineLabel'] as String?;
    void decide(String label) => _run(
      () => widget.onAnswer(eventId, {
        'answers': [
          {
            'id': '${review['id']}',
            'selected': [label],
          },
        ],
      }),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Acc.lightBlue(context).withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 条：圆点 + 计划待审
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: Acc.lightBlue(context),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '计划待审',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.onDismiss(eventId)),
                child: const Text('去聊天里说'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 主体：计划全文（限高滚动，键盘感知——保证决策按钮行始终可见）
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(
                140.0,
                math.min(
                  560.0,
                  MediaQuery.of(context).size.height -
                      MediaQuery.of(context).viewInsets.bottom -
                      320,
                ),
              ),
            ),
            child: SingleChildScrollView(child: MarkdownText(plan)),
          ),
          const SizedBox(height: 10),
          // 动作：拒绝（outline） / 确认执行（primary）
          Row(
            children: [
              const Spacer(),
              if (declineLabel != null) ...[
                OutlinedButton(
                  onPressed: _busy ? null : () => decide(declineLabel),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 10),
              ],
              FilledButton(
                // 同问答提交按钮：覆盖主题的无穷最小宽（见上文说明）。
                style: FilledButton.styleFrom(
                  minimumSize: const Size(88, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: _busy
                    ? null
                    : () => decide('${review['approveLabel']}'),
                child: Text(_busy ? '提交中…' : '确认执行'),
              ),
            ],
          ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header.isNotEmpty)
            Text(
              questionLabel(q, header),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
              ),
            ),
          Text(
            '${q['question'] ?? ''}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          // 携带正文的询问（如计划评审的 detail=完整计划）：正文全量渲染。
          if ('${q['detail'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: MarkdownText('${q['detail']}'.trim()),
            ),
          ],
          if (options.isNotEmpty) ...[
            const SizedBox(height: 6),
            // 选项一列一行：标签 + 描述常显，整行可点选/取消。
            for (final o in options)
              Builder(
                builder: (context) {
                  final label = '${o['label'] ?? ''}';
                  final desc = '${o['description'] ?? ''}'.trim();
                  final isSel = d.selected.contains(label);
                  return InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: d.skipped ? null : () => _select(q, d, label),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isSel
                            ? scheme.primary.withValues(alpha: 0.16)
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.4,
                              ),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: isSel
                              ? scheme.primary.withValues(alpha: 0.55)
                              : scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  questionLabel(q, label),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: isSel ? FontWeight.w600 : null,
                                  ),
                                ),
                                if (desc.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 1),
                                    child: Text(
                                      desc,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            if (multi)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '（可多选）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
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
              hintText: (q['intent'] as Map?)?['kind'] == 'plan-review'
                  ? questionCustomHint(q)
                  : (options.isEmpty ? '输入回答…' : '或填写自定义回答…'),
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
              icon: Icon(
                d.skipped ? Icons.undo : Icons.skip_next,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              label: Text(
                d.skipped ? '取消跳过' : '跳过此题',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
