import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'message_widgets.dart';
import 'models.dart';

class _SessionEntry {
  _SessionEntry({
    required this.sid,
    required this.mtime,
    required this.messageCount,
    required this.preview,
    required this.isCurrent,
  });

  final String sid;
  final DateTime mtime;
  final int messageCount;
  final String preview;
  final bool isCurrent;
}

class SessionHistoryPage extends StatefulWidget {
  const SessionHistoryPage({
    super.key,
    required this.agentId,
    required this.host,
    required this.port,
  });

  final String agentId;
  final String host;
  final int port;

  @override
  State<SessionHistoryPage> createState() => _SessionHistoryPageState();
}

class _SessionHistoryPageState extends State<SessionHistoryPage> {
  bool _loading = true;
  List<_SessionEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/phone_agent_chat');
    final (currentSid, _) = await LocalStore.loadCurrentSession(widget.agentId);
    if (!await dir.exists()) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
      });
      return;
    }

    final sidPattern = RegExp(r'^chat_(.+)\.jsonl$');
    final sids = <String>{};
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      final m = sidPattern.firstMatch(name);
      if (m != null) sids.add(m.group(1)!);
    }
    final entries = <_SessionEntry>[];
    for (final sid in sids) {
      final file = File('${dir.path}/chat_$sid.jsonl');
      if (!await file.exists()) continue;
      final stat = await file.stat();
      final records = await LocalStore.loadAll(sid);
      if (records.isEmpty) continue;
      final (messages, _) = replayLocalRecords(records);
      if (messages.isEmpty) continue;
      final firstUser = messages.where((m) => m.kind == MessageKind.user);
      final previewSrc = firstUser.isNotEmpty
          ? firstUser.first.searchableText
          : messages.first.searchableText;
      final preview = previewSrc.length > 30
          ? '${previewSrc.substring(0, 30)}…'
          : previewSrc;
      entries.add(
        _SessionEntry(
          sid: sid,
          mtime: stat.modified,
          messageCount: messages.length,
          preview: preview.isEmpty ? '(无文字内容)' : preview,
          isCurrent: sid == currentSid,
        ),
      );
    }
    entries.sort((a, b) => b.mtime.compareTo(a.mtime));
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _fmtTime(DateTime t) {
    final l = t.toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${p2(l.month)}-${p2(l.day)} ${p2(l.hour)}:${p2(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('会话历史(本机全部聊天记录)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
          ? const Center(
              child: Text(
                '本机没有找到任何聊天记录文件',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = _entries[i];
                return ListTile(
                  leading: e.isCurrent
                      ? const Icon(Icons.chat_bubble, color: Colors.teal)
                      : const Icon(Icons.history, color: Colors.grey),
                  title: Text(
                    e.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_fmtTime(e.mtime)} · ${e.messageCount} 条${e.isCurrent ? ' · 当前会话' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _SessionReplayPage(
                        sid: e.sid,
                        host: widget.host,
                        port: widget.port,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _SessionReplayPage extends StatefulWidget {
  const _SessionReplayPage({
    required this.sid,
    required this.host,
    required this.port,
  });

  final String sid;
  final String host;
  final int port;

  @override
  State<_SessionReplayPage> createState() => _SessionReplayPageState();
}

class _SessionReplayPageState extends State<_SessionReplayPage> {
  bool _loading = true;
  List<ChatMessage> _messages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await LocalStore.loadAll(widget.sid);
    final (messages, _) = replayLocalRecords(records);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '只读回放 · ${widget.sid.length > 16 ? widget.sid.substring(0, 16) : widget.sid}',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.amber.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 12,
                  ),
                  child: const Text(
                    '只读历史——不会切换当前会话,也不会发送任何消息',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final rows = buildChatRows(_messages);
                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 8,
                        ),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          if (row.isBar) {
                            final g = row.group!;
                            return buildGroupBar(
                              context,
                              g,
                              onToggle: () =>
                                  setState(() => toggleGroup(_messages, g)),
                            );
                          }
                          return buildMessageWidget(
                            context,
                            _messages[row.index],
                            host: widget.host,
                            port: widget.port,
                            onCopy: (t) => copyToClipboard(context, t),
                            onToggleExpand: (m) => setState(
                              () => m.toolExpanded = !m.toolExpanded,
                            ),

                            onToggleCollapse: (m) => setState(() {
                              m.toolCollapsed = !m.toolCollapsed;
                              m.toolExpanded = !m.toolCollapsed;
                            }),
                            onDownload: (rel, name) => downloadFileVia(
                              context,
                              host: widget.host,
                              port: widget.port,
                              relPath: rel,
                              filename: name,
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
