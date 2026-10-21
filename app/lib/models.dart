import 'dart:collection';

import 'local_store.dart';
import 'runtime_status_policy.dart';

enum ConnStatus { connected, connecting, disconnected }

enum MessageKind { user, assistant, status, error, tool, done, narration }

class ChatAttachment {
  final String rel;
  final String mime;
  final String name;
  final int size;

  ChatAttachment({
    required this.rel,
    required this.mime,
    required this.name,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
    'rel': rel,
    'mime': mime,
    'name': name,
    'size': size,
  };

  factory ChatAttachment.fromJson(Map<String, dynamic> j) => ChatAttachment(
    rel: (j['rel'] ?? '') as String,
    mime: (j['mime'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
  );

  bool get isImage => mime.startsWith('image/');
  bool get isAudio => mime.startsWith('audio/');
}

class MediaAttachment {
  final String kind;
  final String url;
  final String name;
  final int size;
  final String mime;
  final String sha256;

  MediaAttachment({
    required this.kind,
    required this.url,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha256,
  });

  factory MediaAttachment.fromJson(Map<String, dynamic> j) => MediaAttachment(
    kind: (j['kind'] ?? 'file') as String,
    url: (j['url'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
    mime: (j['mime'] ?? '') as String,
    sha256: (j['sha256'] ?? '') as String,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'url': url,
    'name': name,
    'size': size,
    'mime': mime,
    'sha256': sha256,
  };

  static List<MediaAttachment> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => MediaAttachment.fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}

class ChatMessage {
  final MessageKind kind;
  final String text;
  final String ts;

  final String? statusKey;

  List<ChatAttachment> attachments = const [];

  List<MediaAttachment> mediaAttachments = const [];

  final String? toolName;
  final String? toolCmd;
  bool toolDone = false;
  bool toolOk = false;
  String? toolOut;
  String? toolImage;
  String? toolFile;
  String? toolFilename;
  int? toolFilesize;
  double? toolSec;
  String? toolVia;
  bool toolExpanded = false;

  bool toolCollapsed = false;

  bool grouped = false;
  bool groupOpen = false;

  String get toolCmdOneLine {
    final raw = (toolCmd ?? '').trim();
    if (raw.isEmpty) return '';
    final first = raw.split('\n').first.trim();
    final cut = first.length > 60 ? '${first.substring(0, 60)}…' : first;
    return (raw.contains('\n') && !cut.endsWith('…')) ? '$cut …' : cut;
  }

  static const _memoTools = {
    'memo_recall',
    'memo_store',
    'memo_handoff',
    'memo_facts',
  };
  bool get isMemoTool => _memoTools.contains(toolName);

  ChatMessage.user(this.text, this.ts, {List<ChatAttachment>? attachments})
    : kind = MessageKind.user,
      statusKey = null,
      toolName = null,
      toolCmd = null {
    if (attachments != null) this.attachments = attachments;
  }

  ChatMessage.assistant(
    this.text,
    this.ts, {
    List<MediaAttachment>? mediaAttachments,
  }) : kind = MessageKind.assistant,
       statusKey = null,
       toolName = null,
       toolCmd = null {
    if (mediaAttachments != null) this.mediaAttachments = mediaAttachments;
  }

  ChatMessage.status(this.text, this.ts, {this.statusKey})
    : kind = MessageKind.status,
      toolName = null,
      toolCmd = null;

  ChatMessage.error(this.text, this.ts)
    : kind = MessageKind.error,
      statusKey = null,
      toolName = null,
      toolCmd = null;

  ChatMessage.done(this.text, this.ts)
    : kind = MessageKind.done,
      statusKey = null,
      toolName = null,
      toolCmd = null;

  ChatMessage.narration(this.text, this.ts)
    : kind = MessageKind.narration,
      statusKey = null,
      toolName = null,
      toolCmd = null;

  ChatMessage.tool(this.toolName, this.toolCmd, this.ts)
    : kind = MessageKind.tool,
      statusKey = null,
      text = '' {
    toolCollapsed = true;
  }

  static void applyFrame(
    Map<String, dynamic> json,
    List<ChatMessage> out,
    Queue<ChatMessage> pendingTools,
  ) {
    final type = json['type'];
    final ts = (json['ts'] ?? '') as String;
    switch (type) {
      case 'status':
        final text = (json['text'] ?? '') as String;
        final statusKey = json['status_key'] as String?;
        if (statusKey == 'codex_connection' && json['state'] == 'connected') {
          _clearCurrentRetryStatus(out);
          break;
        }
        if (text.isNotEmpty) {
          final replaceKey = _replaceableStatusKey(text, statusKey);
          if (replaceKey != null) {
            var turnStart = 0;
            for (var i = out.length - 1; i >= 0; i--) {
              if (out[i].kind == MessageKind.user) {
                turnStart = i + 1;
                break;
              }
            }
            for (var i = out.length - 1; i >= turnStart; i--) {
              final message = out[i];
              if (message.kind == MessageKind.status &&
                  _replaceableStatusKey(message.text, message.statusKey) ==
                      replaceKey) {
                out.removeAt(i);
              }
            }
          }
          out.add(ChatMessage.status(text, ts, statusKey: statusKey));
        }
        break;
      case 'assistant':
        _clearCurrentRetryStatus(out);
        out.add(
          ChatMessage.assistant(
            (json['text'] ?? '') as String,
            ts,
            mediaAttachments: MediaAttachment.listFromJson(json['attachments']),
          ),
        );
        break;
      case 'narration':
        final n = (json['text'] ?? '') as String;
        if (n.trim().isNotEmpty) {
          _clearCurrentRetryStatus(out);
          out.add(ChatMessage.narration(n, ts));
        }
        break;
      case 'tool':
        _clearCurrentRetryStatus(out);
        final tool = ChatMessage.tool(
          json['name'] as String?,
          json['cmd'] as String?,
          ts,
        );
        pendingTools.add(tool);
        out.add(tool);
        break;
      case 'tool_result':
        _clearCurrentRetryStatus(out);
        if (pendingTools.isNotEmpty) {
          final tool = pendingTools.removeFirst();
          tool.applyResult(
            ok: json['ok'] == true,
            out: json['out'] as String?,
            image: json['image'] as String?,
            file: json['file'] as String?,
            filename: json['filename'] as String?,
            filesize: (json['filesize'] as num?)?.toInt(),
            sec: (json['sec'] as num?)?.toDouble(),
            via: json['via'] as String?,
            mediaAttachments: MediaAttachment.listFromJson(json['attachments']),
          );
        }
        break;
      case 'done':
        _clearCurrentRetryStatus(out);
        _drainPendingTools(pendingTools, '本轮已结束，但这个工具始终没回结果');
        out.add(ChatMessage.done((json['text'] ?? '') as String, ts));
        break;
      case 'error':
        _clearCurrentRetryStatus(out);
        _drainPendingTools(pendingTools, '本轮出错中断，这个工具没有结果');
        out.add(ChatMessage.error((json['text'] ?? '') as String, ts));
        break;
      case 'interrupted':
        _clearCurrentRetryStatus(out);
        _drainPendingTools(pendingTools, '已被打断，这个工具没有结果');
        break;
      default:
        break;
    }
  }

  static bool _isCodexProgressStatus(String text, String? statusKey) =>
      RuntimeStatusPolicy.isProgress(text, statusKey);

  static bool _isCodexRetryStatus(String text, String? statusKey) =>
      RuntimeStatusPolicy.isRetry(text, statusKey);

  static String? _replaceableStatusKey(String text, String? statusKey) {
    return RuntimeStatusPolicy.replacementKey(text, statusKey);
  }

  bool get isRuntimeStatus =>
      kind == MessageKind.status &&
      (_replaceableStatusKey(text, statusKey) != null ||
          text.startsWith('思考中…(codex '));

  static bool isRuntimeStatusFrame(Map<String, dynamic> frame) =>
      RuntimeStatusPolicy.frameKey(frame) != null;

  static void _clearCurrentRetryStatus(List<ChatMessage> out) {
    for (var i = out.length - 1; i >= 0; i--) {
      final message = out[i];
      if (message.kind == MessageKind.user) break;
      if (message.kind == MessageKind.status &&
          _isCodexRetryStatus(message.text, message.statusKey)) {
        out.removeAt(i);
      }
    }
  }

  String get searchableText {
    if (kind == MessageKind.tool) {
      return [
        toolName ?? '',
        toolCmd ?? '',
        toolOut ?? '',
      ].where((s) => s.isNotEmpty).join('\n');
    }
    return text;
  }

  void applyResult({
    required bool ok,
    String? out,
    String? image,
    String? file,
    String? filename,
    int? filesize,
    double? sec,
    String? via,
    List<MediaAttachment>? mediaAttachments,
  }) {
    toolDone = true;
    toolOk = ok;
    toolOut = out;
    toolImage = image;
    toolFile = file;
    toolFilename = filename;
    toolFilesize = filesize;
    toolSec = sec;
    toolVia = via;
    if (mediaAttachments != null) this.mediaAttachments = mediaAttachments;
  }
}

void collapseTurns(List<ChatMessage> msgs, {bool includeRunning = false}) {
  var i = 0;
  while (i < msgs.length) {
    var end = i + 1;
    while (end < msgs.length && msgs[end].kind != MessageKind.user) {
      end++;
    }
    if (msgs[i].kind == MessageKind.user) {
      _collapseOneTurn(
        msgs,
        i,
        end,
        includeRunning: includeRunning,
        headIsUser: true,
      );
    } else if (_hasProcess(msgs, i, end)) {
      _collapseOneTurn(
        msgs,
        i,
        end,
        includeRunning: includeRunning,
        headIsUser: false,
      );
    }
    i = end;
  }
}

bool _hasProcess(List<ChatMessage> msgs, int start, int end) {
  for (var k = start; k < end; k++) {
    final kind = msgs[k].kind;
    if (kind == MessageKind.tool || kind == MessageKind.narration) return true;
  }
  return false;
}

void _collapseOneTurn(
  List<ChatMessage> msgs,
  int start,
  int end, {
  required bool includeRunning,
  required bool headIsUser,
}) {
  final hasTerminal = () {
    for (var k = start; k < end; k++) {
      if (msgs[k].kind == MessageKind.done ||
          msgs[k].kind == MessageKind.error) {
        return true;
      }
    }
    return false;
  }();

  final settled = includeRunning || end < msgs.length || hasTerminal;
  if (!settled) return;

  final from = headIsUser ? start + 1 : start;
  var finalIdx = -1;
  for (var k = end - 1; k >= from; k--) {
    if (msgs[k].kind == MessageKind.assistant) {
      finalIdx = k;
      break;
    }
  }

  final stop = finalIdx >= 0 ? finalIdx : end;
  for (var k = from; k < stop; k++) {
    final m = msgs[k];
    if (m.kind == MessageKind.error) continue;
    if (m.kind == MessageKind.assistant && m.mediaAttachments.isNotEmpty) {
      continue;
    }

    if (m.grouped && !includeRunning) continue;
    m.grouped = true;
    m.groupOpen = false;
    if (m.kind == MessageKind.tool) {
      m.toolCollapsed = true;
      m.toolExpanded = false;
    }
  }
}

class ChatGroup {
  final int start;
  final int end;
  final bool open;
  final int steps;
  final int tools;
  final int failed;
  final int unfinished;

  final int narrations;

  const ChatGroup({
    required this.start,
    required this.end,
    required this.open,
    required this.steps,
    required this.tools,
    required this.failed,
    required this.unfinished,
    this.narrations = 0,
  });
}

class ChatRow {
  final int index;
  final ChatGroup? group;
  const ChatRow.message(this.index) : group = null;
  const ChatRow.bar(ChatGroup g) : group = g, index = -1;
  bool get isBar => group != null;
}

List<ChatRow> buildChatRows(List<ChatMessage> msgs) {
  final rows = <ChatRow>[];
  var i = 0;
  while (i < msgs.length) {
    if (!msgs[i].grouped) {
      if (!msgs[i].isRuntimeStatus) rows.add(ChatRow.message(i));
      i++;
      continue;
    }
    var j = i;
    var tools = 0;
    var failed = 0;
    var unfinished = 0;
    var narrations = 0;
    var visibleSteps = 0;
    while (j < msgs.length && msgs[j].grouped) {
      final m = msgs[j];
      if (m.isRuntimeStatus) {
        j++;
        continue;
      }
      visibleSteps++;
      if (m.kind == MessageKind.tool) {
        tools++;
        if (!m.toolDone) {
          unfinished++;
        } else if (!m.toolOk) {
          failed++;
        }
      } else if (m.kind == MessageKind.narration) {
        narrations++;
      }
      j++;
    }
    if (visibleSteps == 0) {
      i = j;
      continue;
    }
    final open = msgs[i].groupOpen;
    rows.add(
      ChatRow.bar(
        ChatGroup(
          start: i,
          end: j,
          open: open,
          steps: visibleSteps,
          tools: tools,
          failed: failed,
          unfinished: unfinished,
          narrations: narrations,
        ),
      ),
    );
    if (open) {
      for (var k = i; k < j; k++) {
        if (!msgs[k].isRuntimeStatus) rows.add(ChatRow.message(k));
      }
    }
    i = j;
  }
  return rows;
}

String runtimeStatusText(List<ChatMessage> msgs) {
  String? progress;
  for (var i = msgs.length - 1; i >= 0; i--) {
    final m = msgs[i];
    if (m.kind == MessageKind.user ||
        m.kind == MessageKind.done ||
        m.kind == MessageKind.error) {
      break;
    }
    if (m.kind != MessageKind.status) continue;
    if (ChatMessage._isCodexRetryStatus(m.text, m.statusKey)) {
      return '正在重连，任务保留…';
    }
    if (progress == null &&
        ChatMessage._isCodexProgressStatus(m.text, m.statusKey)) {
      final elapsed = RegExp(
        r'^Codex 已处理 (\d+(?:\.\d+)?) 分钟',
      ).firstMatch(m.text);
      progress = elapsed == null ? m.text : '处理中 · 已用 ${elapsed.group(1)} 分钟';
    }
  }
  return progress ?? '思考中…';
}

void toggleGroup(List<ChatMessage> msgs, ChatGroup g) {
  final next = !g.open;
  for (var k = g.start; k < g.end && k < msgs.length; k++) {
    msgs[k].groupOpen = next;
  }
}

void _drainPendingTools(Queue<ChatMessage> pendingTools, String reason) {
  while (pendingTools.isNotEmpty) {
    pendingTools.removeFirst().applyResult(ok: false, out: '[无结果] $reason');
  }
}

(List<ChatMessage>, Queue<ChatMessage>) replayLocalRecords(
  List<LocalRecord> records,
) {
  final initial = <ChatMessage>[];
  final pending = Queue<ChatMessage>();
  for (final r in records) {
    if (r.kind == 'user') {
      final rawAtts = r.payload['attachments'] as List<dynamic>? ?? const [];
      final atts = rawAtts
          .whereType<Map>()
          .map((e) => ChatAttachment.fromJson(e.cast<String, dynamic>()))
          .toList();
      initial.add(
        ChatMessage.user(
          (r.payload['text'] ?? '') as String,
          r.ts,
          attachments: atts,
        ),
      );
    } else {
      ChatMessage.applyFrame(r.payload, initial, pending);
    }
  }

  collapseTurns(initial, includeRunning: true);
  return (initial, pending);
}
