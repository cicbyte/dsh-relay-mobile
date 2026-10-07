// 工具调用渲染层：元数据聚合（ToolEntry）、工具卡、计划/询问卡、轮尾已编辑卡与行级 diff。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../../widgets/interaction_composer.dart';
import '../../widgets/markdown_text.dart';
import 'formatting.dart';

/// 会话统计聚合（状态条 + 上下文详情面板共用数据形状）。
class SessionStats {
  int turns = 0;
  int steps = 0;
  int inTok = 0;
  int outTok = 0;
  int cacheTok = 0;

  /// 累计 tokens（投影路径=计费输入+输出；兜底路径=in+out+cache）
  int totalTok = 0;

  /// 缓存命中率（投影路径=cacheRead/计费输入；兜底路径=cache/(cache+in)）
  double? cachePct;

  /// 上下文占用（投影=压力投影；兜底=最近一次用量三和）
  int ctxTok = 0;

  /// 模型上下文窗口（宿主下发的真实值；null=未知，按 262K 估算）
  int? ctxWindow;

  /// 输出速度 tok/s（投影=全程解码吞吐；兜底=最近一轮）
  double tps = 0;
}

/// 工具调用聚合条目（tool/call + tool/result 按 callId 配对）。
class ToolEntry {
  String name = 'tool';
  String arguments = '';
  String argsPretty = '';
  String argSummary = '';
  String resultText = '';
  bool isError = false;
  bool hasResult = false;
  bool emitted = false;
  int? callMs; // tool/call 时间（epoch ms）
  int? resultMs; // tool/result 时间

  int? get durationMs =>
      (callMs != null && resultMs != null) ? resultMs! - callMs! : null;

  void setCall(String name, String args) {
    if (this.name == 'tool' && name.isNotEmpty) this.name = name;
    if (arguments.isEmpty && args.isNotEmpty) {
      arguments = args;
      argsPretty = prettyJson(args);
      argSummary = _argSummary(this.name, args);
    }
  }
}

// ---- 工具行呈现（对齐桌面 ui-tool：变体 → 图标/标题/摘要）----

/// 工具名 → 行变体（桌面 TOOL_VARIANTS 同表）。
String _toolVariant(String name) {
  switch (name) {
    case 'bash':
    case 'pwsh':
      return 'bash';
    case 'read':
    case 'read_image':
    case 'web_fetch':
    case 'cordis_package_inspect':
    case 'cordis_runtime_inspect':
      return 'read';
    case 'web_search':
    case 'grep':
    case 'glob':
      return 'search';
    case 'write':
      return 'write';
    case 'edit':
      return 'edit';
    case 'run_code':
      return 'code';
    default:
      return 'others';
  }
}

/// 工具专名图标（桌面 details-row/detailIcon 同表），未命中回退变体图标。
IconData? _toolIcon(String name) {
  switch (name) {
    case 'todo_write':
      return Icons.checklist;
    case 'ask_user_question':
      return Icons.help_outline;
    case 'subagent':
    case 'spawn_teammate':
    case 'list_agents':
    case 'send_message':
    case 'interrupt_agent':
    case 'wait_agent':
    case 'team_task_create':
    case 'team_task_get':
    case 'team_task_update':
    case 'team_task_list':
      return Icons.group_outlined;
    case 'create_goal':
    case 'get_goal':
    case 'update_goal':
      return Icons.flag_outlined;
    case 'schedule_create':
    case 'schedule_list':
    case 'schedule_delete':
    case 'schedule_update':
      return Icons.schedule;
    case 'terminal_open':
    case 'terminal_read':
    case 'terminal_list':
    case 'terminal_signal':
    case 'terminal_close':
      return Icons.terminal;
    case 'workflow':
    case 'ralph':
      return Icons.account_tree_outlined;
    case 'job_list':
    case 'job_output':
    case 'job_kill':
      return Icons.checklist;
    case 'read_image':
      return Icons.image_outlined;
  }
  switch (_toolVariant(name)) {
    case 'search':
      return Icons.search;
    case 'read':
      return Icons.menu_book_outlined;
    case 'bash':
      return Icons.terminal;
    case 'write':
    case 'edit':
      return Icons.edit_outlined;
    case 'code':
      return Icons.code;
    default:
      return Icons.auto_awesome; // others：桌面 SparkleRegular 同款
  }
}

/// 工具中文标题（桌面 locales.ts 同表），未命中回退变体标题。
String _toolTitle(String name) {
  const owned = {
    'bash': '运行命令',
    'pwsh': '运行命令',
    'read': '读取',
    'read_image': '读取图片',
    'web_search': '搜索',
    'grep': '搜索',
    'glob': '搜索',
    'write': '写入',
    'edit': '编辑',
    'run_code': '代码',
    'todo_write': '更新任务清单',
    'ask_user_question': '提问',
    'subagent': '创建子智能体',
    'list_agents': '查看子智能体',
    'send_message': '发送消息',
    'interrupt_agent': '中断智能体',
    'wait_agent': '等待子智能体',
    'spawn_teammate': '创建队友',
    'list_subagent_models': '查看可用模型',
    'job_list': '查看后台任务',
    'job_output': '读取任务输出',
    'job_kill': '取消后台任务',
    'create_goal': '创建目标',
    'get_goal': '查看目标',
    'update_goal': '更新目标',
    'schedule_create': '创建定时任务',
    'schedule_list': '查看定时任务',
    'schedule_delete': '删除定时任务',
    'schedule_update': '修改定时任务',
    'terminal_open': '创建终端',
    'terminal_read': '读取终端',
    'terminal_list': '查看终端',
    'terminal_signal': '发送终端信号',
    'terminal_close': '关闭终端',
    'workflow': '运行工作流',
    'ralph': '运行循环工作流',
    'session_search': '搜索会话',
  };
  final hit = owned[name];
  if (hit != null) return hit;
  switch (_toolVariant(name)) {
    case 'bash':
      return '运行命令';
    case 'read':
      return '读取';
    case 'search':
      return '搜索';
    case 'write':
      return '写入';
    case 'edit':
      return '编辑';
    case 'code':
      return '代码';
    default:
      return '工具调用';
  }
}

/// `C:\Users\zhyj\xx` → `~\xx`（桌面 abbreviateHomePath 同义）。
String _abbrHome(String p) {
  final home = Platform.environment['USERPROFILE'] ?? '';
  if (home.isEmpty) return p;
  final norm = p.replaceAll('/', r'\');
  final normHome = home.replaceAll('/', r'\');
  if (norm.toLowerCase().startsWith(normHome.toLowerCase())) {
    return '~${norm.substring(normHome.length)}';
  }
  return p;
}

String _firstLine(String text) {
  final i = text.indexOf('\n');
  return i == -1 ? text : text.substring(0, i);
}

/// 参数单行摘要（桌面 deriveSummary 同式）：按变体 key 偏好链取值。
String _argSummary(String toolName, String raw) {
  List<String> pref(String variant) {
    switch (variant) {
      case 'bash':
        return ['description', 'command'];
      case 'read':
        return ['path', 'file_path', 'url'];
      case 'search':
        return ['query', 'pattern', 'url'];
      case 'write':
      case 'edit':
        return ['path', 'file_path'];
      case 'code':
        return ['description'];
      default:
        return [];
    }
  }

  try {
    final v = jsonDecode(raw);
    if (v is! Map) return _firstLine('$v'.replaceAll('\n', ' '));
    // web_search：queries 数组逐条首行拼接（桌面同款特例）
    if (_toolVariant(toolName) == 'search' && v['queries'] is List) {
      final queries = (v['queries'] as List)
          .whereType<String>()
          .where((q) => q.isNotEmpty)
          .map(_firstLine)
          .toList();
      if (queries.isNotEmpty) return queries.join(', ');
    }
    for (final key in pref(_toolVariant(toolName))) {
      final val = v[key];
      if (val is String && val.isNotEmpty) {
        final line = _firstLine(val);
        return key == 'path' || key == 'file_path' ? _abbrHome(line) : line;
      }
    }
    for (final val in v.values) {
      if (val is String && val.isNotEmpty) return _firstLine(val);
    }
    return _firstLine(raw);
  } catch (_) {
    return _firstLine(raw.replaceAll('\n', ' '));
  }
}

  /// 一轮内单个文件的变更计数（编辑参数本地行级 diff，非宿主 git 摘要）。
class TurnEdit {
  final String path;
  int added = 0;
  int deleted = 0;
  TurnEdit(this.path);
}

/// 行级 LCS 增删计数（编辑片段规模小，O(n·m) 足够；超限退化为净变化）。
(int, int) diffLineCounts(String oldText, String newText) {
  final a = oldText.split('\n');
  final b = newText.split('\n');
  while (a.isNotEmpty && a.last.trim().isEmpty) {
    a.removeLast();
  }
  while (b.isNotEmpty && b.last.trim().isEmpty) {
    b.removeLast();
  }
  final n = a.length;
  final m = b.length;
  if (n * m > 4000000) {
    final d = m - n;
    return (d > 0 ? d : 0, d < 0 ? -d : 0);
  }
  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    final ai = a[i];
    final dpi = dp[i];
    final dpi1 = dp[i + 1];
    for (var j = m - 1; j >= 0; j--) {
      dpi[j] = ai == b[j]
          ? dpi1[j + 1] + 1
          : (dpi1[j] >= dpi[j + 1] ? dpi1[j] : dpi[j + 1]);
    }
  }
  final common = dp[0][0];
  return (m - common, n - common);
}

int _lineCount(String s) {
  final t = s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  if (t.trim().isEmpty) return 0;
  return t.split('\n').length;
}

/// 从变更工具参数估算行增删：write/create 全量 +N；edit/str_replace 走
/// 行级 diff；insert 只计新增。返回 (added, deleted)。
(int, int) editLineDelta(String name, String argsRaw) {
  Map<String, dynamic>? args;
  try {
    final v = jsonDecode(argsRaw);
    if (v is Map<String, dynamic>) args = v;
  } catch (_) {
    return (0, 0);
  }
  String? str(Object? v) => v is String ? v : null;
  switch (name) {
    case 'write':
      final c = str(args?['content']);
      return c == null ? (0, 0) : (_lineCount(c), 0);
    case 'edit':
      final o = str(args?['old_string']);
      final w = str(args?['new_string']);
      if (o == null || w == null) return (0, 0);
      return diffLineCounts(o, w);
    case 'str_replace_editor':
      switch (args?['command']) {
        case 'create':
          final c = str(args?['file_text']);
          return c == null ? (0, 0) : (_lineCount(c), 0);
        case 'str_replace':
          final o = str(args?['old_str']);
          final w = str(args?['new_str']);
          if (o == null || w == null) return (0, 0);
          return diffLineCounts(o, w);
        case 'insert':
          final w = str(args?['new_str']);
          return w == null ? (0, 0) : (_lineCount(w), 0);
        default:
          return (0, 0);
      }
    default:
      return (0, 0);
  }
}

/// 一次性变更工具（write/edit/str_replace_editor）的变更路径提取
/// （桌面 turn-deliverables mutationPath 同式；仅完整合法调用算产出）。
String? mutationPath(String name, String argsRaw) {
  Map<String, dynamic>? args;
  try {
    final v = jsonDecode(argsRaw);
    if (v is Map<String, dynamic>) args = v;
  } catch (_) {
    return null;
  }
  String? pv(Object? v) =>
      v is String && v.trim().isNotEmpty ? v : null;
  switch (name) {
    case 'write':
      return args?['content'] is String ? pv(args?['file_path']) : null;
    case 'edit':
      final old = args?['old_string'];
      final neu = args?['new_string'];
      if (old is String && old.isNotEmpty && neu is String && old != neu) {
        return pv(args?['file_path']);
      }
      return null;
    case 'str_replace_editor':
      final path = pv(args?['path']);
      if (path == null) return null;
      switch (args?['command']) {
        case 'create':
          return args?['file_text'] is String ? path : null;
        case 'str_replace':
          final os = args?['old_str'];
          return os is String && os.isNotEmpty ? path : null;
        case 'insert':
          return args?['insert_line'] is int &&
                  args?['new_str'] is String
              ? path
              : null;
        default:
          return null;
      }
    default:
      return null;
  }
}

/// 轮尾文件概览卡（桌面 ChangedFiles 同款文案）：「已编辑 N 个文件」/
/// 「已编辑 {名}」+ 行级增删（编辑参数本地 diff，同 git 摘要的绿/红呈现）；
/// 点按折叠展开完整清单；行点按进工作区文件阅读页。
class ChangedFilesCard extends StatefulWidget {
  final List<TurnEdit> edits;
  final void Function(String path)? onOpenFile;
  const ChangedFilesCard({required this.edits, this.onOpenFile});

  @override
  State<ChangedFilesCard> createState() => _ChangedFilesCardState();
}

class _ChangedFilesCardState extends State<ChangedFilesCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final edits = widget.edits;
    final single = edits.length == 1 ? edits.first : null;
    String base(String p) {
      final norm = p.replaceAll('\\', '/');
      final i = norm.lastIndexOf('/');
      return i == -1 ? norm : norm.substring(i + 1);
    }

    void open(String p) => widget.onOpenFile?.call(p);

    Widget counts(int added, int deleted, {double? alpha}) {
      if (added == 0 && deleted == 0) return const SizedBox.shrink();
      final a = alpha ?? 1.0;
      return Text(
        [
          if (added > 0) '+$added',
          if (deleted > 0) '−$deleted',
        ].join(' '),
        style: theme.textTheme.labelSmall?.copyWith(
          color: deleted > 0
              ? scheme.error.withValues(alpha: a)
              : Colors.green.shade600.withValues(alpha: a),
        ),
      );
    }

    final preview =
        edits.take(3).map((e) => base(e.path)).join('、');
    final rest = edits.length - 3;
    final canOpen = widget.onOpenFile != null;
    final totalAdded = edits.fold<int>(0, (s, e) => s + e.added);
    final totalDeleted = edits.fold<int>(0, (s, e) => s + e.deleted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: single != null && canOpen
              ? () => open(single.path)
              : edits.length > 1
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  single != null ? Icons.description_outlined : Icons.code,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              single != null
                                  ? '已编辑 ${base(single.path)}'
                                  : '已编辑 ${edits.length} 个文件',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: canOpen && single != null
                                    ? scheme.primary
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          counts(
                              single?.added ?? totalAdded,
                              single?.deleted ?? totalDeleted),
                        ],
                      ),
                      if (edits.length > 1 && !_expanded)
                        Text(
                          rest > 0 ? '$preview 等 ${edits.length} 个' : preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                          ),
                        ),
                      if (edits.length > 1 && _expanded)
                        for (final e in edits)
                          InkWell(
                            onTap: canOpen ? () => open(e.path) : null,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 1.5),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 12,
                                    color: scheme.onSurfaceVariant
                                        .withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      base(e.path),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color: canOpen
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant
                                                .withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  counts(e.added, e.deleted, alpha: 0.9),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
                if (edits.length > 1)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具调用卡片：状态图标 + 名称 + 参数摘要；点击展开（美化参数 / 结果 / 错误）。
class ToolCallCard extends StatefulWidget {
  final ToolEntry entry;
  const ToolCallCard({required this.entry});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = e.hasResult;
    // 询问工具：参数是结构化 questions，直接渲染问题卡而非原始 JSON。
    if (e.name == 'ask_user_question') {
      final questions = _parseMapList(e.arguments, 'questions');
      if (questions.isNotEmpty) return questionCard(context, e, questions);
    }
    // 计划工具：参数是完整计划 Markdown，按计划卡渲染（对齐 web presentCall：
    // 标题=计划首个 # 标题，正文=计划全文）。
    if (e.name == 'exit_plan_mode') {
      final plan = parseArgString(e.arguments, 'plan');
      if (plan.trim().isNotEmpty) return planCard(context, e, plan.trim());
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                // 变体/专名图标：状态着色（运行=琥珀、错误=红、完成=中性）
                // ——桌面 ToolRow 同式，替代旧的光秃 ✓/✗。
                Icon(
                  _toolIcon(e.name),
                  size: 15,
                  color: e.isError
                      ? scheme.error
                      : done
                      ? scheme.onSurfaceVariant
                      : Acc.orange(context),
                ),
                const SizedBox(width: 8),
                Text(
                  _toolTitle(e.name),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: e.isError ? scheme.error : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.arguments.isEmpty ? '' : e.argSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.callMs != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        [
                          fmtClock(e.callMs!, withSeconds: true),
                          if (e.durationMs != null)
                            '耗时 ${fmtDuration(e.durationMs!)}',
                        ].join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  if (e.arguments.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('参数', style: theme.textTheme.labelSmall),
                        const Spacer(),
                        copyIcon(e.argsPretty),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.argsPretty,
                      style: monoStyle.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Text('结果', style: theme.textTheme.labelSmall),
                      const Spacer(),
                      if (done && e.resultText.isNotEmpty)
                        copyIcon(e.resultText),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    done
                        ? (e.resultText.isEmpty ? '（空）' : e.resultText)
                        : '运行中…',
                    style: monoStyle.copyWith(
                      color: e.isError ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 从工具参数/结果 JSON 里安全取出对象列表（解析失败返回空 → 走通用卡兜底）。
  List<Map<String, dynamic>> _parseMapList(String json, String key) {
    try {
      final j = jsonDecode(json);
      final list = (j is Map ? j[key] as List? : null) ?? const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 从工具参数 JSON 里安全取出字符串字段（解析失败返回空 → 走通用卡兜底）。
  String parseArgString(String json, String key) {
    try {
      final j = jsonDecode(json);
      final v = j is Map ? j[key] : null;
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  /// exit_plan_mode 计划卡：标题=计划首个 # 标题，正文=计划 Markdown。
  Widget planCard(BuildContext context, ToolEntry e, String plan) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = _firstHeading(plan) ?? '计划';
    final done = e.hasResult;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                (e.isError
                        ? scheme.error
                        : done
                        ? Acc.green(context)
                        : Acc.lightBlue(context))
                    .withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 14,
                  color: Acc.lightBlue(context),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!done)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  )
                else
                  Icon(
                    e.isError ? Icons.close : Icons.check,
                    size: 14,
                    color: e.isError ? scheme.error : Acc.green(context),
                  ),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            MarkdownText(plan),
            if (done) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      e.isError ? Icons.close : Icons.check_circle,
                      size: 12,
                      color: e.isError ? scheme.error : Acc.green(context),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      e.isError
                          ? e.resultText
                          : (e.resultText.contains('approved')
                                ? '计划已批准 · 退出计划模式，开始执行'
                                : e.resultText),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: e.isError ? scheme.error : Acc.green(context),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                '等待评审…',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 计划的首个 Markdown 标题（对齐 web 的 firstHeading）。
  String? _firstHeading(String plan) {
    for (final line in plan.split('\n')) {
      final m = RegExp(r'^#{1,6}\s+(.+?)\s*$').firstMatch(line);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// ask_user_question 问题卡：问题/选项/多选标注 + 回答展示。
  Widget questionCard(
    BuildContext context,
    ToolEntry e,
    List<Map<String, dynamic>> questions,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final answers = _parseMapList(e.resultText, 'answers');

    Map<String, dynamic>? answerOf(String id) {
      for (final a in answers) {
        if ('${a['id']}' == id) return a;
      }
      return null;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (e.hasResult ? Acc.green(context) : Acc.orange(context))
                .withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.question_answer_outlined,
                  size: 14,
                  color: e.hasResult ? Acc.green(context) : Acc.orange(context),
                ),
                const SizedBox(width: 6),
                Text(
                  '询问 · ${questions.length} 个问题',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!e.hasResult)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  )
                else
                  Icon(Icons.check, size: 14, color: Acc.green(context)),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < questions.length; i++) ...[
              if (i > 0) const Divider(height: 16),
              questionBlock(
                context,
                i,
                questions[i],
                answerOf('${questions[i]['id'] ?? ''}'),
                e.hasResult,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget questionBlock(
    BuildContext context,
    int index,
    Map<String, dynamic> q,
    Map<String, dynamic>? answer,
    bool hasResult,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = '${q['header'] ?? ''}'.trim();
    final question = '${q['question'] ?? ''}'.trim();
    final detail = '${q['detail'] ?? ''}'.trim();
    final multi = q['multi_select'] == true;
    final options = (q['options'] as List? ?? []).whereType<Map>().toList();
    final selected = ((answer?['selected'] as List?) ?? const [])
        .whereType<String>()
        .toSet();
    final custom = '${answer?['custom'] ?? ''}'.trim();
    final answered = answer != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header.isNotEmpty)
          Text(
            questionLabel(q, header),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (question.isNotEmpty) ...[
          if (header.isNotEmpty) const SizedBox(height: 2),
          Text(question, style: theme.textTheme.bodyMedium),
        ],
        // 携带正文的询问（如计划评审的 detail=完整计划）：正文按 Markdown
        // 全量渲染，不再丢细节。
        if (detail.isNotEmpty) ...[
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
            child: MarkdownText(detail),
          ),
        ],
        if (options.isNotEmpty) ...[
          const SizedBox(height: 6),
          // 选项一列一行（标签 + 描述常显），回答按行展示，细节不丢失。
          for (final o in options)
            Builder(
              builder: (context) {
                final label = '${o['label'] ?? ''}';
                final desc = '${o['description'] ?? ''}'.trim();
                final isSel = selected.contains(label);
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isSel
                        ? Acc.green(context).withValues(alpha: 0.13)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSel
                          ? Acc.green(context).withValues(alpha: 0.5)
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
                              ? Acc.green(context)
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
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
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
        if (!hasResult) ...[
          const SizedBox(height: 6),
          Text(
            '等待回答…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else if (!answered) ...[
          const SizedBox(height: 6),
          Text(
            '（未作答）',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else if (selected.isEmpty && custom.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '（已跳过）',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else ...[
          // 回答一行一个：每条选项答案一行（含描述），自由填单独一行。
          const SizedBox(height: 8),
          for (final o in options)
            if (selected.contains('${o['label']}')) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.check_circle,
                      size: 13,
                      color: Acc.green(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      questionLabel(q, '${o['label']}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Acc.green(context),
                      ),
                    ),
                  ),
                ],
              ),
              if ('${o['description'] ?? ''}'.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 19, top: 1, bottom: 3),
                  child: Text(
                    '${o['description']}'.trim(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          if (custom.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.short_text,
                    size: 13,
                    color: Acc.green(context),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    custom,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Acc.green(context),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget copyIcon(String text) {
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
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
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// reasoning 思考块：折叠，展开显示灰字全文。
class ReasoningFold extends StatefulWidget {
  final String text;
  const ReasoningFold({required this.text});

  @override
  State<ReasoningFold> createState() => _ReasoningFoldState();
}

class _ReasoningFoldState extends State<ReasoningFold> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  _expanded ? '思考过程' : '思考过程（${widget.text.length} 字）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 3),
              child: Text(
                widget.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
