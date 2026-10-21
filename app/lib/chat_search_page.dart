import 'package:flutter/material.dart';

import 'global_search_index.dart';
import 'message_widgets.dart';
import 'models.dart';

String _p2(int n) => n.toString().padLeft(2, '0');

class ChatSearchPage extends StatefulWidget {
  const ChatSearchPage({super.key, this.currentAgentId, this.host, this.port});

  final String? currentAgentId;

  final String? host;
  final int? port;

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends State<ChatSearchPage> {
  final TextEditingController _queryCtrl = TextEditingController();
  final ScrollController _resultsCtrl = ScrollController();

  bool _loading = true;
  int _scanned = 0;
  int _totalSessions = 0;

  GlobalSearchIndex _index = GlobalSearchIndex.empty;
  List<IndexedMessage> _results = const [];

  @override
  void initState() {
    super.initState();
    _queryCtrl.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _queryCtrl.removeListener(_onQueryChanged);
    _queryCtrl.dispose();
    _resultsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final index = await GlobalSearchIndex.build(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _scanned = done;
          _totalSessions = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _index = index;
      _loading = false;
    });
    _onQueryChanged();
  }

  void _onQueryChanged() {
    final q = _queryCtrl.text.trim().toLowerCase();
    setState(() {
      _results = q.isEmpty
          ? const []
          : _index.messages.where((m) => m.haystackLower.contains(q)).toList();
    });
  }

  static String _roleLabel(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.user:
        return '我';
      case MessageKind.assistant:
        return '回复';
      case MessageKind.status:
        return '状态';
      case MessageKind.error:
        return '错误';
      case MessageKind.done:
        return '完成';
      case MessageKind.narration:
        return '思考';
      case MessageKind.tool:
        final n = m.toolName ?? '';
        return n.isEmpty ? '工具' : '工具·$n';
    }
  }

  static String _timeLabel(IndexedMessage m) {
    final d = m.sessionMtime.toLocal();
    final date = '${_p2(d.month)}-${_p2(d.day)}';
    final ts = m.message.ts.trim();
    if (ts.isEmpty) return date;
    final parsed = DateTime.tryParse(ts);
    if (parsed != null) {
      final l = parsed.toLocal();
      return '${_p2(l.month)}-${_p2(l.day)} ${_p2(l.hour)}:${_p2(l.minute)}';
    }
    return '$date $ts';
  }

  void _openHit(IndexedMessage hit) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _HitReplayPage(
          sid: hit.sid,
          agentId: hit.agentId,
          agentLabel: hit.agentLabel,
          hitIndex: hit.indexInSession,
          host: widget.host ?? '',
          port: widget.port ?? 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _queryCtrl,
          autofocus: true,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(
            hintText: '搜索全部 agent 的聊天记录…',
            hintStyle: const TextStyle(fontSize: 16),
            border: InputBorder.none,
            suffixIcon: _queryCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: '清空',
                    onPressed: () => _queryCtrl.clear(),
                  ),
          ),
        ),
      ),
      body: _loading ? _buildScanning() : _buildBody(theme),
    );
  }

  Widget _buildScanning() {
    final total = _totalSessions;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: total == 0 ? null : _scanned / total,
            ),
            const SizedBox(height: 16),
            Text(
              total == 0 ? '正在查找本机的聊天记录…' : '正在建立全局索引  $_scanned / $total 个会话',
              style: const TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return _buildIdle();
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '没有找到包含「$query」的消息',
          style: const TextStyle(fontSize: 15, color: Colors.grey),
        ),
      );
    }
    return Column(
      children: [
        _buildCountBar(theme),
        Expanded(
          child: ListView.builder(
            controller: _resultsCtrl,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
            itemCount: _results.length,
            itemBuilder: (context, i) =>
                _buildResultCard(theme, _results[i], query.toLowerCase()),
          ),
        ),
      ],
    );
  }

  Widget _buildCountBar(ThemeData theme) {
    final sessions = _results.map((r) => r.sid).toSet().length;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 14),
      child: Text(
        '共 ${_results.length} 条结果 · 来自 $sessions 个会话',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildIdle() {
    final unknown = _index.unknownSessionCount;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 14),
            const Text(
              '全局搜索',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '已索引本机 ${_index.sessionCount} 个会话、${_index.messages.length} 条消息\n'
              '不分角色、不分会话,输入关键词即可',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.grey,
                height: 1.5,
              ),
            ),
            if (unknown > 0) ...[
              const SizedBox(height: 12),
              Text(
                '其中 $unknown 个会话认不出属于哪个角色,会标为「未知角色」',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.orange.shade700,
                  height: 1.4,
                ),
              ),
            ],
            if (_index.truncated) ...[
              const SizedBox(height: 12),
              Text(
                '记录太多,只索引了最近的 ${GlobalSearchIndex.maxIndexedMessages} 条,'
                '更早的会话没有参与搜索',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.orange.shade700,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(
    ThemeData theme,
    IndexedMessage hit,
    String queryLower,
  ) {
    final isCurrent =
        widget.currentAgentId != null && hit.agentId == widget.currentAgentId;
    final unknown = hit.agentMatch == AgentMatch.unknown;
    final agentColor = unknown
        ? Colors.grey.shade600
        : theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openHit(hit),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: agentColor.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      hit.agentLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: agentColor,
                      ),
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 6),
                    Text(
                      '当前',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _roleLabel(hit.message),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _timeLabel(hit),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _snippet(theme, hit, queryLower),
            ],
          ),
        ),
      ),
    );
  }

  Widget _snippet(ThemeData theme, IndexedMessage hit, String queryLower) {
    final display = hit.message.searchableText
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const bodyStyle = TextStyle(fontSize: 15, height: 1.45);

    if (queryLower.isEmpty || display.isEmpty) {
      return Text(
        display,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: bodyStyle,
      );
    }

    final lower = display.toLowerCase();
    final at = lower.indexOf(queryLower);
    if (at < 0) {
      return Text(
        display,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: bodyStyle,
      );
    }

    const before = 28;
    const after = 140;
    final start = (at - before).clamp(0, display.length);
    final end = (at + queryLower.length + after).clamp(0, display.length);
    final window = display.substring(start, end);
    final windowLower = lower.substring(start, end);

    final spans = <TextSpan>[];
    if (start > 0) spans.add(const TextSpan(text: '…'));
    var cursor = 0;
    while (cursor < window.length) {
      final next = windowLower.indexOf(queryLower, cursor);
      if (next < 0) {
        spans.add(TextSpan(text: window.substring(cursor)));
        break;
      }
      if (next > cursor)
        spans.add(TextSpan(text: window.substring(cursor, next)));
      spans.add(
        TextSpan(
          text: window.substring(next, next + queryLower.length),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onPrimaryContainer,
            backgroundColor: theme.colorScheme.primaryContainer,
          ),
        ),
      );
      cursor = next + queryLower.length;
    }
    if (end < display.length) spans.add(const TextSpan(text: '…'));

    return Text.rich(
      TextSpan(children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: bodyStyle.copyWith(color: theme.colorScheme.onSurface),
    );
  }
}

class _HitReplayPage extends StatefulWidget {
  const _HitReplayPage({
    required this.sid,
    required this.agentId,
    required this.agentLabel,
    required this.hitIndex,
    required this.host,
    required this.port,
  });

  final String sid;
  final String? agentId;
  final String agentLabel;
  final int hitIndex;
  final String host;
  final int port;

  @override
  State<_HitReplayPage> createState() => _HitReplayPageState();
}

class _HitReplayPageState extends State<_HitReplayPage> {
  final GlobalKey _centerKey = GlobalKey();
  final ScrollController _scrollCtrl = ScrollController();

  bool _loading = true;
  List<ChatMessage> _messages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final msgs = await GlobalSearchIndex.messagesOf(widget.sid);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
  }

  int get _hit =>
      _messages.isEmpty ? 0 : widget.hitIndex.clamp(0, _messages.length - 1);

  Widget _item(int i) {
    final isHit = i == _hit;

    if (isHit &&
        _messages[i].kind == MessageKind.tool &&
        _messages[i].toolCollapsed) {
      _messages[i]
        ..toolCollapsed = false
        ..toolExpanded = true;
    }
    final bubble = buildMessageWidget(
      context,
      _messages[i],
      host: widget.host,
      port: widget.port,
      agentId: widget.agentId,
      agentDisplayName: widget.agentLabel,
      onCopy: (t) => copyToClipboard(context, t),
      onToggleExpand: (m) => setState(() => m.toolExpanded = !m.toolExpanded),
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
    if (!isHit) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: bubble,
      );
    }
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.55),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 0, 2),
            child: Text(
              '搜索命中',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          bubble,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.agentLabel, style: const TextStyle(fontSize: 17)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _loading
                    ? '只读全文 · 正在加载…'
                    : '只读全文 · 第 ${_hit + 1} / ${_messages.length} 条',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      ),

      floatingActionButton: _loading || _messages.isEmpty
          ? null
          : FloatingActionButton.small(
              tooltip: '回到命中的那条',
              onPressed: () => _scrollCtrl.animateTo(
                0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.my_location),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _messages.isEmpty
          ? const Center(
              child: Text(
                '这个会话没有可显示的内容',
                style: TextStyle(fontSize: 15, color: Colors.grey),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.amber.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                    vertical: 7,
                    horizontal: 12,
                  ),
                  child: Text(
                    '只读历史——不会切换当前会话,也不会发送任何消息',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollCtrl,
                    center: _centerKey,
                    anchor: 0.12,
                    slivers: [
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => _item(_hit - 1 - i),
                          childCount: _hit,
                        ),
                      ),
                      SliverList(
                        key: _centerKey,
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => _item(_hit + i),
                          childCount: _messages.length - _hit,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.of(context).size.height * 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
