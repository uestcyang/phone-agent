import 'transport_routes.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_registry.dart';
import 'models.dart';

class AgentApiClient {
  final AgentSpec spec;

  String? sessionId;
  String? _currentRunId;
  bool busy = false;
  String? _pendingText;
  int _turnSeq = 0;

  final ValueNotifier<ConnStatus> status = ValueNotifier(
    ConnStatus.disconnected,
  );

  void Function(ChatMessage msg)? onAppendMessage;

  void Function({String? delta, String? finalText})? onAssistantUpdate;
  void Function()? onThinkingStart;
  void Function()? onThinkingEnd;
  void Function(String text)? onQueuedNotice;
  void Function(String text)? onInterruptedNotice;

  AgentApiClient(this.spec);

  Map<String, String> get _authHeaders => {
    if (spec.apiKey != null) 'Authorization': 'Bearer ${spec.apiKey}',
  };

  Uri _uri(String path) => backendUri(spec.host, spec.port, path);

  String get _sessionIdPrefKey => 'hermes_session_id_${spec.id}';

  Future<void> init() async {
    status.value = ConnStatus.connecting;
    try {
      final prefs = await SharedPreferences.getInstance();
      sessionId = prefs.getString(_sessionIdPrefKey);
      if (sessionId != null) {
        final r = await http
            .get(_uri('/api/sessions/$sessionId'), headers: _authHeaders)
            .timeout(const Duration(seconds: 8));
        if (r.statusCode != 200) sessionId = null;
      }
      if (sessionId == null) {
        final r = await http
            .post(
              _uri('/api/sessions'),
              headers: {..._authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'title': 'phone_agent_app ${spec.displayName}',
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (r.statusCode == 201 || r.statusCode == 200) {
          final obj = jsonDecode(r.body) as Map<String, dynamic>;
          sessionId =
              (obj['session'] as Map<String, dynamic>?)?['id'] as String?;
          if (sessionId != null)
            await prefs.setString(_sessionIdPrefKey, sessionId!);
        }
      }
      status.value = sessionId != null
          ? ConnStatus.connected
          : ConnStatus.disconnected;
    } catch (_) {
      status.value = ConnStatus.disconnected;
    }
  }

  Future<void> newSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionIdPrefKey);
    sessionId = null;
    await init();
  }

  Future<void> sendUserText(String text) async {
    if (sessionId == null) {
      await init();
      if (sessionId == null) {
        onAppendMessage?.call(
          ChatMessage.error('连接失败：session 未建立，检查网络/服务是否在跑', _nowTs()),
        );
        return;
      }
    }
    if (busy) {
      final stopped = await _tryStop();
      if (stopped) {
        onInterruptedNotice?.call('已打断上一条，正在处理新消息');
        unawaited(_startTurn(text));
      } else {
        _pendingText = text;
        onQueuedNotice?.call(text);
      }
    } else {
      unawaited(_startTurn(text));
    }
  }

  Future<bool> _tryStop() async {
    final runId = _currentRunId;
    if (runId == null) return false;
    try {
      final r = await http
          .post(_uri('/v1/runs/$runId/stop'), headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startTurn(String text) async {
    busy = true;
    final mySeq = ++_turnSeq;
    onThinkingStart?.call();
    final client = http.Client();
    try {
      final req = http.Request(
        'POST',
        _uri('/api/sessions/$sessionId/chat/stream'),
      );
      req.headers.addAll({..._authHeaders, 'Content-Type': 'application/json'});
      req.body = jsonEncode({'message': text});
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 20));
      if (streamed.statusCode != 200) {
        if (mySeq == _turnSeq) {
          onAppendMessage?.call(
            ChatMessage.error('HTTP ${streamed.statusCode}', _nowTs()),
          );
          _finishTurn(mySeq);
        }
        return;
      }
      var buf = '';
      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        if (mySeq != _turnSeq) continue;
        buf += chunk;
        while (buf.contains('\n\n')) {
          final idx = buf.indexOf('\n\n');
          final block = buf.substring(0, idx);
          buf = buf.substring(idx + 2);
          _handleSseBlock(block, mySeq);
        }
      }
    } catch (e) {
      if (mySeq == _turnSeq) {
        onAppendMessage?.call(ChatMessage.error('连接中断: $e', _nowTs()));
        _finishTurn(mySeq);
      }
    } finally {
      client.close();
    }
  }

  void _handleSseBlock(String block, int mySeq) {
    String? eventName;
    String? dataLine;
    for (final line in const LineSplitter().convert(block)) {
      if (line.startsWith('event: ')) eventName = line.substring(7).trim();
      if (line.startsWith('data: ')) dataLine = line.substring(6);
    }
    if (dataLine == null) return;
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(dataLine) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final runId = payload['run_id'] as String?;
    if (runId != null) _currentRunId = runId;
    switch (eventName) {
      case 'run.started':
        break;
      case 'message.started':
        onAppendMessage?.call(ChatMessage.assistant('', _nowTs()));
        break;
      case 'assistant.delta':
        final delta = payload['delta'] as String? ?? '';
        if (delta.isNotEmpty) onAssistantUpdate?.call(delta: delta);
        break;
      case 'tool.started':
      case 'tool.completed':
      case 'tool.failed':
        final name = payload['tool_name'] as String? ?? '?';
        final preview = payload['preview'] as String? ?? '';
        onAppendMessage?.call(
          ChatMessage.status(
            '🔧 $name${preview.isNotEmpty ? ": $preview" : ""}',
            _nowTs(),
          ),
        );
        break;
      case 'assistant.completed':
        final content = payload['content'] as String? ?? '';
        onAssistantUpdate?.call(finalText: content);
        break;
      case 'run.completed':
        break;
      case 'error':
        onAppendMessage?.call(
          ChatMessage.error(payload['message'] as String? ?? '未知错误', _nowTs()),
        );
        break;
      case 'done':
        _finishTurn(mySeq);
        break;
    }
  }

  void _finishTurn(int mySeq) {
    if (mySeq != _turnSeq) return;
    busy = false;
    _currentRunId = null;
    onThinkingEnd?.call();
    final pending = _pendingText;
    if (pending != null) {
      _pendingText = null;
      unawaited(_startTurn(pending));
    }
  }

  String _nowTs() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
  }

  void dispose() {
    status.dispose();
  }
}
