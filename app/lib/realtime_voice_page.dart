import 'transport_routes.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_credentials.dart';
import 'upload_client.dart';
import 'ws_client.dart';

({List<String> sentences, String remainder}) splitSpeakableVoiceText(
  String input, {
  bool flush = false,
}) {
  final sentences = <String>[];
  var remainder = input;

  final boundary = RegExp(r'[。！？!?；;，,：:\n]');
  while (true) {
    final match = boundary.firstMatch(remainder);
    if (match == null) break;
    final sentence = remainder.substring(0, match.end).trim();
    remainder = remainder.substring(match.end);
    if (sentence.isNotEmpty) sentences.add(sentence);
  }
  if (flush && remainder.trim().isNotEmpty) {
    sentences.add(remainder.trim());
    remainder = '';
  }
  return (sentences: sentences, remainder: remainder);
}

Duration? realtimeVoiceRestartDelay({
  required String eventKind,
  int? errorCode,
  int failureCount = 0,
}) {
  if (eventKind == 'final') return null;
  if (eventKind == 'listen_end') return const Duration(milliseconds: 180);
  if (eventKind != 'asr_error' || errorCode == 9) return null;
  final exponent = failureCount.clamp(0, 3);
  return Duration(seconds: 1 << exponent);
}

bool canResumeRealtimeVoiceListening({
  required bool running,
  required bool thinking,
  required bool speaking,
  required bool hasActiveTurn,
  required int ttsOutstanding,
  bool headsetDuplex = false,
}) =>
    running &&
    (headsetDuplex ||
        (!thinking && !speaking && !hasActiveTurn && ttsOutstanding == 0));

class RealtimeVoiceFastReply {
  final String text;
  final bool cancelSlow;
  final bool stopPlayback;

  const RealtimeVoiceFastReply(
    this.text, {
    this.cancelSlow = false,
    this.stopPlayback = false,
  });
}

String _normalizeVoiceFastText(String input) =>
    input.toLowerCase().replaceAll(RegExp(r'[\s，。！？!?、,.；;：:]'), '');

RealtimeVoiceFastReply? realtimeVoiceFastReply(
  String input, {
  DateTime? now,
  String? lastAnswer,
}) {
  final text = _normalizeVoiceFastText(input);
  if (text.isEmpty) return null;

  if ({'不用查了', '别查了', '取消搜索', '取消这条', '算了'}.contains(text)) {
    return const RealtimeVoiceFastReply(
      '好，已经取消。',
      cancelSlow: true,
      stopPlayback: true,
    );
  }
  if ({'闭嘴', '别说了', '不要说了', '停一下', '先停'}.contains(text)) {
    return const RealtimeVoiceFastReply('好。', stopPlayback: true);
  }
  if ({'再说一遍', '重复一下', '你刚才说什么'}.contains(text)) {
    final previous = lastAnswer?.trim() ?? '';
    if (previous.isNotEmpty) return RealtimeVoiceFastReply(previous);
    return const RealtimeVoiceFastReply('还没有可以重复的上一条回答。');
  }
  return null;
}

class _VoiceExchange {
  final String user;
  final String assistant;
  final bool interrupted;

  const _VoiceExchange({
    required this.user,
    required this.assistant,
    this.interrupted = false,
  });
}

class _PendingVoiceAudio {
  final String text;
  final int generation;
  final Future<Uint8List?> audio;

  const _PendingVoiceAudio({
    required this.text,
    required this.generation,
    required this.audio,
  });
}

class RealtimeVoicePage extends StatefulWidget {
  final String agentId;
  final String host;
  final int port;
  final WsClient ws;
  final bool previewMode;

  const RealtimeVoicePage({
    super.key,
    required this.agentId,
    required this.host,
    required this.port,
    required this.ws,
    this.previewMode = false,
  });

  @override
  State<RealtimeVoicePage> createState() => _RealtimeVoicePageState();
}

class _RealtimeVoicePageState extends State<RealtimeVoicePage> {
  static const MethodChannel _native = MethodChannel(
    'org.phoneagent.app/realtime_voice',
  );

  AudioPlayer? _voicePlayer;
  final ListQueue<_PendingVoiceAudio> _voiceAudioQueue = ListQueue();
  WebSocketChannel? _voiceWs;
  StreamSubscription<dynamic>? _voiceSub;
  StreamSubscription<void>? _voicePlayerCompleteSub;
  bool _connected = false;
  bool _running = true;
  bool _listening = false;
  bool _thinking = false;
  bool _speaking = false;
  bool _headsetDuplex = false;
  bool _disposed = false;
  double _level = 0;
  String _partial = '';
  String _userText = '';
  String _answer = '';
  String _sentenceBuffer = '';
  String? _pendingUtterance;
  String? _activeTurnId;
  String? _mutedTurnId;
  int _turnCounter = 0;
  int _asrFailureCount = 0;
  int _ttsOutstanding = 0;
  int _speechGeneration = 0;
  int? _activeSpeechGeneration;
  int _partialSeq = 0;
  bool _voiceAudioBusy = false;
  bool _nativeFallbackActive = false;
  String _voiceToken = '';
  bool _semanticCommitPending = false;
  String? _activeToolLabel;
  Timer? _listenRestart;
  Timer? _connectTimeout;
  Timer? _semanticEouTimer;
  final List<_VoiceExchange> _history = [];

  @override
  void initState() {
    super.initState();
    _native.setMethodCallHandler(_onNativeCall);
    if (widget.previewMode) {
      _connected = true;
      _listening = true;
      _partial = '继续说，我在听…';
      _userText = '这是一条合成预览消息。';
      _answer = '这里是预览回复，不代表已经调用服务端。';
      return;
    }
    unawaited(_native.invokeMethod('startSession'));
    unawaited(_connectVoice());
    unawaited(_startListening());
  }

  Future<AudioPlayer> _ensureVoicePlayer() async {
    final existing = _voicePlayer;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _voicePlayer = player;
    _voicePlayerCompleteSub = player.onPlayerComplete.listen((_) {
      if (!_disposed && _voiceAudioBusy && !_nativeFallbackActive) {
        _completeVoiceAudioItem();
      }
    });
    await player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          audioMode: AndroidAudioMode.inCommunication,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.none,
        ),
      ),
    );
    return player;
  }

  Future<void> _connectVoice() async {
    var token = widget.ws.token;
    if (token.isEmpty) {
      token = await DeviceCredentials.load(widget.host, widget.port) ?? '';
    }
    if (_disposed) return;
    if (token.isEmpty) {
      _showError('尚未取得该角色的设备鉴权，先回聊天页等连接成功');
      return;
    }
    _voiceToken = token;
    try {
      final channel = IOWebSocketChannel.connect(
        TransportRoutes.instance.uri(
          widget.host,
          widget.port,
          '/ws',
          websocket: true,
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      _voiceWs = channel;
      _voiceSub = channel.stream.listen(
        _onVoiceFrame,
        onError: (Object error, StackTrace _) => _voiceDisconnected('$error'),
        onDone: () => _voiceDisconnected('连接已关闭'),
        cancelOnError: true,
      );
      await channel.ready;
      if (_disposed || _voiceWs != channel) return;
      channel.sink.add(
        jsonEncode({
          'type': 'voice_hello',
          'incognito': widget.ws.incognito.value,
        }),
      );
      _connectTimeout?.cancel();
      _connectTimeout = Timer(const Duration(seconds: 5), () {
        if (!_connected && !_disposed) _showError('即时语音后端尚未就绪');
      });
    } catch (e) {
      _voiceDisconnected('$e');
    }
  }

  void _onVoiceFrame(dynamic raw) {
    if (raw is! String || _disposed) return;
    Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final type = frame['type'];
    if (type == 'voice_ready') {
      _connectTimeout?.cancel();
      setState(() => _connected = true);
      final pending = _pendingUtterance;
      if (pending != null) {
        _pendingUtterance = null;
        _sendUtterance(pending);
      }
      return;
    }
    if (type == 'voice_commit') {
      final seq = (frame['seq'] as num?)?.toInt();
      if (seq != _partialSeq || _semanticCommitPending || !_listening) return;
      _semanticCommitPending = true;
      _semanticEouTimer?.cancel();
      if (!widget.previewMode) {
        unawaited(_native.invokeMethod('stopListening'));
      }
      return;
    }
    final turnId = frame['turn_id']?.toString();
    if (turnId != null && turnId != _activeTurnId) return;
    if (type == 'voice_delta') {
      final delta = frame['text']?.toString() ?? '';
      if (delta.isEmpty) return;
      setState(() {
        _thinking = false;
        _answer += delta;
        _sentenceBuffer += delta;
      });
      if (_mutedTurnId != turnId) _speakCompleteSentences();
    } else if (type == 'voice_fast_done') {
      if (_mutedTurnId != turnId) _flushSpeech();
      setState(() {
        _thinking = frame['slow_pending'] == true;
        _activeToolLabel = null;
      });
    } else if (type == 'voice_tool') {
      final label = _voiceToolLabel(frame['name']?.toString() ?? '');
      final shouldAcknowledge = _answer.trim().isEmpty && _ttsOutstanding == 0;
      setState(() => _activeToolLabel = label);
      if (shouldAcknowledge) _enqueueSpeech('正在$label。');
    } else if (type == 'voice_tool_result') {
      setState(() => _activeToolLabel = '整理实查结果');
    } else if (type == 'voice_done') {
      if (_mutedTurnId == turnId) {
        _sentenceBuffer = '';
      } else {
        _flushSpeech();
      }
      final completedUser = _userText;
      final completedAnswer = _answer.trim();
      if (completedUser.isNotEmpty || completedAnswer.isNotEmpty) {
        _history.add(
          _VoiceExchange(user: completedUser, assistant: completedAnswer),
        );
        if (_history.length > 6) _history.removeAt(0);
      }
      setState(() {
        _thinking = false;
        _activeTurnId = null;
        if (_mutedTurnId == turnId) _mutedTurnId = null;
        _activeToolLabel = null;
      });
      _maybeResumeListening();
    } else if (type == 'voice_error') {
      setState(() {
        _thinking = false;
        _activeTurnId = null;
        _activeToolLabel = null;
      });
      _showError(frame['text']?.toString() ?? '即时语音请求失败');
      _maybeResumeListening();
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'event' || _disposed) return;
    final event = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    final kind = event['kind']?.toString();
    if (kind == 'session_start') {
      if (mounted) {
        setState(() => _headsetDuplex = event['headsetDuplex'] == true);
      }
    } else if (kind == 'session_stop') {
      if (mounted) setState(() => _headsetDuplex = false);
    } else if (kind == 'listen_start' || kind == 'ready') {
      if (kind == 'ready') _asrFailureCount = 0;
      _semanticCommitPending = false;
      if (mounted) setState(() => _listening = true);
    } else if (kind == 'level') {
      final raw = (event['value'] as num?)?.toDouble() ?? 0;
      if (mounted) setState(() => _level = ((raw + 2) / 12).clamp(0, 1));
    } else if (kind == 'speech_start') {
      if (_headsetDuplex && _speaking) _stopPlaybackForBargeIn();
      _semanticEouTimer?.cancel();
      _partialSeq += 1;
      _semanticCommitPending = false;
      if (mounted) {
        setState(() {
          _partial = '';
        });
      }
    } else if (kind == 'partial') {
      final text = event['text']?.toString().trim() ?? '';
      if (mounted) setState(() => _partial = text);
      _semanticEouTimer?.cancel();
      _semanticCommitPending = false;
      final seq = ++_partialSeq;
      if (text.isNotEmpty && _connected && _listening) {
        _semanticEouTimer = Timer(const Duration(milliseconds: 320), () {
          if (_disposed || seq != _partialSeq || !_listening) return;
          _voiceWs?.sink.add(
            jsonEncode({'type': 'voice_partial', 'seq': seq, 'text': text}),
          );
        });
      }
    } else if (kind == 'final') {
      final text = event['text']?.toString().trim() ?? '';
      _semanticEouTimer?.cancel();
      _semanticCommitPending = false;
      _asrFailureCount = 0;
      if (mounted) {
        setState(() {
          _listening = false;
          _partial = '';
        });
      }
      if (text.isNotEmpty) {
        _sendUtterance(text);
      } else {
        _maybeResumeListening();
      }
    } else if (kind == 'listen_end') {
      _semanticEouTimer?.cancel();
      _semanticCommitPending = false;
      if (mounted) setState(() => _listening = false);
      _maybeResumeListening(
        realtimeVoiceRestartDelay(eventKind: 'listen_end')!,
      );
    } else if (kind == 'asr_error') {
      if (mounted) setState(() => _listening = false);
      final code = (event['code'] as num?)?.toInt();
      final terminal = event['terminal'] == true || code == 9;
      final delay = realtimeVoiceRestartDelay(
        eventKind: 'asr_error',
        errorCode: code,
        failureCount: _asrFailureCount,
      );
      if (terminal || delay == null) {
        _listenRestart?.cancel();
        _showError(event['message']?.toString() ?? '系统语音服务缺少麦克风权限');
      } else {
        _asrFailureCount += 1;
        _scheduleListeningRestart(delay);
      }
    } else if (kind == 'permission' && event['granted'] != true) {
      _listenRestart?.cancel();
      _showError('没有麦克风权限，无法开始即时语音');
    } else if (kind == 'tts_start') {
      if (mounted) setState(() => _speaking = true);
    } else if (kind == 'tts_done') {
    } else if (kind == 'tts_idle' || kind == 'tts_stopped') {
      if (_nativeFallbackActive && kind == 'tts_idle') {
        _nativeFallbackActive = false;
        _completeVoiceAudioItem();
      } else if (kind == 'tts_stopped') {
        _nativeFallbackActive = false;
        if (mounted) setState(() => _speaking = false);
      }
    } else if (kind == 'error') {
      _showError(event['message']?.toString() ?? '系统语音服务不可用');
    }
  }

  void _sendUtterance(String text) {
    final lastAnswer = _history
        .where((item) => item.assistant.trim().isNotEmpty)
        .map((item) => item.assistant)
        .lastOrNull;
    final fast = realtimeVoiceFastReply(text, lastAnswer: lastAnswer);
    if (fast != null) {
      _listenRestart?.cancel();
      if (fast.cancelSlow) {
        _cancelVoiceAnswer(keepPartial: false);
      } else if (fast.stopPlayback) {
        _stopPlaybackForBargeIn();
      }
      _history.add(_VoiceExchange(user: text, assistant: fast.text));
      if (_history.length > 6) _history.removeAt(0);
      if (_activeTurnId == null && mounted) {
        setState(() {
          _userText = text;
          _answer = fast.text;
          _thinking = false;
          _activeToolLabel = null;
        });
      }
      _enqueueSpeech(fast.text);
      _maybeResumeListening(const Duration(milliseconds: 80));
      return;
    }
    if (!_connected || _voiceWs == null) {
      _pendingUtterance = text;
      if (mounted) setState(() => _userText = text);
      return;
    }
    _cancelVoiceAnswer(keepPartial: false);
    _listenRestart?.cancel();
    _listening = false;
    if (!widget.previewMode) {
      unawaited(_native.invokeMethod('cancelListening'));
      unawaited(_native.invokeMethod('playAck'));
    }
    final turnId = '${DateTime.now().microsecondsSinceEpoch}-${++_turnCounter}';
    _activeTurnId = turnId;
    _mutedTurnId = null;
    setState(() {
      _userText = text;
      _answer = '';
      _sentenceBuffer = '';
      _thinking = true;
      _activeToolLabel = null;
    });
    _voiceWs!.sink.add(
      jsonEncode({'type': 'voice_query', 'turn_id': turnId, 'text': text}),
    );

    _maybeResumeListening(const Duration(milliseconds: 80));
  }

  void _cancelVoiceAnswer({required bool keepPartial}) {
    final turnId = _activeTurnId;
    if (turnId != null) {
      _voiceWs?.sink.add(
        jsonEncode({'type': 'voice_cancel', 'turn_id': turnId}),
      );
      if (keepPartial && (_userText.isNotEmpty || _answer.isNotEmpty)) {
        _history.add(
          _VoiceExchange(
            user: _userText,
            assistant: _answer,
            interrupted: true,
          ),
        );
      }
    }
    _activeTurnId = null;
    _mutedTurnId = null;
    _sentenceBuffer = '';
    _thinking = false;
    _activeToolLabel = null;
    _stopAllSpeech();
  }

  void _stopPlaybackForBargeIn() {
    if (_activeTurnId != null) _mutedTurnId = _activeTurnId;
    _stopAllSpeech();
  }

  void _enqueueSpeech(String text) {
    final clean = text.trim();
    if (widget.previewMode || clean.isEmpty) return;
    _ttsOutstanding += 1;
    final generation = _speechGeneration;
    _voiceAudioQueue.add(
      _PendingVoiceAudio(
        text: clean,
        generation: generation,

        audio: fetchRealtimeVoiceAudio(
          host: widget.host,
          port: widget.port,
          token: _voiceToken,
          text: clean,
        ).then<Uint8List?>((bytes) => bytes).catchError((_) => null),
      ),
    );
    unawaited(_pumpVoiceAudio());
  }

  Future<void> _pumpVoiceAudio() async {
    if (_disposed || _voiceAudioBusy || _voiceAudioQueue.isEmpty) return;
    final item = _voiceAudioQueue.removeFirst();
    if (item.generation != _speechGeneration) {
      unawaited(_pumpVoiceAudio());
      return;
    }
    _voiceAudioBusy = true;
    _activeSpeechGeneration = item.generation;
    try {
      final bytes = await item.audio;
      if (bytes == null) throw StateError('neural TTS unavailable');
      if (_disposed || item.generation != _speechGeneration) return;
      final player = await _ensureVoicePlayer();
      if (_disposed || item.generation != _speechGeneration) return;

      await _native.invokeMethod('ensureOutputRoute');
      if (_disposed || item.generation != _speechGeneration) return;
      await player.play(
        BytesSource(bytes, mimeType: 'audio/mpeg'),
        mode: PlayerMode.mediaPlayer,
      );
      if (_disposed || item.generation != _speechGeneration) {
        await player.stop();
        return;
      }
      if (mounted) setState(() => _speaking = true);
    } catch (_) {
      if (_disposed || item.generation != _speechGeneration) return;
      _nativeFallbackActive = true;
      try {
        final accepted = await _native.invokeMethod<bool>('speak', {
          'text': item.text,
        });
        if (accepted != true) {
          _nativeFallbackActive = false;
          _completeVoiceAudioItem();
        }
      } catch (_) {
        _nativeFallbackActive = false;
        _completeVoiceAudioItem();
      }
    } finally {
      if (item.generation != _speechGeneration &&
          _activeSpeechGeneration == item.generation) {
        _voiceAudioBusy = false;
        _activeSpeechGeneration = null;
        unawaited(_pumpVoiceAudio());
      }
    }
  }

  void _completeVoiceAudioItem() {
    if (!_voiceAudioBusy) return;
    _voiceAudioBusy = false;
    _activeSpeechGeneration = null;
    if (_ttsOutstanding > 0) _ttsOutstanding -= 1;
    if (mounted && !_disposed) setState(() => _speaking = false);
    if (_voiceAudioQueue.isNotEmpty) {
      unawaited(_pumpVoiceAudio());
    } else {
      _maybeResumeListening(const Duration(milliseconds: 120));
    }
  }

  void _stopAllSpeech() {
    _speechGeneration += 1;
    _voiceAudioQueue.clear();
    _voiceAudioBusy = false;
    _activeSpeechGeneration = null;
    _nativeFallbackActive = false;
    _ttsOutstanding = 0;
    _speaking = false;
    final player = _voicePlayer;
    if (player != null) unawaited(player.stop());
    if (!widget.previewMode) {
      unawaited(_native.invokeMethod('stopSpeaking'));
    }
    if (mounted && !_disposed) setState(() => _speaking = false);
  }

  void _speakCompleteSentences() {
    final split = splitSpeakableVoiceText(_sentenceBuffer);
    _sentenceBuffer = split.remainder;
    for (final sentence in split.sentences) {
      _enqueueSpeech(sentence);
    }
  }

  void _flushSpeech() {
    final split = splitSpeakableVoiceText(_sentenceBuffer, flush: true);
    _sentenceBuffer = split.remainder;
    for (final sentence in split.sentences) {
      _enqueueSpeech(sentence);
    }
  }

  Future<void> _startListening() async {
    if (!_running || _disposed || widget.previewMode) return;
    if (_listening) return;
    if (!canResumeRealtimeVoiceListening(
      running: _running,
      thinking: _thinking,
      speaking: _speaking,
      hasActiveTurn: _activeTurnId != null,
      ttsOutstanding: _ttsOutstanding,
      headsetDuplex: _headsetDuplex,
    )) {
      return;
    }
    try {
      await _native.invokeMethod('startListening');
    } catch (e) {
      _showError('启动聆听失败：$e');
    }
  }

  void _scheduleListeningRestart([
    Duration delay = const Duration(milliseconds: 180),
  ]) {
    _listenRestart?.cancel();
    if (!_running || _disposed || widget.previewMode) return;
    _listenRestart = Timer(delay, () {
      _listenRestart = null;
      unawaited(_startListening());
    });
  }

  void _maybeResumeListening([
    Duration delay = const Duration(milliseconds: 120),
  ]) {
    if (!canResumeRealtimeVoiceListening(
      running: _running,
      thinking: _thinking,
      speaking: _speaking,
      hasActiveTurn: _activeTurnId != null,
      ttsOutstanding: _ttsOutstanding,
      headsetDuplex: _headsetDuplex,
    )) {
      return;
    }
    _scheduleListeningRestart(delay);
  }

  Future<void> _interruptAndListen() async {
    if (!_running || (!_thinking && !_speaking)) return;
    _listenRestart?.cancel();
    if (_headsetDuplex) {
      _stopPlaybackForBargeIn();
    } else {
      _cancelVoiceAnswer(keepPartial: true);
    }
    if (mounted) {
      setState(() {
        _partial = '';
        _listening = false;
      });
    }
    _maybeResumeListening(const Duration(milliseconds: 180));
  }

  void _toggleRunning() {
    setState(() => _running = !_running);
    if (_running) {
      unawaited(_native.invokeMethod('startSession'));
      _scheduleListeningRestart();
    } else {
      _listenRestart?.cancel();
      _listening = false;
      unawaited(_native.invokeMethod('cancelListening'));
      _cancelVoiceAnswer(keepPartial: true);
      unawaited(_native.invokeMethod('stopSession'));
    }
  }

  void _voiceDisconnected(String detail) {
    if (_disposed) return;
    setState(() => _connected = false);
    _showError('即时语音连接断开：$detail');
  }

  void _showError(String text) {
    if (!mounted || _disposed) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String get _statusText {
    if (!_connected) return '正在连接快慢脑…';
    if (!_running) return '已暂停聆听';
    if (_thinking && _activeToolLabel != null) return '正在$_activeToolLabel…';
    if (_thinking && _headsetDuplex) return '慢脑后台处理中 · 仍可继续说';
    if (_thinking) return '慢脑处理中 · 点圆球可重新说';
    if (_speaking && _headsetDuplex) return '正在播报 · 直接开口可打断';
    if (_speaking) return '正在播报 · 点圆球可立即打断';
    if (_listening) return '正在聆听 · 说完即答';
    return '准备聆听…';
  }

  Color get _orbColor {
    if (!_running) return Colors.blueGrey;
    if (_thinking) return Colors.amber;
    if (_speaking) return Colors.deepPurpleAccent;
    return Colors.tealAccent;
  }

  String _voiceToolLabel(String name) {
    switch (name) {
      case 'web_search':
      case 'web_read':
        return '搜索网页';
      case 'local_status':
        return '核对本机状态';
      case 'project_history_search':
      case 'project_read':
        return '检索项目库';
      case 'deepmemo_lookup':
        return '查询记忆服务';
      case 'session_search':
      case 'session_read':
        return '查询历史会话';
      default:
        return '调用只读工具';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _listenRestart?.cancel();
    _connectTimeout?.cancel();
    _semanticEouTimer?.cancel();
    _cancelVoiceAnswer(keepPartial: false);
    if (!widget.previewMode) {
      unawaited(_native.invokeMethod('cancelListening'));
      unawaited(_native.invokeMethod('stopSpeaking'));
      unawaited(_native.invokeMethod('stopSession'));
    }
    _native.setMethodCallHandler(null);
    _voicePlayerCompleteSub?.cancel();
    final player = _voicePlayer;
    if (player != null) unawaited(player.dispose());
    _voiceSub?.cancel();
    _voiceWs?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latestHistory = _history.reversed.take(2).toList().reversed;
    return Scaffold(
      appBar: AppBar(
        title: const Text('即时语音问答'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text(
                '快脑 · 慢脑',
                style: TextStyle(
                  color: Colors.tealAccent.shade100,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1720), Color(0xFF111018), Color(0xFF090B0F)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '可选语音通道 · 需要兼容服务端',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: (_thinking || _speaking)
                    ? () => unawaited(_interruptAndListen())
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 126 + (_level * 20),
                  height: 126 + (_level * 20),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _orbColor.withValues(alpha: 0.13),
                    border: Border.all(color: _orbColor, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: _orbColor.withValues(alpha: 0.28),
                        blurRadius: 36 + (_level * 18),
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Icon(
                    _speaking ? Icons.graphic_eq : Icons.mic_rounded,
                    size: 48,
                    color: _orbColor,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _statusText,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    _partial.isEmpty ? '直接说话，不用按住麦克风' : _partial,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _partial.isEmpty ? Colors.white38 : Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (_userText.isNotEmpty || _answer.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.065),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _userText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 13,
                        ),
                      ),
                      if (_answer.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        Text(
                          _answer,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, height: 1.45),
                        ),
                      ],
                    ],
                  ),
                ),
              for (final item in latestHistory)
                if (item.interrupted)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      '上一轮已被抢话打断',
                      style: TextStyle(
                        color: Colors.orange.shade200,
                        fontSize: 11,
                      ),
                    ),
                  ),
              const SizedBox(height: 22),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _toggleRunning,
                        icon: Icon(
                          _running
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(_running ? '暂停聆听' : '继续聆听'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          backgroundColor: _running
                              ? Colors.teal.shade700
                              : Colors.blueGrey,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filledTonal(
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: '结束即时语音',
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
