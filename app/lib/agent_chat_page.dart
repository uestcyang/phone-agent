import 'package:flutter/material.dart';

import 'agent_registry.dart';
import 'agent_api_client.dart';
import 'models.dart';

class AgentChatPage extends StatefulWidget {
  final AgentSpec agent;
  const AgentChatPage({super.key, required this.agent});

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends State<AgentChatPage> {
  late AgentApiClient _client;
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _inputCtrl = TextEditingController();

  bool _thinking = false;
  String? _queuedText;
  String? _interruptedText;
  String _liveBuffer = '';
  int? _liveIndex;

  @override
  void initState() {
    super.initState();
    _client = AgentApiClient(widget.agent);
    _client.onAppendMessage = (m) {
      if (!mounted) return;
      setState(() {
        _messages.add(m);
        if (m.kind == MessageKind.assistant) {
          _liveIndex = _messages.length - 1;
          _liveBuffer = '';
        }
      });
      _scrollToBottom();
    };
    _client.onAssistantUpdate = ({String? delta, String? finalText}) {
      if (!mounted || _liveIndex == null) return;
      setState(() {
        if (finalText != null) {
          _liveBuffer = finalText;
        } else if (delta != null) {
          _liveBuffer += delta;
        }
        _messages[_liveIndex!] = ChatMessage.assistant(
          _liveBuffer,
          _messages[_liveIndex!].ts,
        );
      });
      _scrollToBottom();
    };
    _client.onThinkingStart = () {
      if (!mounted) return;
      setState(() {
        _thinking = true;
        _queuedText = null;
        _interruptedText = null;
      });
    };
    _client.onThinkingEnd = () {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _liveIndex = null;
      });
    };
    _client.onQueuedNotice = (text) {
      if (!mounted) return;
      setState(() => _queuedText = text);
    };
    _client.onInterruptedNotice = (text) {
      if (!mounted) return;
      setState(() {
        _interruptedText = text;
        _queuedText = null;
      });
    };
    _client.init();
  }

  @override
  void dispose() {
    _client.dispose();
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    final now = TimeOfDay.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';
    setState(() => _messages.add(ChatMessage.user(text, ts)));
    _scrollToBottom();
    _client.sendUserText(text);
    _inputCtrl.clear();
  }

  Future<void> _newSession() async {
    await _client.newSession();
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _thinking = false;
      _queuedText = null;
      _interruptedText = null;
      _liveIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.agent.displayName),
        actions: [
          IconButton(
            tooltip: '连接状态',
            icon: ValueListenableBuilder<ConnStatus>(
              valueListenable: _client.status,
              builder: (context, status, _) {
                return Icon(
                  Icons.circle,
                  size: 14,
                  color: _statusColor(status),
                );
              },
            ),
            onPressed: () => _client.init(),
          ),
          IconButton(
            tooltip: '新建会话',
            icon: const Icon(Icons.delete_sweep),
            onPressed: _newSession,
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.agent.note != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                widget.agent.note!,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              itemCount: _messages.length,
              itemBuilder: (context, i) => _buildBubble(_messages[i]),
            ),
          ),
          if (_thinking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '思考中…',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          if (_interruptedText != null)
            Container(
              width: double.infinity,
              color: Colors.orange.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Text(
                _interruptedText!,
                style: const TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          if (_queuedText != null)
            Container(
              width: double.infinity,
              color: Colors.blue.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Text(
                '排队中(该通道不支持硬打断，等当前轮结束后自动发送): $_queuedText',
                style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildBubble(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            decoration: BoxDecoration(
              color: Colors.teal.shade700,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(m.text, style: const TextStyle(color: Colors.white)),
          ),
        );
      case MessageKind.assistant:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            decoration: BoxDecoration(
              color: Colors.grey.shade800,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(m.text, style: const TextStyle(color: Colors.white)),
          ),
        );
      case MessageKind.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '❌ ${m.text}',
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        );
      case MessageKind.status:
      case MessageKind.tool:
      case MessageKind.done:
      case MessageKind.narration:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            m.text,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        );
    }
  }

  Color _statusColor(ConnStatus status) {
    switch (status) {
      case ConnStatus.connected:
        return Colors.green;
      case ConnStatus.connecting:
        return Colors.amber;
      case ConnStatus.disconnected:
        return Colors.red;
    }
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: TextField(
                  controller: _inputCtrl,
                  minLines: 1,
                  maxLines: 5,
                  enabled: true,
                  decoration: InputDecoration(
                    hintText: _thinking ? '输入打断/追加消息…' : '输入消息…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _send,
              icon: Icon(_thinking ? Icons.flash_on : Icons.send),
              color: _thinking ? Colors.orange : null,
            ),
          ],
        ),
      ),
    );
  }
}
