import 'transport_routes.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'avatar_widgets.dart';
import 'device_credentials.dart';
import 'media_bubbles.dart';
import 'models.dart';
import 'upload_client.dart';

const _downloaderChannel = MethodChannel('org.phoneagent.app/downloader');

Future<void> downloadFileVia(
  BuildContext context, {
  required String host,
  required int port,
  required String relPath,
  String? filename,
}) async {
  final url = backendUri(host, port, relPath).toString();
  final token = tokenFor(host, port);
  final name = filename ?? relPath.split('/').last;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await _downloaderChannel.invokeMethod('download', {
      'url': url,
      'filename': name,
      'token': token,
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text('已开始下载: $name'),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('下载失败: $e'), duration: const Duration(seconds: 2)),
    );
  }
}

Future<void> downloadAttachmentVia(
  BuildContext context, {
  required String host,
  required int port,
  required String rel,
  String? filename,
}) async {
  final url = attachmentUrl(host, port, rel);
  final token = tokenFor(host, port);
  final name = filename ?? rel.split('/').last;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await _downloaderChannel.invokeMethod('download', {
      'url': url,
      'filename': name,
      'token': token,
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text('已开始下载: $name'),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('下载失败: $e'), duration: const Duration(seconds: 2)),
    );
  }
}

class VoiceBubble extends StatefulWidget {
  final String url;
  const VoiceBubble({super.key, required this.url});

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await _player.play(UrlSource(widget.url));
      if (mounted) setState(() => _playing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _toggle,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_playing ? Icons.pause_circle : Icons.play_circle, size: 22),
            const SizedBox(width: 6),
            const Text('语音消息', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

Widget buildAttachmentWidget(
  BuildContext context,
  ChatAttachment a, {
  required String host,
  required int port,
}) {
  final url = attachmentUrl(host, port, a.rel);
  if (a.isImage) {
    final headers = authHeader(tokenFor(host, port));
    return GestureDetector(
      onTap: () => openImageViewer(context, url, headers: headers),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: 180,
          fit: BoxFit.cover,
          headers: headers,
        ),
      ),
    );
  }
  if (a.isAudio) {
    return VoiceBubble(
      url: attachmentUrlWithToken(host, port, tokenFor(host, port), a.rel),
    );
  }
  return GestureDetector(
    onTap: () => downloadAttachmentVia(
      context,
      host: host,
      port: port,
      rel: a.rel,
      filename: a.name,
    ),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, size: 16),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              a.name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            formatBytes(a.size),
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    ),
  );
}

void copyToClipboard(BuildContext context, String text) {
  if (text.isEmpty) return;
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
  );
}

String composeWithQuote(String text, String? quoted) {
  final q = quoted?.trim() ?? '';
  if (q.isEmpty) return text;
  final block = q.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');
  return text.isEmpty ? block : '$block\n\n$text';
}

Future<void> showMessageActionSheet(
  BuildContext context,
  String rawText, {
  required void Function(String text) onCopy,
  void Function(String text)? onQuote,
}) {
  if (rawText.trim().isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _MessageActionSheet(rawText: rawText, onCopy: onCopy, onQuote: onQuote),
  );
}

class _MessageActionSheet extends StatefulWidget {
  final String rawText;
  final void Function(String text) onCopy;
  final void Function(String text)? onQuote;

  const _MessageActionSheet({
    required this.rawText,
    required this.onCopy,
    this.onQuote,
  });

  @override
  State<_MessageActionSheet> createState() => _MessageActionSheetState();
}

class _MessageActionSheetState extends State<_MessageActionSheet> {
  String _selected = '';

  void _finish(String text, {required bool quote}) {
    Navigator.of(context).pop();
    if (quote) {
      widget.onQuote?.call(text);
    } else {
      widget.onCopy(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSel = _selected.trim().isNotEmpty;
    final canQuote = widget.onQuote != null;
    final target = hasSel ? _selected : widget.rawText;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              hasSel ? '已选中 ${_selected.length} 个字符' : '拖动选中要引用的片段；不选则整条引用',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SelectableText(
                widget.rawText,
                style: const TextStyle(fontSize: 14, height: 1.4),
                onSelectionChanged: (selection, cause) {
                  final t = (selection.isValid && !selection.isCollapsed)
                      ? selection.textInside(widget.rawText)
                      : '';
                  if (t != _selected) setState(() => _selected = t);
                },
              ),
            ),
          ),
          const Divider(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),

            child: Row(
              children: [
                if (canQuote)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _finish(target, quote: true),
                      icon: const Icon(Icons.format_quote, size: 18),
                      label: Text(
                        hasSel ? '引用选中的 ${_selected.length} 字' : '引用这条',
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _finish(target, quote: false),
                      icon: const Icon(Icons.copy, size: 18),
                      label: Text(hasSel ? '复制选中' : '复制原文'),
                    ),
                  ),
                if (canQuote) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _finish(target, quote: false),
                    child: const Text(
                      '复制到剪贴板',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String formatBytes(int? bytes) {
  if (bytes == null) return '?';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

IconData toolIcon(ChatMessage m) {
  if (m.isMemoTool) return Icons.psychology_alt;
  if (m.toolName == 'phone_screenshot') return Icons.screenshot;
  if (m.toolName == 'file_pull' ||
      m.toolName == 'file_push' ||
      m.toolName == 'file_list') {
    return Icons.folder_open;
  }
  if (m.toolName == 'pai_submit' || m.toolName == 'pai_status')
    return Icons.send_to_mobile;
  return Icons.terminal;
}

void openImageViewer(
  BuildContext context,
  String url, {
  Map<String, String>? headers,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Image.network(url, headers: headers),
          ),
        ),
      ),
    ),
  );
}

Widget buildMessageWidget(
  BuildContext context,
  ChatMessage m, {
  required String host,
  required int port,
  required void Function(String text) onCopy,
  required void Function(ChatMessage m) onToggleExpand,
  required void Function(String relPath, String? filename) onDownload,

  void Function(ChatMessage m)? onToggleCollapse,
  String? agentId,
  String? agentDisplayName,

  void Function(String text)? onQuote,
}) {
  switch (m.kind) {
    case MessageKind.user:
      return _bubble(
        context,
        m,
        alignRight: true,
        onCopy: onCopy,
        onQuote: onQuote,
        host: host,
        port: port,
      );
    case MessageKind.assistant:
      return _bubble(
        context,
        m,
        alignRight: false,
        onCopy: onCopy,
        onQuote: onQuote,
        renderMarkdown: true,
        agentId: agentId,
        agentDisplayName: agentDisplayName,
        host: host,
        port: port,
      );
    case MessageKind.narration:
      return _narrationLine(context, m, onCopy: onCopy, onQuote: onQuote);
    case MessageKind.status:
      return _centerText(m.text, Colors.grey);
    case MessageKind.error:
      return _centerText(m.text, Colors.redAccent);
    case MessageKind.done:
      return _centerText(m.text, Colors.grey.shade600, small: true);
    case MessageKind.tool:
      return _toolCard(
        context,
        m,
        host: host,
        port: port,
        onCopy: onCopy,
        onQuote: onQuote,
        onToggleExpand: onToggleExpand,
        onToggleCollapse: onToggleCollapse,
        onDownload: onDownload,
      );
  }
}

String stripLightMarkdown(String s) {
  var t = s.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*', dotAll: true),
    (m) => m.group(1)!,
  );
  t = t.replaceAllMapped(
    RegExp(r'(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])', dotAll: true),
    (m) => m.group(1)!,
  );
  t = t.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

Widget _narrationLine(
  BuildContext context,
  ChatMessage m, {
  required void Function(String text) onCopy,
  void Function(String text)? onQuote,
}) {
  final text = stripLightMarkdown(m.text);
  if (text.isEmpty) return const SizedBox.shrink();
  final scheme = Theme.of(context).colorScheme;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: () => showMessageActionSheet(
      context,
      m.text,
      onCopy: onCopy,
      onQuote: onQuote,
    ),
    child: Container(
      margin: const EdgeInsets.fromLTRB(4, 5, 26, 5),
      padding: const EdgeInsets.only(left: 10),

      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: scheme.primary.withValues(alpha: 0.35),
            width: 2,
          ),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.88),
        ),
      ),
    ),
  );
}

Widget _centerText(String text, Color color, {bool small = false}) {
  if (text.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Center(
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: small ? 11 : 13),
        textAlign: TextAlign.center,
      ),
    ),
  );
}

Widget _bubble(
  BuildContext context,
  ChatMessage m, {
  required bool alignRight,
  required void Function(String text) onCopy,
  void Function(String text)? onQuote,
  bool renderMarkdown = false,
  String? agentId,
  String? agentDisplayName,
  String? host,
  int? port,
}) {
  final bg = alignRight
      ? Theme.of(context).colorScheme.primaryContainer
      : Theme.of(context).colorScheme.surfaceContainerHighest;
  final hasAttachments = m.attachments.isNotEmpty;
  final hasMediaAttachments = m.mediaAttachments.isNotEmpty;

  final bubble = GestureDetector(
    onLongPress: () => showMessageActionSheet(
      context,
      m.text,
      onCopy: onCopy,
      onQuote: onQuote,
    ),
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),

      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * (alignRight ? 0.88 : 1.0),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(alignRight ? 18 : 4),
          bottomRight: Radius.circular(alignRight ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.text.isNotEmpty)
            (renderMarkdown ? _markdownText(context, m.text) : Text(m.text)),
          if (hasAttachments && m.text.isNotEmpty) const SizedBox(height: 6),
          if (hasAttachments && host != null && port != null)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: m.attachments
                  .map(
                    (a) => buildAttachmentWidget(
                      context,
                      a,
                      host: host,
                      port: port,
                    ),
                  )
                  .toList(),
            ),

          if (hasMediaAttachments && (m.text.isNotEmpty || hasAttachments))
            const SizedBox(height: 6),
          if (hasMediaAttachments && host != null && port != null)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: m.mediaAttachments
                  .map(
                    (a) =>
                        MediaAttachmentBubble(att: a, host: host, port: port),
                  )
                  .toList(),
            ),
        ],
      ),
    ),
  );
  if (alignRight) {
    return Align(alignment: Alignment.centerRight, child: bubble);
  }

  if (agentId == null || agentId.isEmpty) {
    return Align(alignment: Alignment.centerLeft, child: bubble);
  }
  final label = (agentDisplayName == null || agentDisplayName.isEmpty)
      ? agentId
      : agentDisplayName;
  return Align(
    alignment: Alignment.centerLeft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AgentAvatar(agentId: agentId, displayName: label, radius: 9),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        bubble,
      ],
    ),
  );
}

Widget _markdownText(BuildContext context, String text) {
  final theme = Theme.of(context);
  final base = DefaultTextStyle.of(context).style;
  final styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: base,
    pPadding: EdgeInsets.zero,
    listBullet: base,
    code: base.copyWith(
      fontFamily: 'monospace',
      fontSize: (base.fontSize ?? 14) - 1,
      backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
    ),
    tableHead: base.copyWith(fontWeight: FontWeight.bold),
    tableBody: base,
    tableBorder: TableBorder.all(
      color: theme.colorScheme.outlineVariant,
      width: 1,
    ),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    blockquoteDecoration: BoxDecoration(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(4),
    ),
  );
  return MarkdownBody(
    data: text,
    selectable: false,
    shrinkWrap: true,
    extensionSet: md.ExtensionSet.gitHubFlavored,
    styleSheet: styleSheet,
    builders: {'pre': _CodeBlockBuilder(base)},
  );
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final TextStyle base;
  _CodeBlockBuilder(this.base);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final codeText = element.textContent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          codeText.replaceAll(RegExp(r'\n$'), ''),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) - 1,
            color: Colors.white,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

Widget buildGroupBar(
  BuildContext context,
  ChatGroup g, {
  required VoidCallback onToggle,
}) {
  final scheme = Theme.of(context).colorScheme;

  final parts = <String>[
    g.narrations > 0 ? '${g.narrations} 段思考' : '${g.steps} 步',
  ];
  if (g.tools > 0) parts.add('${g.tools} 次工具');
  if (g.failed > 0) parts.add('${g.failed} 失败');
  if (g.unfinished > 0) parts.add('${g.unfinished} 未完成');
  final bad = g.failed > 0 || g.unfinished > 0;
  final tint = bad ? Colors.orangeAccent : scheme.outline;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onToggle,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(
          alpha: g.open ? 0.30 : 0.55,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            g.open ? Icons.unfold_less : Icons.more_horiz,
            size: 15,
            color: tint,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              '中间过程 · ${parts.join(' · ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: bad ? Colors.orangeAccent : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            g.open ? '收起' : '展开',
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
          Icon(
            g.open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
            size: 15,
            color: scheme.primary,
          ),
        ],
      ),
    ),
  );
}

Widget _toolCardCollapsed(
  BuildContext context,
  ChatMessage m, {
  required void Function(String text) onCopy,
  void Function(ChatMessage m)? onToggleCollapse,
  void Function(String text)? onQuote,
}) {
  final memo = m.isMemoTool;
  final scheme = Theme.of(context).colorScheme;
  final accent = memo ? Colors.deepPurple : scheme.outline;
  final raw = '${m.toolCmd ?? ''}\n${m.toolOut ?? ''}';

  final outLines = (m.toolOut ?? '')
      .split('\n')
      .where((s) => s.trim().isNotEmpty)
      .length;
  final tail = m.toolDone ? '${m.toolSec?.toStringAsFixed(1) ?? '?'}s' : '未完成';
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onToggleCollapse == null ? null : () => onToggleCollapse(m),
    onLongPress: () =>
        showMessageActionSheet(context, raw, onCopy: onCopy, onQuote: onQuote),
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(toolIcon(m), size: 14, color: accent),
          const SizedBox(width: 6),
          Text(
            m.toolName ?? 'tool',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: memo ? Colors.deepPurple : scheme.onSurfaceVariant,
            ),
          ),

          const Spacer(),
          const SizedBox(width: 6),
          if (m.toolDone)
            Icon(
              m.toolOk ? Icons.check_circle : Icons.cancel,
              size: 13,
              color: m.toolOk ? Colors.green : Colors.redAccent,
            )
          else
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
          const SizedBox(width: 5),
          Text(
            outLines > 0 ? '$tail · $outLines行' : tail,
            style: TextStyle(fontSize: 10, color: scheme.outline),
          ),
          Icon(Icons.keyboard_arrow_down, size: 16, color: scheme.outline),
        ],
      ),
    ),
  );
}

Widget _toolCard(
  BuildContext context,
  ChatMessage m, {
  required String host,
  required int port,
  required void Function(String text) onCopy,
  required void Function(ChatMessage m) onToggleExpand,
  required void Function(String relPath, String? filename) onDownload,
  void Function(ChatMessage m)? onToggleCollapse,
  void Function(String text)? onQuote,
}) {
  if (m.toolCollapsed) {
    return _toolCardCollapsed(
      context,
      m,
      onCopy: onCopy,
      onQuote: onQuote,
      onToggleCollapse: onToggleCollapse,
    );
  }
  final imageUrl = m.toolImage != null
      ? backendUri(host, port, m.toolImage!).toString()
      : null;
  final imageHeaders = authHeader(tokenFor(host, port));
  final outLines = (m.toolOut ?? '').split('\n');
  final isLong = outLines.length > 6;
  final displayOut = (isLong && !m.toolExpanded)
      ? outLines.take(6).join('\n')
      : m.toolOut ?? '';
  final memo = m.isMemoTool;
  final baseColor = memo
      ? Colors.deepPurple
      : Theme.of(context).colorScheme.outlineVariant;
  final bgColor = memo
      ? Colors.deepPurple.withValues(alpha: 0.12)
      : Theme.of(context).colorScheme.surfaceContainerHigh;

  final toolRaw = '${m.toolCmd ?? ''}\n${m.toolOut ?? ''}';
  return GestureDetector(
    onLongPress: () => showMessageActionSheet(
      context,
      toolRaw,
      onCopy: onCopy,
      onQuote: onQuote,
    ),
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: baseColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleCollapse == null ? null : () => onToggleCollapse(m),
            child: Row(
              children: [
                Icon(
                  toolIcon(m),
                  size: 16,
                  color: memo ? Colors.deepPurple : null,
                ),
                const SizedBox(width: 6),
                Text(
                  m.toolName ?? 'tool',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: memo ? Colors.deepPurple : null,
                  ),
                ),
                if (memo) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '记忆',
                      style: TextStyle(fontSize: 10, color: Colors.deepPurple),
                    ),
                  ),
                ],
                const Spacer(),
                if (m.toolDone)
                  Icon(
                    m.toolOk ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: m.toolOk ? Colors.green : Colors.redAccent,
                  )
                else
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (onToggleCollapse != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.keyboard_arrow_up,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              m.toolCmd ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          if (m.toolDone) ...[
            const SizedBox(height: 6),
            Text(
              '${m.toolSec?.toStringAsFixed(2) ?? '?'}s · via ${m.toolVia ?? '?'}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            if ((m.toolOut ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: isLong ? () => onToggleExpand(m) : null,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayOut,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      if (isLong)
                        Text(
                          m.toolExpanded ? '收起' : '展开（共${outLines.length}行）',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blueAccent,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (imageUrl != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () =>
                    openImageViewer(context, imageUrl, headers: imageHeaders),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    headers: imageHeaders,
                  ),
                ),
              ),
            ],
            if (m.toolFile != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => onDownload(m.toolFile!, m.toolFilename),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.insert_drive_file, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.toolFilename ?? m.toolFile!.split('/').last,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              formatBytes(m.toolFilesize),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.download, size: 18),
                    ],
                  ),
                ),
              ),
            ],
            if (m.mediaAttachments.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: m.mediaAttachments
                    .map(
                      (a) =>
                          MediaAttachmentBubble(att: a, host: host, port: port),
                    )
                    .toList(),
              ),
            ],
          ],
        ],
      ),
    ),
  );
}
