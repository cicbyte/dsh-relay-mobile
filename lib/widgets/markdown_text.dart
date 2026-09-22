import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// GFM Markdown 渲染（暗色主题定制）。
///
/// 支持：标题、段落、**加粗**/斜体/~~删除线~~、行内代码、围栏/缩进代码块、
/// 有序/无序（嵌套）列表、任务列表、引用、表格、链接、分割线、@提及/自动链接。
/// 链接点击复制到剪贴板（零依赖交互，不引 url_launcher）。
class MarkdownText extends StatelessWidget {
  final String data;

  /// 气泡内略缩小字号。
  final bool compact;

  const MarkdownText(this.data, {super.key, this.compact = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = (theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14))
        .copyWith(fontSize: compact ? 14.5 : 15, height: 1.55);
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['Consolas', 'Courier New'],
      fontSize: 13,
    );

    final style = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: base,
      h1: base.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.35),
      h2: base.copyWith(fontSize: 18, fontWeight: FontWeight.w700, height: 1.35),
      h3: base.copyWith(fontSize: 16.5, fontWeight: FontWeight.w600, height: 1.35),
      h4: base.copyWith(fontSize: 15.5, fontWeight: FontWeight.w600),
      h5: base.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      h6: base.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      del: base.copyWith(decoration: TextDecoration.lineThrough),
      code: mono.copyWith(
        color: scheme.primary,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
      ),
      codeblockDecoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquote: base.copyWith(color: scheme.onSurfaceVariant),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.only(left: 10),
      listIndent: 18,
      listBullet: base.copyWith(color: scheme.onSurfaceVariant),
      tableHead: base.copyWith(fontWeight: FontWeight.w600),
      tableBody: base.copyWith(fontSize: 13.5, height: 1.4),
      tableBorder: TableBorder.all(color: scheme.outlineVariant, width: 1),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      a: base.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
    );

    return MarkdownBody(
      data: data,
      extensionSet: md.ExtensionSet.gitHubWeb, // 表格/删除线/自动链接/@提及
      styleSheet: style,
      softLineBreak: true,
      onTapLink: (text, href, title) async {
        if (href == null || href.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: href));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('链接已复制：$href')));
        }
      },
    );
  }
}
