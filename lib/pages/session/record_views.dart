// 记录渲染层：内容块工具、消息气泡、系统事件 tiles（对齐桌面渲染口径）。

import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import '../../dsh/dsh_client.dart';
import '../../theme.dart';
import '../../widgets/markdown_text.dart';
import 'formatting.dart';
import 'tool_cards.dart';

  String contentText(dynamic content) {
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text' && b['text'] is String)
        parts.add(b['text'] as String);
    }
    return parts.join('\n');
  }

  /// content blocks → widgets：text=Markdown，image=图片，file=占位。
  List<Widget> contentBlocks(dynamic content) {
    final out = <Widget>[];
    if (content is! List) return out;
    for (final b in content) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.trim().isNotEmpty) out.add(MarkdownText(t));
        case 'image':
          out.add(imageBlock(b));
        case 'file':
          out.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.attach_file, size: 15),
                  Flexible(
                    child: Text(
                      '${b['name'] ?? 'file'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        default:
          break;
      }
    }
    return out;
  }

  Widget imageBlock(Map b) {
    final data = b['data'];
    if (data is String && data.isNotEmpty) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            base64Decode(data),
            width: 240,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text('[图片无法解码]'),
          ),
        );
      } catch (_) {
        /* fallthrough */
      }
    }
    return const Text('[图片]');
  }

  /// 消息块（对齐桌面：无「你/助手」文字标签——用户=右对齐气泡，
  /// 助手=左对齐纯内容流；时间/用量/复制收纳成小字 meta 行）。
  Widget messageBubble(
  BuildContext context, {
    required bool mine,
    required List<Widget> body,
    int? time,
    String? usage,
    String? copyText,
    bool interrupted = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      if (interrupted) '已中断',
      if (time != null) fmtClock(time),
      if (usage != null) usage,
    ].join(' · ');

    Widget? metaRow({bool below = false}) {
      final hasCopy = copyText != null && copyText.trim().isNotEmpty;
      if (meta.isEmpty && !hasCopy) return null;
      return Row(
        mainAxisAlignment: below ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (meta.isNotEmpty) ...[
            Text(
              meta,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
          if (hasCopy) ...[
            if (meta.isNotEmpty) const SizedBox(width: 8),
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: copyText));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
              child: Icon(
                Icons.copy,
                size: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      );
    }

    if (mine) {
      // 用户：右对齐气泡（宽 ≤85%），meta+复制 收在气泡下方右对齐
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.85,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: body.isEmpty
                  ? Text('(空)', style: theme.textTheme.bodyMedium)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < body.length; i++) ...[
                          if (i > 0) const SizedBox(height: 5),
                          body[i],
                        ],
                      ],
                    ),
            ),
            if (metaRow(below: true) != null) ...[
              const SizedBox(height: 3),
              metaRow(below: true)!,
            ],
          ],
        ),
      );
    }

    // 助手/其他：meta 在顶部右对齐（不再有图标+标签头），正文左对齐内容流
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (metaRow() != null) ...[
            metaRow()!,
            const SizedBox(height: 4),
          ],
          if (body.isEmpty)
            const Text('(空)')
          else
            for (var i = 0; i < body.length; i++) ...[
              if (i > 0) const SizedBox(height: 5),
              body[i],
            ],
        ],
      ),
    );
  }

  /// 单行事件胶囊：图标 + 主文 + 可选副文，用于生命周期/状态类事件。
  Widget chipTile(
  BuildContext context, {
    required IconData icon,
    required Color color,
    required String text,
    String? sub,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
                if (sub != null && sub.trim().isNotEmpty)
                  Text(
                    sub.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// todo/write：任务清单整表快照（计划/执行进度一目了然）。
  Widget todoTile(
  BuildContext context,
  WireRecord r) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final todos = (r.data['todos'] as List? ?? []).whereType<Map>().toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 13, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  '任务清单',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final t in todos)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch ('${t['status'] ?? ''}') {
                        'completed' => Icons.check_circle_outline,
                        'in_progress' => Icons.timelapse,
                        _ => Icons.circle_outlined,
                      },
                      size: 13,
                      color: switch ('${t['status'] ?? ''}') {
                        'completed' => Acc.green(context),
                        'in_progress' => Acc.amber(context),
                        _ => scheme.onSurfaceVariant,
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${t['content'] ?? ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          decoration: '${t['status'] ?? ''}' == 'completed'
                              ? TextDecoration.lineThrough
                              : null,
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
  }

  /// 合成注入（source.kind != user）：文件变动通知、skill、cron、goal 续轮等。
  Widget injectionTile(
  BuildContext context,
  WireRecord r,
  Map<String, dynamic> source) {
    final kind = '${source['kind'] ?? 'plugin'}';
    final summary = '${source['summary'] ?? ''}'.trim();
    final text = summary.isNotEmpty
        ? summary
        : contentText(r.data['content']).trim().split('\n').first;
    return chipTile(context,
      icon: Icons.input,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      text: '注入 · $kind',
      sub: text,
    );
  }

  Widget systemTile(
  BuildContext context,
  WireRecord r) {
    final scheme = Theme.of(context).colorScheme;
    switch (r.type) {
      case 'turn/start':
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Text(
            '— 第 ${r.data['turn'] ?? '?'} 轮 · ${fmtClock(r.time)} —',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        );
      case 'system/message':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
          child: Text(
            contentText(r.data['content'] ?? r.data['message']),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      // ---- 计划 / 任务 ----
      case 'todo/write':
        return todoTile(context, r);
      case 'plan/mode':
        final active = r.data['active'] == true;
        return chipTile(context,
          icon: Icons.map_outlined,
          color: Acc.lightBlue(context),
          text: active ? '计划模式 · 开启' : '计划模式 · 关闭',
        );
      // ---- 询问 / 授权 ----
      case 'approval/asked':
        final tool = '${r.data['toolName'] ?? '工具'}';
        final reason = '${r.data['reason'] ?? ''}';
        return chipTile(context,
          icon: Icons.lock_outline,
          color: Acc.orange(context),
          text: '授权询问 · $tool',
          sub: reason.isEmpty ? '等待授权' : reason,
        );
      case 'approval/decided':
        final outcome = '${r.data['outcome'] ?? ''}';
        final label = switch (outcome) {
          'allowed-once' => '允许一次',
          'rejected' => '拒绝',
          'cancelled' => '取消',
          'unavailable' => '不可用',
          _ => outcome,
        };
        final ok = outcome == 'allowed-once';
        return chipTile(context,
          icon: ok ? Icons.lock_open_outlined : Icons.block_outlined,
          color: ok ? Acc.green(context) : scheme.error,
          text: '授权结果 · $label',
        );
      // ---- 子agent ----
      case 'subagent/descriptor':
        final mode = '${r.data['mode'] ?? ''}';
        return chipTile(context,
          icon: Icons.account_tree_outlined,
          color: Acc.teal(context),
          text: '子agent · ${mode == 'one-shot' ? '一次性' : '可续聊'}',
          sub: '${r.data['provider'] ?? ''}',
        );
      // ---- 后台任务（workflow 运行记录） ----
      case 'tool-workflow/run-start':
        return chipTile(context,
          icon: Icons.run_circle_outlined,
          color: Acc.cyan(context),
          text: '后台任务 · ${r.data['name'] ?? ''}',
          sub: '${r.data['runId'] ?? ''}',
        );
      case 'tool-workflow/agent-start':
        return chipTile(context,
          icon: Icons.person_add_alt_outlined,
          color: Acc.cyan(context),
          text: '后台成员 #${r.data['seq'] ?? '?'} · ${r.data['label'] ?? ''}',
          sub: '${r.data['phase'] ?? ''}',
        );
      case 'tool-workflow/agent-end':
        return chipTile(context,
          icon: Icons.done_all,
          color: Acc.cyan(context),
          text: '后台成员完成 #${r.data['seq'] ?? '?'} · ${r.data['outcome'] ?? ''}',
        );
      case 'tool-workflow/run-end':
        return chipTile(context,
          icon: Icons.stop_circle_outlined,
          color: Acc.cyan(context),
          text: '后台任务结束 · ${r.data['stopReason'] ?? ''}',
        );
      // ---- 命令 ----
      case 'command/run':
        final args = '${r.data['args'] ?? ''}';
        return chipTile(context,
          icon: Icons.terminal,
          color: Acc.amber(context),
          text: '命令 · /${r.data['name'] ?? ''}${args.isEmpty ? '' : ' $args'}',
        );
      case 'command/done':
        if (r.data['kind'] != 'error') return const SizedBox.shrink();
        return chipTile(context,
          icon: Icons.error_outline,
          color: scheme.error,
          text: '命令失败 · ${r.data['text'] ?? ''}',
        );
      // ---- 上下文压缩 ----
      case 'compaction/start':
        return chipTile(context,
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 开始',
        );
      case 'compaction/summary':
        final n = (r.data['shadowedTokenCount'] as num? ?? 0).toInt();
        return chipTile(context,
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 完成',
          sub: n > 0 ? '压缩 ${fmtTokens(n)} tokens' : null,
        );
      case 'compaction/end':
        if (r.data['error'] == null) return const SizedBox.shrink();
        return chipTile(context,
          icon: Icons.error_outline,
          color: scheme.error,
          text: '上下文压缩 · 失败',
        );
      // ---- 目标 ----
      case 'goal/change':
        final goal = Map<String, dynamic>.from(r.data['goal'] as Map? ?? {});
        final objective = '${goal['objective'] ?? goal['goalId'] ?? ''}';
        final op = '${r.data['operation'] ?? ''}';
        return chipTile(context,
          icon: Icons.flag_outlined,
          color: Acc.pink(context),
          text:
              '目标 · ${op == 'clear'
                  ? '已清除'
                  : objective.isEmpty
                  ? op
                  : objective}',
        );
      // ---- 交付物 ----
      case 'deliverables/presented':
        final files = (r.data['files'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final paths = files
            .map((f) => '${f['path'] ?? ''}')
            .where((s) => s.isNotEmpty)
            .join('、');
        return chipTile(context,
          icon: Icons.inventory_2_outlined,
          color: Acc.green(context),
          text: '交付物 · ${files.length} 个文件',
          sub: paths,
        );
      // ---- 状态小事件 ----
      case 'model/selection':
        return chipTile(context,
          icon: Icons.tune,
          color: scheme.onSurfaceVariant,
          text: '模型 · ${r.data['model'] ?? r.data['modelId'] ?? ''}',
        );
      case 'agent-preset/selected':
        return chipTile(context,
          icon: Icons.smart_toy_outlined,
          color: scheme.onSurfaceVariant,
          text: '预设 · ${r.data['agentPreset'] ?? ''}',
        );
      case 'sandbox/mode':
        return chipTile(context,
          icon: Icons.security_outlined,
          color: scheme.onSurfaceVariant,
          text: '沙箱 · ${r.data['mode'] ?? ''}',
        );
      // ---- 权限 / 审批策略（与 sandbox/mode 同族状态条，web 端同组渲染） ----
      case 'permission/preset':
        return chipTile(context,
          icon: Icons.admin_panel_settings_outlined,
          color: scheme.onSurfaceVariant,
          text: '权限预设 · ${r.data['preset'] ?? ''}',
        );
      case 'approval/policy':
        return chipTile(context,
          icon: Icons.verified_user_outlined,
          color: scheme.onSurfaceVariant,
          text: '审批策略 · ${r.data['policy'] ?? ''}',
          sub: '${r.data['source'] ?? ''}' == 'delegation' ? '来源：委派' : null,
        );
      // ---- 模型重试（透明化卡顿/失败恢复） ----
      case 'llm/retry':
        final retryNo = '${r.data['retry'] ?? '?'}';
        final maxNo = '${r.data['maxRetries'] ?? ''}';
        final delayMs = (r.data['delayMs'] as num? ?? 0).toInt();
        final failure = r.data['failure'];
        final failText = failure is Map
            ? '${failure['message'] ?? failure['name'] ?? failure['code'] ?? ''}'
            : '$failure';
        return chipTile(context,
          icon: Icons.replay_outlined,
          color: Acc.amber(context),
          text:
              '模型重试 · 第 $retryNo${maxNo.isEmpty ? '' : '/$maxNo'} 次（${delayMs}ms 后）',
          sub: failText.isEmpty || failText == 'null' ? null : failText,
        );
      case 'llm/retry-started':
        return chipTile(context,
          icon: Icons.replay_outlined,
          color: Acc.amber(context),
          text: '模型重试开始 · 第 ${r.data['retry'] ?? '?'} 次',
        );
      // ---- 消息反馈（👍/👎 + 备注） ----
      case 'feedback/message-put':
        final note = '${r.data['note'] ?? ''}'.trim();
        return chipTile(context,
          icon: '${r.data['rating']}' == 'negative'
              ? Icons.thumb_down_alt_outlined
              : Icons.thumb_up_alt_outlined,
          color: Acc.teal(context),
          text: '消息反馈 · ${'${r.data['rating']}' == 'negative' ? '差评' : '好评'}',
          sub: note.isEmpty ? null : note,
        );
      case 'feedback/message-delete':
        return chipTile(context,
          icon: Icons.delete_outline,
          color: scheme.onSurfaceVariant,
          text: '消息反馈 · 已撤下',
        );
      case 'feedback/record':
        return chipTile(context,
          icon: Icons.rate_review_outlined,
          color: Acc.teal(context),
          text: '反馈记录 · ${r.data['kind'] ?? r.data['rating'] ?? ''}',
          sub: '${r.data['note'] ?? ''}'.trim().isEmpty
              ? null
              : '${r.data['note']}'.trim(),
        );
      // ---- 队列消息改写 / 撤回（inbox splice） ----
      // 语义：insert=入队、remove=出队（送达）、同事件两者并存=改写、
      // outcome:'canceled'=撤回。纯入队/出队是管道流量（会以 user/message
      // 呈现或随轮次消化），不渲染；只显示真正的撤回与改写。
      case 'agent/inbox/spliced':
        final inserted = (r.data['inserted'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final removed = (r.data['removedCount'] as num? ?? 0).toInt();
        final canceled = '${r.data['outcome'] ?? ''}' == 'canceled';
        final edited = removed > 0 && inserted.isNotEmpty;
        if (!canceled && !edited) return const SizedBox.shrink();
        final preview = inserted
            .map((m) => contentText(m['content'] ?? m))
            .where((s) => s.trim().isNotEmpty)
            .join('\n');
        return chipTile(context,
          icon: Icons.edit_note_outlined,
          color: Acc.pink(context),
          text: canceled
              ? '消息撤回'
              : '消息改写 · 撤下 $removed 条 / 补入 ${inserted.length} 条',
          sub: preview.isEmpty ? null : preview,
        );
      // ---- 定时任务变更 ----
      case 'schedule/change':
        final op = '${r.data['operation'] ?? ''}';
        final opLabel = switch (op) {
          'delete' => '已删除',
          'create' => '已创建',
          'update' => '已更新',
          _ => op,
        };
        return chipTile(context,
          icon: Icons.schedule_outlined,
          color: Acc.lightBlue(context),
          text: '定时任务 · $opLabel',
          sub: '${r.data['id'] ?? ''}',
        );
      // ---- B 档：低频事件折叠成一行小 tile，不刷屏也不失可见性 ----
      case 'assistant/attempt':
        return chipTile(context,
          icon: Icons.history_edu_outlined,
          color: scheme.onSurfaceVariant,
          text: '一次未完成的输出（随后重试）',
        );
      case 'hook/invoked':
        return chipTile(context,
          icon: Icons.bolt_outlined,
          color: scheme.onSurfaceVariant,
          text: '钩子 · ${r.data['name'] ?? r.data['hook'] ?? ''}',
        );
      case 'hook/result':
        if (r.data['error'] == null && '${r.data['ok']}' != 'false') {
          return const SizedBox.shrink();
        }
        return chipTile(context,
          icon: Icons.error_outline,
          color: scheme.error,
          text: '钩子失败 · ${r.data['name'] ?? r.data['hook'] ?? ''}',
          sub: '${r.data['error'] ?? r.data['message'] ?? ''}',
        );
      case 'subagent/catalog':
        return chipTile(context,
          icon: Icons.account_tree_outlined,
          color: scheme.onSurfaceVariant,
          text: '子agent 目录更新',
        );
      case 'subagent/model-selection-policy':
        return chipTile(context,
          icon: Icons.account_tree_outlined,
          color: scheme.onSurfaceVariant,
          text: '子agent 模型策略更新',
        );
      case 'team/member':
        return chipTile(context,
          icon: Icons.groups_outlined,
          color: Acc.cyan(context),
          text:
              '团队成员 · ${r.data['member'] is Map ? '${(r.data['member'] as Map)['name'] ?? (r.data['member'] as Map)['role'] ?? ''}' : ''}',
        );
      case 'team/task':
        return chipTile(context,
          icon: Icons.groups_outlined,
          color: Acc.cyan(context),
          text:
              '团队任务 · ${r.data['task'] is Map ? '${(r.data['task'] as Map)['title'] ?? (r.data['task'] as Map)['summary'] ?? (r.data['task'] as Map)['status'] ?? ''}' : ''}',
        );
      case 'team/message/queued':
        return chipTile(context,
          icon: Icons.groups_outlined,
          color: scheme.onSurfaceVariant,
          text: '团队消息 · 排队',
        );
      case 'team/message/delivered':
        return chipTile(context,
          icon: Icons.groups_outlined,
          color: scheme.onSurfaceVariant,
          text: '团队消息 · 已送达',
        );
      case 'compaction/prune':
        final range = Map<String, dynamic>.from(
          r.data['shadowedRange'] as Map? ?? {},
        );
        final tok = (r.data['shadowedTokenCount'] as num? ?? 0).toInt();
        return chipTile(context,
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 裁剪 #${range['start'] ?? '?'}–#${range['end'] ?? '?'}',
          sub: tok > 0 ? '${fmtTokens(tok)} tokens' : null,
        );
      default:
        // 剩余纯协议内部噪声不渲染（web 同样不显示）：step/*、turn/end、
        // request/*、session/end-seed、session/title-llm-request、
        // session-log-deepseek/*、tool/ptc-dispatch*、web/*。
        // session/title 单独走标题同步（见 _liveTitle），不落气泡。
        return const SizedBox.shrink();
    }
  }
