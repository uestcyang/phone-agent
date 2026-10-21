import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_credentials.dart';
import 'backend_identity.dart';
import 'message_outbox.dart';
import 'network_event_outbox.dart';
import 'transport_routes.dart';
import 'local_store.dart';
import 'models.dart';
import 'push_store.dart';

class WsClientRegistry {
  static final Map<String, WsClient> _clients = {};

  static const MethodChannel _heartbeatChannel = MethodChannel(
    'org.phoneagent.app/heartbeat',
  );

  static const MethodChannel _replyChannel = MethodChannel(
    'org.phoneagent.app/reply',
  );
  static bool _handlerInstalled = false;
  static bool? _lastSyncedForeground;

  static void Function()? onTick;

  static String? activeChatAgentId;

  static void claimActiveChat(String agentId) {
    activeChatAgentId = agentId;
  }

  static void releaseActiveChat(String agentId) {
    if (activeChatAgentId == agentId) activeChatAgentId = null;
  }

  static WsClient getOrCreate(
    String agentId,
    String host,
    int port,
    String token, {
    bool alwaysIncognito = false,
  }) {
    _ensureNativeHandler();
    final existing = _clients[agentId];
    if (existing != null) {
      if (alwaysIncognito) existing.enforceAlwaysIncognito();

      final changed =
          (token.isNotEmpty && existing.token != token) ||
          existing.host != host ||
          existing.port != port;
      if (changed) {
        if (token.isNotEmpty) existing.token = token;
        existing.host = host;
        existing.port = port;
        existing.reconnectNow();
      }
      return existing;
    }
    final c = WsClient(
      agentId: agentId,
      host: host,
      port: port,
      token: token,
      alwaysIncognito: alwaysIncognito,
    );
    _clients[agentId] = c;
    return c;
  }

  static WsClient? peek(String agentId) => _clients[agentId];

  static void _ensureNativeHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _heartbeatChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'tick':
          for (final c in _clients.values.toList(growable: false)) {
            c._heartbeatTick();
          }
          onTick?.call();
          break;
        case 'networkChanged':
          for (final c in _clients.values.toList(growable: false)) {
            c._onNetworkChanged();
          }
          break;
      }
      return null;
    });
    _replyChannel.setMethodCallHandler((call) async {
      if (call.method != 'send') return null;
      final args = (call.arguments as Map).cast<String, dynamic>();
      final agentId = args['agentId'] as String?;
      final text = args['text'] as String?;
      if (agentId == null || text == null || text.isEmpty) return null;

      final client = _clients[agentId];
      if (client == null) return null;
      final now = DateTime.now();
      final ts =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';
      if (client.sid != null && !client.incognito.value) {
        unawaited(LocalStore.appendUser(client.sid!, text, ts));
      }
      await client.send(text);
      return null;
    });
  }

  static void syncForegroundToNative(bool value) {
    if (_lastSyncedForeground == value) return;
    _lastSyncedForeground = value;
    unawaited(
      _heartbeatChannel
          .invokeMethod('setForeground', {'value': value})
          .catchError((_) {}),
    );
  }
}

class ConnDiagEntry {
  final DateTime ts;
  final String kind;
  final String detail;
  final int? closeCode;
  final String? closeReason;
  final bool foreground;

  ConnDiagEntry({
    required this.ts,
    required this.kind,
    required this.detail,
    required this.closeCode,
    required this.closeReason,
    required this.foreground,
  });

  String get tsLabel =>
      '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:${ts.second.toString().padLeft(2, '0')}';
}

class WsClient with WidgetsBindingObserver {
  NetworkEventOutbox? _networkEvents;
  bool _sendingNetworkEvents = false;
  bool _supportsNetworkEvents = false;
  DateTime? _networkOutageAt;
  bool _networkFallbackObserved = false;

  String? _networkScope;
  NetworkEventOutbox get _networkOutbox {
    final scope =
        'owner-network:${BackendIdentity.credentialKey(host, port)}:$agentId';
    if (_networkScope != scope) {
      _networkScope = scope;
      _networkEvents = NetworkEventOutbox(scope);
    }
    return _networkEvents!;
  }

  void _recordNetworkEvent(String kind, String from, String to) {
    if (!TransportRoutes.instance.supports(host, port) ||
        alwaysIncognito ||
        agentId == 'agent_f') {
      return;
    }
    unawaited(
      _networkOutbox
          .add(
            kind,
            from,
            to,
            durationMs: _networkOutageAt == null
                ? 0
                : DateTime.now().difference(_networkOutageAt!).inMilliseconds,
          )
          .catchError(
            (Object e) => _recordDiag(
              kind: 'network_event_persist_error',
              detail: e.runtimeType.toString(),
              closeCode: null,
              closeReason: null,
            ),
          ),
    );
  }

  Future<void> _flushNetworkEvents() async {
    if (_sendingNetworkEvents ||
        !_sessionReady ||
        !_supportsNetworkEvents ||
        _channel == null ||
        alwaysIncognito ||
        !TransportRoutes.instance.supports(host, port) ||
        agentId == 'agent_f') {
      return;
    }
    _sendingNetworkEvents = true;
    try {
      final channel = _channel;
      for (final event in (await _networkOutbox.pending()).take(4)) {
        if (channel != _channel || !_sessionReady) break;
        channel!.sink.add(
          jsonEncode({'type': 'network_event', 'event': event}),
        );
      }
    } catch (e) {
      _recordDiag(
        kind: 'network_event_retry',
        detail: e.runtimeType.toString(),
        closeCode: null,
        closeReason: null,
      );
    } finally {
      _sendingNetworkEvents = false;
    }
  }

  final String agentId;
  String host;
  int port;
  String token;
  bool alwaysIncognito;
  void Function(Map<String, dynamic> json)? onMessage;

  String? sid;
  int lastSeq = 0;
  Future<void> _inboundSerial = Future<void>.value();
  bool _sessionReady = false;
  bool _supportsMessageAck = false;
  MessageOutbox? _outbox;
  String? _outboxScope;
  final Set<String> _sentPendingIds = {};

  Map<String, dynamic>? _lastSessionFrame;
  DateTime? _lastSessionFrameAt;

  bool? get cachedBusy {
    final frame = _lastSessionFrame;
    final at = _lastSessionFrameAt;
    if (frame == null || at == null) return null;
    if (DateTime.now().difference(at) > const Duration(seconds: 60)) {
      return null;
    }
    return frame['busy'] == true;
  }

  late final ValueNotifier<bool> incognito;
  String? _savedSid;
  int _savedLastSeq = 0;
  bool _pendingIncognitoEnd = false;
  Timer? _incognitoEndRetry;

  void Function(Map<String, dynamic> sessionJson)? onSession;
  void Function(int count)? onReplayStart;
  void Function()? onReplayEnd;

  void Function(AgentPush push)? onPush;

  void Function(String text)? onTurnDone;

  final StringBuffer _turnText = StringBuffer();

  bool _replaying = false;

  final ValueNotifier<ConnStatus> status = ValueNotifier(
    ConnStatus.disconnected,
  );

  final ValueNotifier<ConnStatus> displayStatus = ValueNotifier(
    ConnStatus.disconnected,
  );
  Timer? _displayDebounce;
  final ValueNotifier<List<ConnDiagEntry>> diagLog = ValueNotifier(const []);

  static const int _diagCapacity = 50;
  final List<ConnDiagEntry> _diag = [];

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _backoffSeconds = 1;
  static const int _maxBackoffSeconds = 60;
  final Random _jitterRng = Random();
  bool _disposed = false;
  bool _wantConnected = false;

  bool _isForeground =
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get isForeground => _isForeground;

  int _pingSeq = 0;
  int _lastAckedSeq = -1;
  int _consecutiveMisses = 0;

  DateTime? _pendingReconnectAt;
  int? _backoffBaseForPendingReconnect;

  late final Future<void> _sidRestored;

  WsClient({
    required this.agentId,
    required this.host,
    required this.port,
    required this.token,
    this.alwaysIncognito = false,
  }) {
    incognito = ValueNotifier(alwaysIncognito);
    WidgetsBinding.instance.addObserver(this);
    status.addListener(_onStatusChanged);
    WsClientRegistry.syncForegroundToNative(_isForeground);
    _sidRestored = _restoreSid();
  }

  Future<void> _restoreSid() async {
    try {
      if (agentId == 'agent_f' && !alwaysIncognito) {}
      if (alwaysIncognito) {
        final (_, incognitoSid, incognitoLastSeq, _, _) =
            await LocalStore.loadIncognitoState(agentId);
        incognito.value = true;
        _savedSid = null;
        _savedLastSeq = 0;
        sid = incognitoSid;
        lastSeq = incognitoLastSeq;
        return;
      }
      final (savedSid, savedLastSeq) = await LocalStore.loadCurrentSession(
        agentId,
      );
      final (
        incognitoActive,
        incognitoSid,
        incognitoLastSeq,
        incognitoSavedSid,
        incognitoSavedLastSeq,
      ) = await LocalStore.loadIncognitoState(
        agentId,
      );
      if (incognitoActive) {
        incognito.value = true;
        _savedSid = incognitoSavedSid ?? savedSid;
        _savedLastSeq = incognitoSavedLastSeq > 0
            ? incognitoSavedLastSeq
            : savedLastSeq;
        sid = incognitoSid;
        lastSeq = incognitoLastSeq;
        return;
      }
      if (savedSid != null && sid == null) {
        sid = savedSid;
      }
      if (savedLastSeq > lastSeq) {
        lastSeq = savedLastSeq;
      }

      if (sid != null) {
        final actualLastSeq = await LocalStore.lastFrameSeq(sid!) ?? 0;
        if (actualLastSeq < lastSeq) {
          lastSeq = actualLastSeq;
        }
      }
    } catch (e) {
      _recordDiag(
        kind: 'sid_restore_error',
        detail: '本地会话指针恢复失败: $e',
        closeCode: null,
        closeReason: null,
      );
    }
  }

  void _onStatusChanged() {
    final s = status.value;
    _displayDebounce?.cancel();
    if (s == ConnStatus.connected) {
      displayStatus.value = s;
      return;
    }
    _displayDebounce = Timer(const Duration(seconds: 3), () {
      displayStatus.value = status.value;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final s = sid;
      if (s != null) {
        unawaited(LocalStore.pendingFlush(s).catchError((_) {}));
      }
    }
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _isForeground) return;
    _isForeground = resumed;
    WsClientRegistry.syncForegroundToNative(resumed);

    if (status.value == ConnStatus.connected) {
      _startHeartbeat();
    }
  }

  void connect() {
    _wantConnected = true;

    if (_channel != null || status.value == ConnStatus.connecting) return;
    _connectNow();
  }

  bool _hydratingToken = false;

  Future<void> _hydrateTokenThenConnect() async {
    if (_hydratingToken) return;
    _hydratingToken = true;
    try {
      String? disk;
      try {
        disk = await DeviceCredentials.load(host, port);
      } catch (_) {
        disk = null;
      }
      if (_disposed || !_wantConnected) return;

      if (_channel != null || status.value == ConnStatus.connected) return;
      if (token.isEmpty && disk != null && disk.isNotEmpty) token = disk;
      if (token.isEmpty) {
        _recordDiag(
          kind: 'token_missing',
          detail: '盘上无 per-device token，跳过这次握手，等配对完成后由 getOrCreate 唤醒',
          closeCode: null,
          closeReason: null,
        );
        status.value = ConnStatus.disconnected;
        return;
      }
    } finally {
      _hydratingToken = false;
    }
    _connectNow();
  }

  void _connectNow() {
    if (_disposed || !_wantConnected) return;
    _reconnectTimer?.cancel();
    status.value = ConnStatus.connecting;
    _sessionReady = false;
    _supportsMessageAck = false;
    _supportsNetworkEvents = false;
    _sentPendingIds.clear();

    if (token.isEmpty) {
      unawaited(_hydrateTokenThenConnect());
      return;
    }
    try {
      final uri = TransportRoutes.instance.websocket(host, port);
      _recordDiag(
        kind: 'route_attempt',
        detail:
            TransportRoutes.instance.attemptedPath(host, port, uri)?.name ??
            'custom',
        closeCode: null,
        closeReason: null,
      );
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 8),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        (data) {
          _inboundSerial = _inboundSerial.then((_) async {
            if (_channel == channel && !_disposed) await _processData(data);
          });
        },
        onError: (Object error, StackTrace _) {
          _recordDiag(
            kind: 'error',
            detail: error.toString(),
            closeCode: channel.closeCode,
            closeReason: channel.closeReason,
          );
          _handleDisconnect(channel: channel, attempted: uri, error: error);
        },
        onDone: () {
          _recordDiag(
            kind: 'done',
            detail: 'stream closed',
            closeCode: channel.closeCode,
            closeReason: channel.closeReason,
          );
          _handleDisconnect(channel: channel, attempted: uri);
        },
        cancelOnError: true,
      );
      channel.ready
          .then((_) async {
            await _sidRestored;
            if (!_disposed && _wantConnected && _channel == channel) {
              _backoffSeconds = 1;
              TransportRoutes.instance.connected(host, port, uri);
              final connectedRoute = TransportRoutes.instance.attemptedPath(
                host,
                port,
                uri,
              );
              if (connectedRoute == TransportPath.vps &&
                  _networkFallbackObserved) {
                _recordNetworkEvent('public_recovered', 'unknown', 'vps');
                _networkFallbackObserved = false;
                _networkOutageAt = null;
              }
              status.value = ConnStatus.connected;
              _sendHello();
              _startHeartbeat();
            }
          })
          .catchError((Object error) {
            _recordDiag(
              kind: 'connect_fail',
              detail: error.toString(),
              closeCode: channel.closeCode,
              closeReason: channel.closeReason,
            );
            _handleDisconnect(channel: channel, attempted: uri, error: error);
          });
    } catch (e) {
      _recordDiag(
        kind: 'connect_fail',
        detail: e.toString(),
        closeCode: null,
        closeReason: null,
      );
      _handleDisconnect();
    }
  }

  void _recordDiag({
    required String kind,
    required String detail,
    required int? closeCode,
    required String? closeReason,
  }) {
    final entry = ConnDiagEntry(
      ts: DateTime.now(),
      kind: kind,
      detail: detail,
      closeCode: closeCode,
      closeReason: closeReason,
      foreground: _isForeground,
    );
    _diag.insert(0, entry);
    if (_diag.length > _diagCapacity) {
      _diag.removeRange(_diagCapacity, _diag.length);
    }
    diagLog.value = List.unmodifiable(_diag);
  }

  void _sendHello() {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(
        jsonEncode({
          'type': 'hello',
          'sid': sid,
          'last_seq': lastSeq,
          if (incognito.value) 'incognito': true,
        }),
      );
    } catch (e) {
      _recordDiag(
        kind: 'send_error',
        detail: 'hello 发送失败: $e',
        closeCode: channel.closeCode,
        closeReason: channel.closeReason,
      );
    }
  }

  Future<void> _processData(dynamic data) async {
    if (data is! String) return;
    try {
      final parsed = jsonDecode(data);
      if (parsed is Map<String, dynamic>) {
        switch (parsed['type']) {
          case 'network_event_ack':
            if (parsed['event_id'] is String && parsed['durable'] == true) {
              await _networkOutbox.acknowledge(
                parsed['event_id'] as String,
                durable: true,
              );
            }
            return;
          case 'pong':
            _onPong(parsed['seq'] as int?);
            return;
          case 'session':
            final nextSid = parsed['sid'] as String?;
            if (nextSid != sid) lastSeq = 0;
            sid = nextSid;
            _sessionReady = true;
            _supportsMessageAck =
                parsed['message_delivery'] == 'message-ack-v1';
            _supportsNetworkEvents =
                parsed['network_events'] == 'durable-network-v1';
            _lastSessionFrame = parsed;
            _lastSessionFrameAt = DateTime.now();

            if (sid != null && incognito.value) {
              unawaited(
                LocalStore.saveIncognitoState(
                  agentId,
                  incognitoSid: sid,
                  lastSeq: lastSeq,
                  savedSid: _savedSid,
                  savedLastSeq: _savedLastSeq,
                ),
              );
              if (_pendingIncognitoEnd) _sendIncognitoEnd();
            } else if (sid != null) {
              unawaited(LocalStore.saveCurrentSession(agentId, sid!, lastSeq));
            }
            onSession?.call(parsed);
            if (parsed['resumed'] != true) _sentPendingIds.clear();
            await _flushOutbox();
            await _flushNetworkEvents();
            return;
          case 'message_ack':
            final ackSid = parsed['sid'] as String?;
            final id = parsed['client_message_id'] as String?;
            if (ackSid == sid &&
                id != null &&
                parsed['durable'] == !incognito.value) {
              await _getOutbox().acknowledge(ackSid!, id);
              _sentPendingIds.remove(id);
            }
            return;
          case 'message_rejected':
            final id = parsed['client_message_id'] as String?;
            if (id != null && sid != null) {
              await _getOutbox().reject(sid!, id);
              _sentPendingIds.remove(id);
            }
            onMessage?.call({'type': 'error', 'text': '消息未接收，已保留本地内容，请确认后重试。'});
            return;
          case 'incognito_ended':
            if (_pendingIncognitoEnd) _finishIncognitoExit();
            return;
          case 'replay_start':
            _replaying = true;
            _turnText.clear();
            onReplayStart?.call((parsed['count'] as num?)?.toInt() ?? 0);
            return;
          case 'replay_end':
            _replaying = false;
            _turnText.clear();
            onReplayEnd?.call();
            return;
          case 'agent_push':
            final push = AgentPush.fromJson(parsed);
            latestPush.value = push;

            savePush(push);
            notifyWidgetUpdate(push);
            onPush?.call(push);
            return;
          default:
            final seqNum = (parsed['seq'] as num?)?.toInt();
            if (seqNum != null && seqNum <= lastSeq) return;
            if (seqNum != null && sid != null) {
              if (incognito.value) {
                if (!_disposed && seqNum > lastSeq) {
                  lastSeq = seqNum;
                  unawaited(
                    LocalStore.saveIncognitoState(
                      agentId,
                      incognitoSid: sid,
                      lastSeq: lastSeq,
                      savedSid: _savedSid,
                      savedLastSeq: _savedLastSeq,
                    ),
                  );
                }
              } else {
                final frameSid = sid!;
                try {
                  await LocalStore.appendFrame(frameSid, parsed);
                  if (!_disposed && seqNum > lastSeq) {
                    lastSeq = seqNum;
                    unawaited(
                      LocalStore.saveCurrentSession(agentId, frameSid, lastSeq),
                    );
                  }
                } catch (e) {
                  _recordDiag(
                    kind: 'append_frame_error',
                    detail: '帧落盘失败 seq=$seqNum: $e',
                    closeCode: _channel?.closeCode,
                    closeReason: _channel?.closeReason,
                  );

                  _handleDisconnect();
                  return;
                }
              }
            }

            if (!_replaying) {
              final t = parsed['type'];
              if (t == 'assistant') {
                final txt = (parsed['text'] as String?)?.trim() ?? '';
                if (txt.isNotEmpty) {
                  if (_turnText.isNotEmpty) _turnText.write('\n');
                  _turnText.write(txt);
                }
              } else if (t == 'done') {
                final body = _turnText.toString().trim();
                _turnText.clear();
                if (body.isNotEmpty) onTurnDone?.call(body);
              } else if (t == 'error' || t == 'interrupted') {
                _turnText.clear();
                final txt = (parsed['text'] as String?)?.trim() ?? '';
                if (txt.isNotEmpty) {
                  onTurnDone?.call(t == 'error' ? '⚠ 出错：$txt' : '⏹ 已打断：$txt');
                }
              }
            }
            onMessage?.call(parsed);
        }
      }
    } catch (e) {
      _recordDiag(
        kind: 'parse_error',
        detail: incognito.value ? '无痕帧处理失败，正文未记录' : '帧处理失败: $e',
        closeCode: _channel?.closeCode,
        closeReason: _channel?.closeReason,
      );
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _consecutiveMisses = 0;
    if (_isForeground) {
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _heartbeatTick(),
      );
    }
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _heartbeatTick() {
    if (_disposed) return;
    _checkPendingReconnect();

    if (status.value != ConnStatus.connected) return;
    final channel = _channel;
    if (channel == null) return;
    if (_pingSeq > 0 && _lastAckedSeq < _pingSeq) {
      _consecutiveMisses++;
      if (_consecutiveMisses >= 2) {
        _recordDiag(
          kind: 'heartbeat_timeout',
          detail: '连续$_consecutiveMisses次tick(最新seq=$_pingSeq)未收到pong',
          closeCode: channel.closeCode,
          closeReason: channel.closeReason,
        );
        reconnectNow();
        return;
      }
    } else {
      _consecutiveMisses = 0;
    }
    _sendPing();
    unawaited(_flushNetworkEvents());
  }

  void _sendPing() {
    final channel = _channel;
    if (channel == null) return;
    _pingSeq++;
    final seq = _pingSeq;
    try {
      channel.sink.add(jsonEncode({'type': 'ping', 'seq': seq}));
    } catch (e) {
      _recordDiag(
        kind: 'send_error',
        detail: 'ping 发送失败(seq=$seq): $e',
        closeCode: channel.closeCode,
        closeReason: channel.closeReason,
      );
    }
  }

  void _checkPendingReconnect() {
    final due = _pendingReconnectAt;
    if (due == null) return;
    if (DateTime.now().isBefore(due)) return;
    _reconnectTimer?.cancel();
    _pendingReconnectAt = null;
    _fireScheduledReconnect();
  }

  void _onPong(int? seq) {
    if (seq != null && seq > _lastAckedSeq) {
      _lastAckedSeq = seq;
    }
    _consecutiveMisses = 0;
  }

  void _handleDisconnect({
    WebSocketChannel? channel,
    Uri? attempted,
    Object? error,
  }) {
    if (channel != null && _channel != channel) return;
    if (attempted != null) {
      final oldRoute = TransportRoutes.instance.path(host, port);
      TransportRoutes.instance.failed(
        host,
        port,
        attempted,
        authentication: RegExp(
          r'\b(401|403|429)\b',
        ).hasMatch(error?.toString() ?? ''),
      );
      final newRoute = TransportRoutes.instance.path(host, port);
      if (oldRoute != newRoute) {
        _networkOutageAt ??= DateTime.now();
        _networkFallbackObserved = true;
        _recordNetworkEvent('route_fallback', oldRoute.name, newRoute.name);
      }
    }
    _stopHeartbeat();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    if (_disposed || !_wantConnected) return;
    status.value = ConnStatus.disconnected;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final base = _backoffSeconds;
    _backoffBaseForPendingReconnect = base;
    final jitterMs = (_jitterRng.nextDouble() * 0.4 - 0.2) * base * 1000;
    final delay = Duration(
      milliseconds: (base * 1000 + jitterMs)
          .clamp(200, _maxBackoffSeconds * 1000)
          .round(),
    );
    _pendingReconnectAt = DateTime.now().add(delay);
    _recordDiag(
      kind: 'reconnect_scheduled',
      detail: '${delay.inMilliseconds}ms 后重连(base=${base}s)',
      closeCode: null,
      closeReason: null,
    );
    _reconnectTimer = Timer(delay, _fireScheduledReconnect);
  }

  void _fireScheduledReconnect() {
    _pendingReconnectAt = null;
    if (_disposed || !_wantConnected) return;
    if (_channel != null || status.value == ConnStatus.connecting) return;
    final base = _backoffBaseForPendingReconnect ?? _backoffSeconds;
    _backoffBaseForPendingReconnect = null;
    _backoffSeconds = (base * 2).clamp(1, _maxBackoffSeconds);
    _connectNow();
  }

  void _onNetworkChanged() {
    if (_disposed || !_wantConnected) return;
    TransportRoutes.instance.networkChanged(host, port);
    _recordDiag(
      kind: 'network_changed',
      detail: '默认网络变化，立即重建连接(退避已复位)',
      closeCode: null,
      closeReason: null,
    );
    reconnectNow();
  }

  void reconnectNow() {
    _backoffSeconds = 1;
    _reconnectTimer?.cancel();
    _pendingReconnectAt = null;
    _backoffBaseForPendingReconnect = null;
    _stopHeartbeat();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _connectNow();
  }

  void enterIncognito() {
    if (incognito.value) return;
    _savedSid = sid;
    _savedLastSeq = lastSeq;
    _outbox?.clearMemory();
    incognito.value = true;
    sid = null;
    lastSeq = 0;
    unawaited(
      LocalStore.saveIncognitoState(
        agentId,
        incognitoSid: null,
        lastSeq: 0,
        savedSid: _savedSid,
        savedLastSeq: _savedLastSeq,
      ),
    );
    reconnectNow();
  }

  void exitIncognito() {
    if (alwaysIncognito) return;
    if (!incognito.value || _pendingIncognitoEnd) return;
    _pendingIncognitoEnd = true;
    _sendIncognitoEnd();
  }

  void _sendIncognitoEnd() {
    if (!_pendingIncognitoEnd) return;
    final channel = _channel;
    if (channel == null || status.value != ConnStatus.connected) {
      reconnectNow();
      return;
    }
    try {
      channel.sink.add(jsonEncode({'type': 'incognito_end', 'sid': sid}));
    } catch (_) {
      reconnectNow();
      return;
    }
    _incognitoEndRetry?.cancel();
    _incognitoEndRetry = Timer(const Duration(seconds: 3), () {
      if (_pendingIncognitoEnd && !_disposed) reconnectNow();
    });
  }

  void _finishIncognitoExit() {
    if (alwaysIncognito) {
      _pendingIncognitoEnd = false;
      incognito.value = true;
      return;
    }
    _incognitoEndRetry?.cancel();
    _outbox?.clearMemory();
    _pendingIncognitoEnd = false;
    incognito.value = false;
    sid = _savedSid;
    lastSeq = _savedLastSeq;
    _savedSid = null;
    _savedLastSeq = 0;
    unawaited(LocalStore.clearIncognitoState(agentId));
    reconnectNow();
  }

  void enforceAlwaysIncognito() {
    if (alwaysIncognito) return;
    alwaysIncognito = true;
    _pendingIncognitoEnd = false;
    _savedSid = null;
    _savedLastSeq = 0;
    incognito.value = true;
    sid = null;
    lastSeq = 0;
    unawaited(
      LocalStore.saveIncognitoState(
        agentId,
        incognitoSid: null,
        lastSeq: 0,
        savedSid: null,
        savedLastSeq: 0,
      ),
    );
    reconnectNow();
  }

  void updateAddress(String newHost, int newPort) {
    host = newHost;
    port = newPort;
    reconnectNow();
  }

  MessageOutbox _getOutbox() {
    final scope =
        '${BackendIdentity.credentialKey(host, port)}:$agentId:${incognito.value}';
    if (_outboxScope != scope) {
      _outbox?.clearMemory();
      _outboxScope = scope;
      _outbox = MessageOutbox(scope, memoryOnly: incognito.value);
    }
    return _outbox!;
  }

  Future<void> _flushOutbox() async {
    if (!_sessionReady || !_supportsMessageAck || sid == null) return;
    final boundSid = sid!;
    final boundChannel = _channel;
    final outbox = _getOutbox();
    for (final entry in await outbox.pending(boundSid)) {
      if (_channel != boundChannel || sid != boundSid || !_sessionReady) return;
      final id = entry['client_message_id'] as String;
      if (_sentPendingIds.add(id)) {
        try {
          boundChannel?.sink.add(jsonEncode(entry));
        } catch (_) {
          _sentPendingIds.remove(id);
          _handleDisconnect(channel: boundChannel);
          return;
        }
      }
    }
  }

  Future<void> _sendInput(
    String text,
    List<Map<String, dynamic>>? attachments, {
    bool steer = false,
  }) async {
    if (_channel == null || !_sessionReady || sid == null) {
      throw StateError('连接或会话尚未就绪，输入已保留');
    }
    if (!_supportsMessageAck ||
        text.trim() == '/reset' ||
        text.trim() == '/clear') {
      _channel!.sink.add(
        jsonEncode({
          'text': text,
          if (steer) 'type': 'steer',
          if (attachments != null && attachments.isNotEmpty)
            'attachments': attachments,
        }),
      );
      return;
    }
    await _getOutbox().enqueue(
      sid!,
      text,
      attachments: attachments,
      steer: steer,
    );
    await _flushOutbox();
  }

  Future<void> send(String text, {List<Map<String, dynamic>>? attachments}) =>
      _sendInput(text, attachments);

  Future<void> sendSteer(
    String text, {
    List<Map<String, dynamic>>? attachments,
  }) => _sendInput(text, attachments, steer: true);

  void sendStop() {
    _channel?.sink.add(jsonEncode({'type': 'stop'}));
  }

  void sendUnqueue(int qid) {
    _channel?.sink.add(jsonEncode({'type': 'unqueue', 'qid': qid}));
  }

  void sendStateSync() {
    _channel?.sink.add(jsonEncode({'type': 'state_sync'}));
  }

  void sendReset() {
    _channel?.sink.add(jsonEncode({'text': '/reset'}));
  }

  void disconnect() {
    _sessionReady = false;
    _supportsMessageAck = false;
    _wantConnected = false;
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _pendingReconnectAt = null;
    _backoffBaseForPendingReconnect = null;
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    status.value = ConnStatus.disconnected;
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    status.removeListener(_onStatusChanged);
    _displayDebounce?.cancel();
    _incognitoEndRetry?.cancel();
    disconnect();
    status.dispose();
    displayStatus.dispose();
    diagLog.dispose();
    incognito.dispose();
  }
}
