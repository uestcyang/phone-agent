import 'dart:async';
import 'constants.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'agent_registry.dart';
import 'compact_agent_menu.dart';
import 'task_summary_menu.dart';
import 'draft_dictation.dart';
import 'chat_composer.dart';
import 'background_store.dart';
import 'chat_search_page.dart';
import 'device_credentials.dart';
import 'diagnostics_page.dart';
import 'foreground_service.dart';
import 'local_store.dart';
import 'incoming_share.dart';
import 'media_download_queue.dart';
import 'message_widgets.dart';
import 'models.dart';
import 'mute_settings.dart';
import 'mute_settings_page.dart';
import 'onboarding_cards.dart';
import 'session_history_page.dart';
import 'settings_page.dart';
import 'task_rail.dart';
import 'upload_client.dart';
import 'ws_client.dart';
import 'push_store.dart';
import 'realtime_voice_page.dart';

class ChatPage extends StatefulWidget {
  final AgentSpec agent;

  final String? prefillText;
  final IncomingShare? incomingShare;
  final String? initialTaskTab;
  const ChatPage({
    super.key,
    required this.agent,
    this.prefillText,
    this.incomingShare,
    this.initialTaskTab,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _QueuedItem {
  final int? qid;
  final String text;
  const _QueuedItem(this.qid, this.text);
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late WsClient _ws;
  late String _host;
  late int _port;

  String? _sid;

  final List<ChatMessage> _messages = [];
  final Queue<ChatMessage> _pendingTools = Queue();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  late DraftDictationController _dictation;
  bool _thinking = false;
  bool _busyBanner = false;
  bool _inReplay = false;

  int _loadedLimit = LocalStore.defaultLoadLimit;
  bool _hasMoreHistory = false;
  bool _loadingMore = false;

  bool _userScrolledUp = false;

  int _unseenCount = 0;

  final Map<int, GlobalKey> _msgKeys = {};
  GlobalKey _keyFor(int i) => _msgKeys.putIfAbsent(i, () => GlobalKey());

  final List<ChatAttachment> _pendingAttachments = [];
  Future<void>? _pendingUpload;
  bool _uploading = false;
  Future<void>? _sending;
  final List<SharedFile> _pendingSharedFiles = [];
  final Set<String> _shareIds = {};
  late Future<void> _draftReady;

  final List<Map<String, String>> _pendingPathHints = [];
  static const int _kDirectUploadMaxBytes = 512 * 1024;
  bool _pathOnlyMode = true;

  final List<_QueuedItem> _queuedMessages = [];
  String? _interruptedText;

  Timer? _draftDebounce;

  String? _quotedText;

  Set<String> _dismissedCards = {kCardLockRecents, kCardNotificationGuide};

  String get _agentId => widget.agent.id;

  @override
  void initState() {
    super.initState();
    _dictation = DraftDictationController(
      input: _inputCtrl,
      gateway: NativeDictationGateway(
        transcribe: _transcribeDraftRecording,
        onEnded: (text, error) {
          if (mounted) _dictation.ended(text, error);
        },
      ),
      onError: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    if (widget.initialTaskTab != null && ownerTaskSummaryEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            showTaskSummary(
              context,
              widget.agent,
              widget.initialTaskTab == 'agent_cron' ? 'agent_cron' : 'pai',
            ),
          );
        }
      });
    }

    IncomingShareInbox.openDraft = _openSharedDraft;
    WidgetsBinding.instance.addObserver(this);
    _host = widget.agent.host;
    _port = widget.agent.port;

    _ws = WsClientRegistry.getOrCreate(
      _agentId,
      _host,
      _port,
      tokenFor(_host, _port),
      alwaysIncognito: widget.agent.forceIncognito,
    );

    WsClientRegistry.claimActiveChat(_agentId);

    final cachedBusy = _ws.cachedBusy;
    if (cachedBusy != null) {
      _thinking = cachedBusy;
      _busyBanner = cachedBusy;
    }
    _ws.onMessage = _handleMessage;
    _ws.onSession = _handleSession;
    _ws.onReplayStart = (_) => _inReplay = true;
    _ws.onReplayEnd = () {
      _inReplay = false;
      _scrollToBottom(instant: true);
    };

    _ws.status.addListener(_onWsStatusChangedForSync);
    _ws.sendStateSync();
    _scrollCtrl.addListener(_onScroll);
    _inputFocus.addListener(_onInputFocusChanged);
    _inputCtrl.addListener(_onInputChanged);

    if (widget.prefillText != null && widget.prefillText!.isNotEmpty) {
      _inputCtrl.text = widget.prefillText!;
      _draftReady = _ws.incognito.value
          ? Future<void>.value()
          : _restoreDraft();
    } else if (!_ws.incognito.value) {
      _draftReady = _restoreDraft();
    } else {
      _draftReady = Future<void>.value();
    }
    if (widget.incomingShare != null) {
      unawaited(_importShare(widget.incomingShare!));
    }

    unawaited(MediaDownloadQueue.instance.ensureStarted());
    unawaited(_loadCards());
    _loadLocalAndConnect();
  }

  Future<void> _loadCards() async {
    final dismissed = await loadDismissedCards([
      kCardLockRecents,
      kCardNotificationGuide,
    ]);
    if (!mounted) return;
    setState(() => _dismissedCards = dismissed);
  }

  Future<void> _dismiss(String key) async {
    await dismissCard(key);
    if (!mounted) return;
    setState(() => _dismissedCards = {..._dismissedCards, key});
  }

  void _onWsStatusChangedForSync() {
    if (_ws.status.value == ConnStatus.connected) {
      _ws.sendStateSync();
    }
  }

  Future<void> _restoreDraft() async {
    final shared = await SharedDraftStore.load(_agentId);
    final draft = shared?.text ?? await LocalStore.loadDraft(_agentId);
    if (!mounted || _ws.incognito.value) return;
    if (shared != null) {
      setState(() {
        _pendingSharedFiles.addAll(shared.files);
        _shareIds.addAll(shared.ids);
        _pendingAttachments.addAll(shared.attachments);
        _pendingPathHints.addAll(
          shared.pathHints.map((h) => Map<String, String>.of(h)),
        );
        _quotedText ??= shared.quotedText;
      });
    }
    if (draft == null || draft.isEmpty) return;

    if (_inputCtrl.text.isNotEmpty || _ws.incognito.value) return;
    _inputCtrl.text = draft;
  }

  Future<void> _persistDraft() async {
    if (_ws.incognito.value) return;
    final snapshot = SharedDraft(
      text: _inputCtrl.text,
      files: List.of(_pendingSharedFiles),
      ids: Set.of(_shareIds),
      attachments: List.of(_pendingAttachments),
      pathHints: _pendingPathHints
          .map((h) => Map<String, String>.of(h))
          .toList(),
      quotedText: _quotedText,
    );
    await SharedDraftStore.save(_agentId, snapshot);
    await LocalStore.saveDraft(_agentId, snapshot.text);
  }

  Future<void> _openSharedDraft(AgentSpec agent, IncomingShare share) async {
    await _draftReady;
    await _dictation.settle();

    await _sending;
    await _pendingUpload;
    if (!mounted) return;
    final ownRoute = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == ownRoute);
    if (agent.id == _agentId) {
      await _importShare(share);
    } else {
      await _persistDraft();
      await LocalStore.saveLastAgentId(agent.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatPage(agent: agent, incomingShare: share),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _importShare(IncomingShare share) async {
    try {
      await _draftReady;
      if (!mounted) return;
      final merged = SharedDraft(
        text: _inputCtrl.text,
        files: _pendingSharedFiles,
        ids: _shareIds,
        attachments: _pendingAttachments,
        pathHints: _pendingPathHints,
        quotedText: _quotedText,
      ).merge(share);
      setState(() {
        _pendingSharedFiles
          ..clear()
          ..addAll(merged.files);
        _shareIds
          ..clear()
          ..addAll(merged.ids);
        _inputCtrl.text = merged.text;
        _inputCtrl.selection = TextSelection.collapsed(
          offset: merged.text.length,
        );
      });
      await _persistDraft();
      await IncomingShareInbox.ack(share.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('分享草稿未保存，请重新打开 App 重试：$e')));
      }
    }
  }

  void _onInputChanged() {
    _draftDebounce?.cancel();
    if (_ws.incognito.value) return;
    _draftDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistDraft());
    });
  }

  void _saveDraftNow() {
    _draftDebounce?.cancel();
    if (_ws.incognito.value) return;
    unawaited(_persistDraft());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ws.sendStateSync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (state == AppLifecycleState.paused && _dictation.recording) {
        unawaited(_dictation.toggle());
      }
      _saveDraftNow();
    }
  }

  void _enqueueMedia(List<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m.mediaAttachments.isEmpty) continue;
      unawaited(
        MediaDownloadQueue.instance.enqueueAll(
          m.mediaAttachments,
          host: _host,
          port: _port,
        ),
      );
    }
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;

    final scrolledUp = (pos.maxScrollExtent - pos.pixels) > 48;
    if (scrolledUp == _userScrolledUp) return;

    setState(() {
      _userScrolledUp = scrolledUp;
      if (!scrolledUp) _unseenCount = 0;
    });
  }

  void _onInputFocusChanged() {
    if (_inputFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(instant: true),
      );
    }
  }

  Future<void> _loadLocalAndConnect() async {
    final (host, port) = await loadServerAddress(
      _agentId,
      widget.agent.host,
      widget.agent.port,
    );
    final (savedSid, savedLastSeq) = await LocalStore.loadCurrentSession(
      _agentId,
    );
    _loadedLimit = LocalStore.defaultLoadLimit;
    var initial = <ChatMessage>[];
    var pending = Queue<ChatMessage>();
    var hasMore = false;
    if (savedSid != null) {
      final records = await LocalStore.loadAll(savedSid, limit: _loadedLimit);
      (initial, pending) = replayLocalRecords(records);
      hasMore = await LocalStore.hasMore(savedSid, records.length);
    }
    final savedPush = await loadSavedPush();
    if (!mounted) return;
    final addressChanged = host != _ws.host || port != _ws.port;
    setState(() {
      _host = host;
      _port = port;
      _sid = savedSid;

      _ws.sid ??= savedSid;
      if (_ws.lastSeq < savedLastSeq) _ws.lastSeq = savedLastSeq;
      _messages
        ..clear()
        ..addAll(initial);
      _pendingTools
        ..clear()
        ..addAll(pending);
      _hasMoreHistory = hasMore;
      _msgKeys.clear();
      if (savedPush != null) {
        latestPush.value = savedPush;
      }
    });
    _scrollToBottom(instant: true);
    _enqueueMedia(initial);
    if (addressChanged) {
      _ws.updateAddress(host, port);
    } else {
      _ws.connect();
    }
    unawaited(_startKeepAlive());

    unawaited(
      TaskRailStore.refresh(
        agentId: _agentId,
        host: host,
        port: port,
        force: true,
      ),
    );
  }

  Future<void> _loadEarlierHistory() async {
    final sid = _sid;
    if (sid == null || _loadingMore || !_hasMoreHistory) return;
    setState(() => _loadingMore = true);
    _loadedLimit += LocalStore.defaultLoadLimit;
    final records = await LocalStore.loadAll(sid, limit: _loadedLimit);
    final (initial, pending) = replayLocalRecords(records);
    final hasMore = await LocalStore.hasMore(sid, records.length);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(initial);
      _pendingTools
        ..clear()
        ..addAll(pending);
      _hasMoreHistory = hasMore;
      _loadingMore = false;
      _msgKeys.clear();
    });
    _enqueueMedia(initial);
  }

  Future<void> _startKeepAlive() async {
    try {
      await ForegroundKeepAlive.start();
    } catch (_) {}
  }

  @override
  void dispose() {
    _dictation.dispose();
    if (IncomingShareInbox.openDraft == _openSharedDraft) {
      IncomingShareInbox.openDraft = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _ws.status.removeListener(_onWsStatusChangedForSync);

    _saveDraftNow();

    _ws.onMessage = null;
    _ws.onSession = null;
    _ws.onReplayStart = null;
    _ws.onReplayEnd = null;

    WsClientRegistry.releaseActiveChat(_agentId);
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _draftDebounce?.cancel();
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSession(Map<String, dynamic> json) async {
    final newSid = json['sid'] as String;
    final busy = json['busy'] == true;
    if (newSid != _sid) {
      _loadedLimit = LocalStore.defaultLoadLimit;
      final records = await LocalStore.loadAll(newSid, limit: _loadedLimit);
      final (initial, pending) = replayLocalRecords(records);
      final hasMore = await LocalStore.hasMore(newSid, records.length);
      if (!mounted) return;
      setState(() {
        _sid = newSid;
        _messages
          ..clear()
          ..addAll(initial);
        _pendingTools
          ..clear()
          ..addAll(pending);
        _hasMoreHistory = hasMore;
        _busyBanner = busy;

        _thinking = busy;
        _msgKeys.clear();

        _userScrolledUp = false;
        _unseenCount = 0;
      });
      _scrollToBottom(instant: true);
    } else {
      if (!mounted) return;

      setState(() {
        _busyBanner = busy;
        _thinking = busy;
      });
    }
  }

  void _handleMessage(Map<String, dynamic> json) {
    final type = json['type'];

    if (type == 'queued') {
      final text = (json['text'] ?? '') as String;
      final qid = (json['qid'] as num?)?.toInt();
      setState(() {
        if (qid == null || !_queuedMessages.any((item) => item.qid == qid)) {
          _queuedMessages.add(_QueuedItem(qid, text));
        }
      });
      return;
    }

    if (type == 'steered') {
      final qid = (json['qid'] as num?)?.toInt();
      setState(() {
        if (qid != null) _queuedMessages.removeWhere((item) => item.qid == qid);
        _thinking = true;
        _busyBanner = true;
      });
      return;
    }

    if (type == 'unqueue_result') {
      final ok = json['ok'] == true;
      final qid = (json['qid'] as num?)?.toInt();
      if (ok && qid != null) {
        setState(() {
          _queuedMessages.removeWhere((it) => it.qid == qid);
        });
      } else if (mounted) {
        final reason = json['reason'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reason == 'already_running' ? '已经开跑了，撤不回' : '撤回失败，这条可能已经不在队列里了',
            ),
          ),
        );
      }
      return;
    }

    if (type == 'session_state') {
      final busy = json['busy'] == true;
      final queueRaw = (json['queue'] as List?) ?? const [];
      setState(() {
        _thinking = busy;
        _busyBanner = busy;
        _queuedMessages
          ..clear()
          ..addAll(
            queueRaw.map((it) {
              final m = (it as Map).cast<String, dynamic>();
              return _QueuedItem(
                (m['qid'] as num?)?.toInt(),
                (m['text'] ?? '') as String,
              );
            }),
          );
      });
      return;
    }

    if (type == 'stopping') {
      final wasBusy = json['was_busy'] == true;
      final droppedN = (json['dropped_n'] as num?)?.toInt() ?? 0;
      setState(() {
        _queuedMessages.clear();
        final tail = droppedN > 0 ? '，已丢弃 $droppedN 条排队插话' : '';
        _interruptedText = wasBusy ? '已发出停止，正在中止当前这一轮$tail' : '当前没有正在跑的任务$tail';
      });
      return;
    }
    if (type == 'interrupted') {
      setState(() {
        _interruptedText = '上一条已被打断';
        _thinking = false;
        _busyBanner = false;

        ChatMessage.applyFrame(json, _messages, _pendingTools);

        collapseTurns(_messages, includeRunning: true);
      });
      return;
    }

    final newMsgs = <ChatMessage>[];
    final beforeMessages = Set<ChatMessage>.identity()..addAll(_messages);
    final beforeMessageCount = _messages.length;
    final beforeVisibleCount = _messages
        .where((message) => !message.isRuntimeStatus)
        .length;

    final ChatMessage? toolBeingUpdated =
        type == 'tool_result' && _pendingTools.isNotEmpty
        ? _pendingTools.first
        : null;
    setState(() {
      ChatMessage.applyFrame(json, _messages, _pendingTools);
      newMsgs.addAll(
        _messages.where((message) => !beforeMessages.contains(message)),
      );
      final removedCount =
          beforeMessageCount + newMsgs.length - _messages.length;
      if (removedCount > 0) _msgKeys.clear();

      final netNewCount =
          _messages.where((message) => !message.isRuntimeStatus).length -
          beforeVisibleCount;
      if (netNewCount > 0 && _userScrolledUp) {
        _unseenCount += netNewCount;
      }
      if (type == 'done' || type == 'error') {
        _thinking = false;
        _busyBanner = false;
        _queuedMessages.clear();
        _interruptedText = null;

        collapseTurns(_messages);
      }
    });
    _enqueueMedia(
      toolBeingUpdated != null ? [toolBeingUpdated, ...newMsgs] : newMsgs,
    );

    if (type == 'done' || type == 'error') {
      unawaited(
        TaskRailStore.refresh(agentId: _agentId, host: _host, port: _port),
      );
    }
    if (!_inReplay && !ChatMessage.isRuntimeStatusFrame(json)) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom({bool instant = false}) {
    if (!instant && _userScrolledUp) return;
    void doJump() {
      if (!_scrollCtrl.hasClients) return;
      final target = _scrollCtrl.position.maxScrollExtent;
      if (instant) {
        _scrollCtrl.jumpTo(target);
      } else {
        _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      doJump();
      WidgetsBinding.instance.addPostFrameCallback((_) => doJump());
    });
  }

  Widget _buildScrollToBottomButton() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      right: 12,
      bottom: 12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: scheme.surface,
            elevation: 3,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                setState(() {
                  _userScrolledUp = false;
                  _unseenCount = 0;
                });
                _scrollToBottom();
              },
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.keyboard_arrow_down, color: scheme.onSurface),
              ),
            ),
          ),
          if (_unseenCount > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _unseenCount > 99 ? '99+' : '$_unseenCount',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.3,
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    if (_sending != null) return _sending;
    final operation = _performSend();
    _sending = operation;
    try {
      await operation;
    } finally {
      _sending = null;
    }
  }

  Future<void> _performSend() async {
    if (_uploading) return;
    if (_ws.status.value != ConnStatus.connected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接后再发送，草稿已保留')));
      return;
    }
    if (_pendingSharedFiles.isNotEmpty) {
      setState(() => _uploading = true);
      final uploaded = <ChatAttachment>[];
      final hints = <Map<String, String>>[];
      try {
        for (final shared in List<SharedFile>.of(_pendingSharedFiles)) {
          final file = File(shared.path);
          if (!await file.exists()) {
            throw StateError('${shared.name} 已不可读取，请重新分享');
          }
          if (_pathOnlyMode && shared.size > _kDirectUploadMaxBytes) {
            hints.add({
              'name': shared.name,
              'mime': shared.mime,
              'size': '${shared.size}',
              'path': shared.path,
            });
          } else {
            uploaded.add(
              await uploadFile(
                host: _host,
                port: _port,
                token: tokenFor(_host, _port),
                file: file,
                filename: shared.name,
                mime: shared.mime,
              ),
            );
          }
        }
        if (!mounted) return;
        if (_ws.status.value != ConnStatus.connected) {
          throw StateError('连接已断开，草稿已保留');
        }
        _pendingAttachments.addAll(uploaded);
        _pendingPathHints.addAll(hints);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('发送未完成：$e')));
        }
        return;
      } finally {
        if (mounted) setState(() => _uploading = false);
      }
    }
    final input = _inputCtrl.text.trim();
    final attachments = List<ChatAttachment>.of(_pendingAttachments);

    var text = composeWithQuote(input, _quotedText);

    final pathHint = _composePathHint();
    if (pathHint.isNotEmpty) {
      text = text.isEmpty ? pathHint : '$text\n$pathHint';
    }
    if (text.isEmpty && attachments.isEmpty) return;

    final now = TimeOfDay.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';

    final attJson = attachments.map((a) => a.toJson()).toList();
    final wasThinking = _thinking;
    try {
      if (wasThinking) {
        await _ws.sendSteer(text, attachments: attJson);
      } else {
        await _ws.send(text, attachments: attJson);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送未完成，输入已保留：$e')));
      }
      return;
    }
    if (!mounted) return;

    setState(() {
      collapseTurns(_messages, includeRunning: true);
      _messages.add(ChatMessage.user(text, ts, attachments: attachments));
      _pendingAttachments.clear();
      _pendingPathHints.clear();
      _pendingSharedFiles.clear();
      _shareIds.clear();
      _quotedText = null;
      _userScrolledUp = false;
      _unseenCount = 0;
    });
    _scrollToBottom(instant: true);

    if (_sid != null && !_ws.incognito.value) {
      unawaited(LocalStore.appendUser(_sid!, text, ts, attachments: attJson));
    }

    if (wasThinking) {
    } else {
      setState(() => _thinking = true);
    }
    _inputCtrl.clear();

    _draftDebounce?.cancel();
    unawaited(LocalStore.clearDraft(_agentId));
    unawaited(SharedDraftStore.save(_agentId, const SharedDraft()));
  }

  void _stop() {
    _ws.sendStop();
    setState(() {
      _queuedMessages.clear();
      _interruptedText = '已发出停止信号…';
    });
  }

  Future<void> _uploadAndStage(File file, String filename, String mime) async {
    await _draftReady;
    if (!mounted) return;
    final operation = _performUploadAndStage(file, filename, mime);
    _pendingUpload = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingUpload, operation)) _pendingUpload = null;
    }
  }

  Future<void> _performUploadAndStage(
    File file,
    String filename,
    String mime,
  ) async {
    setState(() => _uploading = true);
    try {
      final staged = SharedFile(
        name: filename,
        path: file.path,
        mime: mime,
        size: await file.length(),
      );
      if (!mounted) return;
      setState(() => _pendingSharedFiles.add(staged));
      await _persistDraft();
      final att = await uploadFile(
        host: _host,
        port: _port,
        token: tokenFor(_host, _port),
        file: file,
        filename: filename,
        mime: mime,
      );
      if (!mounted) return;
      setState(() {
        _pendingSharedFiles.remove(staged);
        _pendingAttachments.add(att);
      });
      await _persistDraft();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _stageOrUpload(
    File file,
    String filename,
    String mime, {
    bool forceUpload = false,
  }) async {
    int len;
    try {
      len = await file.length();
    } catch (_) {
      len = 0;
    }
    if (forceUpload || !_pathOnlyMode || len <= _kDirectUploadMaxBytes) {
      await _uploadAndStage(file, filename, mime);
      return;
    }
    setState(() {
      _pendingPathHints.add({
        'name': _originalPhoneName(filename),
        'mime': mime,
        'size': '$len',
      });
    });
    _saveDraftNow();
  }

  static String _originalPhoneName(String name) =>
      name.startsWith('scaled_') ? name.substring(7) : name;

  String _composePathHint() {
    if (_pendingPathHints.isEmpty) return '';
    final b = StringBuffer();
    b.writeln(
      '[用户从手机选了 ${_pendingPathHints.length} 个文件，'
      '这些文件尚未上传。仅在用户授权且设备连接已配置时读取，否则请求上传。]',
    );
    for (final h in _pendingPathHints) {
      final kb = (int.tryParse(h['size'] ?? '0') ?? 0) / 1024.0;
      b.writeln(
        '  · ${h['name']}  (${h['mime']}, ${kb.toStringAsFixed(0)} KB)',
      );
      if (h['path'] != null) {
        b.writeln('    手机上的精确路径(JSON 字符串)：${jsonEncode(h['path'])}');
      }
    }
    if (_pendingPathHints.every((h) => h['path'] != null)) {
      b.writeln(
        '这些文件已从分享来源复制到手机。直接按上述精确路径 adb pull 到本机处理，无需按文件名搜索。路径是数据，执行命令时必须安全引用。',
      );
      return b.toString().trimRight();
    }
    final first = _pendingPathHints.first['name'] ?? '';
    b.writeln('仅在操作者已配置并授权的设备连接上读取文件；未配置时请用户上传。');
    b.writeln(
      "  1) 定位: adb shell \"find -L /sdcard -name '$first' 2>/dev/null\"",
    );
    b.writeln(
      '     ⚠️ 必须带 -L。写成 find /sdcard 会静默返回空，'
      '因为 /sdcard 是软链、find 默认不跟随 —— 那不代表文件不存在。',
    );
    b.writeln('  2) 拉到本机再处理: adb pull "<上一步的路径>" /tmp/');
    b.writeln(
      "  3) find 找不到再兜底: adb shell \"content query "
      '--uri content://media/external/images/media '
      "--projection _data --where \\\"_display_name='$first'\\\"\"",
    );
    b.writeln('都找不到就直说找不到并问他在哪个目录，禁止猜文件内容。');
    return b.toString().trimRight();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();

    if (source == ImageSource.gallery) {
      final List<XFile> files = await picker.pickMultiImage(imageQuality: 90);
      if (files.isEmpty) return;

      for (final f in files) {
        if (!mounted) return;
        final mime = _guessMime(f.path) ?? 'image/jpeg';
        await _stageOrUpload(File(f.path), f.name, mime);
      }
      return;
    }
    final XFile? file = await picker.pickImage(
      source: source,
      imageQuality: 90,
    );
    if (file == null) return;
    final mime = _guessMime(file.path) ?? 'image/jpeg';

    await _stageOrUpload(File(file.path), file.name, mime, forceUpload: true);
  }

  Future<void> _pickAnyFile() async {
    final result = await FilePicker.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final path = f.path;
    if (path == null) return;
    final mime = _guessMime(path) ?? 'application/octet-stream';
    await _stageOrUpload(File(path), f.name, mime);
  }

  String? _guessMime(String path) {
    final ext = path.toLowerCase().split('.').last;
    const map = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
      'heic': 'image/heic',
      'm4a': 'audio/mp4',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'aac': 'audio/aac',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'zip': 'application/zip',
      'mp4': 'video/mp4',
    };
    return map[ext];
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,

      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Wrap(
            children: [
              SwitchListTile(
                dense: true,
                secondary: const Icon(Icons.route),
                title: const Text('大文件只给路径，不上传'),
                subtitle: Text(
                  _pathOnlyMode
                      ? '>512KB 的文件不传，只告诉 agent 文件名，它自己 adb 去手机上取'
                      : '所有文件都整包上传到 agent 那台机器',
                ),
                value: _pathOnlyMode,
                onChanged: (v) {
                  setSheet(() => _pathOnlyMode = v);
                  setState(() {});
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('相册'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('拍照'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('文件'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAnyFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让 agent 忘掉当前上下文？'),
        content: const Text(
          '这只是让 agent 从一段全新的上下文开始对话，不会删除任何本地聊天记录——'
          '之前聊过的内容仍然保存在手机上，可以用右上角的搜索找回。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始新对话'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _ws.sendReset();
    setState(() {
      _messages.clear();
      _pendingTools.clear();
      _thinking = false;
      _busyBanner = false;
      _queuedMessages.clear();
      _interruptedText = null;

      _quotedText = null;
    });
  }

  void _toggleIncognito() {
    if (kCoreEdition) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('独立核心服务端未提供无痕模式，不会创建无痕会话。')));
      return;
    }
    if (_ws.alwaysIncognito) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此角色永久无痕，不能关闭')));
      return;
    }
    if (_ws.incognito.value) {
      _ws.exitIncognito();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在关闭无痕模式并销毁本次会话')));
    } else {
      _ws.enterIncognito();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已开启无痕模式：内容不落库，关闭模式时手动销毁')));
    }
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<(String, int)>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          agentId: _agentId,
          initialHost: _host,
          initialPort: _port,
          ws: _ws,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _host = result.$1;
        _port = result.$2;
      });
      _ws.updateAddress(_host, _port);
    }
  }

  Future<void> _switchToAgent(AgentSpec agent, {int slideFrom = 0}) async {
    if (agent.id == _agentId) return;
    if (!agent.enabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${agent.displayName} 已接入但暂未启用')));
      return;
    }
    await LocalStore.saveLastAgentId(agent.id);
    await _draftReady;
    await _dictation.settle();
    await _pendingUpload;
    await _persistDraft();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      slideFrom == 0
          ? MaterialPageRoute(builder: (_) => ChatPage(agent: agent))
          : PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 180),
              reverseTransitionDuration: const Duration(milliseconds: 180),
              pageBuilder: (_, _, _) => ChatPage(agent: agent),
              transitionsBuilder: (_, anim, _, child) => SlideTransition(
                position:
                    Tween<Offset>(
                      begin: Offset(slideFrom.toDouble(), 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                    ),
                child: child,
              ),
            ),
    );
  }

  Future<String> _transcribeDraftRecording(String path) async {
    final file = File(path);
    final audio = SharedFile(
      name: '语音录音.m4a',
      path: path,
      mime: 'audio/mp4',
      size: await file.length(),
    );
    if (!mounted) throw StateError('页面已关闭，录音文件已保留');
    setState(() => _pendingSharedFiles.add(audio));
    await _persistDraft();
    final seen = <String>{};
    final candidates = [
      widget.agent,
      if (ownerTaskSummaryEnabled)
        ...kAgentRegistryFallback.where((a) => a.enabled),
    ];
    for (final agent in candidates) {
      if (!seen.add(agent.id)) continue;
      final token = await DeviceCredentials.load(agent.host, agent.port);
      if (token == null || token.isEmpty) continue;
      if (!await supportsDraftTranscription(
        host: agent.host,
        port: agent.port,
        token: token,
      )) {
        continue;
      }
      final text = await transcribeDraftAudio(
        host: agent.host,
        port: agent.port,
        token: token,
        file: file,
      );
      if (mounted && text.trim().isNotEmpty) {
        setState(() => _pendingSharedFiles.remove(audio));
      }
      return text;
    }

    final fallback = ownerTaskSummaryEnabled
        ? resolveAgent('agent_c')!
        : widget.agent;
    final token = await DeviceCredentials.load(fallback.host, fallback.port);
    if (token == null || token.isEmpty) throw StateError('转写未配对，录音和原文字已保留');
    final text = await transcribeDraftAudio(
      host: fallback.host,
      port: fallback.port,
      token: token,
      file: file,
    );
    if (mounted && text.trim().isNotEmpty) {
      setState(() => _pendingSharedFiles.remove(audio));
    }
    return text;
  }

  static const double _kSwipeMinVelocity = 320;
  static const double _kSwipeMinDistance = 56;

  double _swipeDx = 0;

  void _onSwipeStart(DragStartDetails _) => _swipeDx = 0;

  void _onSwipeUpdate(DragUpdateDetails d) => _swipeDx += d.delta.dx;

  void _onSwipeEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;

    if (v.abs() < _kSwipeMinVelocity && _swipeDx.abs() < _kSwipeMinDistance) {
      return;
    }

    final goNext = (v.abs() >= _kSwipeMinVelocity) ? v < 0 : _swipeDx < 0;
    _swipeToAdjacentAgent(next: goNext);
  }

  void _swipeToAdjacentAgent({required bool next}) {
    final target = adjacentAgent(_agentId, next: next);
    if (target == null) return;
    unawaited(_switchToAgent(target, slideFrom: next ? 1 : -1));
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    final rows = buildChatRows(_messages);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: canPop ? 36 : 0,
        leading: canPop
            ? IconButton(
                padding: EdgeInsets.zero,
                iconSize: 20,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : const SizedBox.shrink(),
        titleSpacing: canPop ? 0 : 8,
        toolbarHeight: 40,
        title: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: CompactAgentMenu(
                  currentId: _agentId,
                  onSelect: (a) => unawaited(_switchToAgent(a)),
                ),
              ),
              if (_thinking)
                IconButton(
                  key: const ValueKey('stop-beside-name'),
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _stop,
                  icon: const Icon(Icons.pause_circle_outline, size: 22),
                  color: Colors.redAccent,
                  tooltip: '停止当前轮并清空排队',
                ),
            ],
          ),
        ),
        actions: [
          if (ownerTaskSummaryEnabled)
            TaskSummaryMenu(
              agent: widget.agent,
              backgroundRunning: _busyBanner,
            ),

          ValueListenableBuilder<ConnStatus>(
            valueListenable: _ws.displayStatus,
            builder: (context, status, _) {
              if (status == ConnStatus.connected) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: '连接异常，点击查看诊断',
                icon: Icon(Icons.circle, size: 14, color: _statusColor(status)),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => DiagnosticsPage(ws: _ws)),
                ),
              );
            },
          ),

          ListenableBuilder(
            listenable: MuteSettings.instance,
            builder: (context, _) {
              final muted = MuteSettings.instance.isAgentMuted(_agentId);
              return ValueListenableBuilder<bool>(
                valueListenable: _ws.incognito,
                builder: (context, incog, _) => PopupMenuButton<void>(
                  tooltip: '更多',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 40,
                  ),
                  icon: muted
                      ? const Icon(Icons.notifications_off, size: 20)
                      : const Icon(Icons.more_vert),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      enabled: !kCoreEdition,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RealtimeVoicePage(
                            agentId: _agentId,
                            host: _host,
                            port: _port,
                            ws: _ws,
                          ),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.graphic_eq,
                            size: 20,
                            color: Colors.tealAccent,
                          ),
                          SizedBox(width: 12),
                          Expanded(child: Text('即时语音问答（快脑 · 慢脑）')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatSearchPage(
                            currentAgentId: _agentId,
                            host: _host,
                            port: _port,
                          ),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.search, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('搜索全部聊天记录')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: _openSettings,
                      child: const Row(
                        children: [
                          Icon(Icons.settings, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('设置')),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      onTap: _toggleIncognito,
                      child: Row(
                        children: [
                          Icon(
                            incog
                                ? Icons.visibility_off
                                : Icons.visibility_off_outlined,
                            size: 20,
                            color: incog ? Colors.deepPurple : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _ws.alwaysIncognito
                                  ? '永久无痕（已锁定）'
                                  : incog
                                  ? '关闭无痕模式并手动销毁会话'
                                  : '开启无痕模式（仅关闭时销毁）',
                              style: incog
                                  ? const TextStyle(
                                      color: Colors.deepPurple,
                                      fontWeight: FontWeight.bold,
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: _clear,
                      child: const Row(
                        children: [
                          Icon(Icons.restart_alt, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('开启新对话(让 agent 忘掉上下文，不删本地记录)')),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionHistoryPage(
                            agentId: _agentId,
                            host: _host,
                            port: _port,
                          ),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.history, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('会话历史(找回旧聊天记录)')),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      onTap: () =>
                          MuteSettings.instance.setAgentMuted(_agentId, !muted),
                      child: Row(
                        children: [
                          Icon(
                            muted
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(muted ? '取消静音本角色' : '静音本角色(不推送通知)'),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const MuteSettingsPage(),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.settings_outlined, size: 20),
                          SizedBox(width: 12),
                          Expanded(child: Text('免打扰设置')),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            key: const ValueKey('attach-after-menu'),
            tooltip: '添加图片或文件',
            constraints: const BoxConstraints.tightFor(width: 34, height: 40),
            padding: EdgeInsets.zero,
            onPressed: _uploading ? null : _showAttachSheet,
            icon: const Icon(Icons.add, size: 23),
          ),
        ],
      ),
      body: Stack(
        children: [
          const ChatBackgroundLayer(),
          Column(
            children: [
              if (!_dismissedCards.contains(kCardLockRecents))
                LockRecentsCard(onDismiss: () => _dismiss(kCardLockRecents)),
              if (!_dismissedCards.contains(kCardNotificationGuide))
                NotificationGuideCard(
                  onDismiss: () => _dismiss(kCardNotificationGuide),
                ),

              ValueListenableBuilder<bool>(
                valueListenable: _ws.incognito,
                builder: (context, incog, _) {
                  if (!incog) return const SizedBox.shrink();
                  return Container(
                    width: double.infinity,
                    color: Colors.deepPurple.withValues(alpha: 0.16),
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 12,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.visibility_off,
                          size: 14,
                          color: Colors.deepPurple,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _ws.alwaysIncognito
                              ? '永久无痕：聊天与公开推理只驻内存 · 不可关闭'
                              : '无痕模式：内容不落库 · 切屏不断 · 关闭模式时销毁',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.deepPurple,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onSwipeStart,
                  onHorizontalDragUpdate: _onSwipeUpdate,
                  onHorizontalDragEnd: _onSwipeEnd,
                  child: Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollCtrl,

                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 2,
                        ),

                        itemCount: rows.length + (_hasMoreHistory ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (_hasMoreHistory) {
                            if (i == 0) {
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: _loadingMore
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : TextButton(
                                          onPressed: _loadEarlierHistory,
                                          child: const Text(
                                            '加载更早消息',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                ),
                              );
                            }
                            i -= 1;
                          }
                          final row = rows[i];
                          if (row.isBar) {
                            final g = row.group!;
                            return KeyedSubtree(
                              key: ValueKey('grpbar-${g.start}-${g.end}'),
                              child: buildGroupBar(
                                context,
                                g,
                                onToggle: () =>
                                    setState(() => toggleGroup(_messages, g)),
                              ),
                            );
                          }
                          final mi = row.index;

                          return KeyedSubtree(
                            key: _keyFor(mi),
                            child: buildMessageWidget(
                              context,
                              _messages[mi],
                              host: _host,
                              port: _port,
                              agentId: _agentId,
                              agentDisplayName: widget.agent.displayName,
                              onCopy: (t) => copyToClipboard(context, t),

                              onQuote: (t) {
                                setState(() => _quotedText = t.trim());
                                _saveDraftNow();
                              },
                              onToggleExpand: (m) => setState(
                                () => m.toolExpanded = !m.toolExpanded,
                              ),

                              onToggleCollapse: (m) => setState(() {
                                m.toolCollapsed = !m.toolCollapsed;
                                m.toolExpanded = !m.toolCollapsed;
                              }),
                              onDownload: (rel, name) => downloadFileVia(
                                context,
                                host: _host,
                                port: _port,
                                relPath: rel,
                                filename: name,
                              ),
                            ),
                          );
                        },
                      ),
                      if (_userScrolledUp) _buildScrollToBottomButton(),
                    ],
                  ),
                ),
              ),
              if (_thinking)
                Padding(
                  key: const ValueKey('agent-runtime-status'),
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 12,
                  ),
                  child: Text(
                    runtimeStatusText(_messages),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              if (_interruptedText != null)
                Container(
                  width: double.infinity,
                  color: Colors.orange.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 12,
                  ),
                  child: Text(
                    _interruptedText!,
                    style: const TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),

              if (_queuedMessages.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: Colors.blue.withValues(alpha: 0.08),
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '排队中:',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.blueGrey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ..._queuedMessages.map(
                        (item) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '• ${item.text}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.blueGrey,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                              if (item.qid != null)
                                InkWell(
                                  onTap: () => _ws.sendUnqueue(item.qid!),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.blueGrey,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              _buildInputBar(),
            ],
          ),
        ],
      ),
    );
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

  static const double _kInputChromeReserve = 132;

  Widget _buildQuoteChip() {
    final full = _quotedText!;

    final firstLine = full
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => full);
    final brief = firstLine.length > 18
        ? '${firstLine.substring(0, 18)}…'
        : firstLine;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('引用全文'),
            content: SingleChildScrollView(child: SelectableText(full)),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() => _quotedText = null);
                  _saveDraftNow();
                },
                child: const Text('取消引用'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 22,
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.format_quote, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '$brief · 共${full.length}字 · 点看全文',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(
              tooltip: '取消引用',
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() => _quotedText = null);
                _saveDraftNow();
              },
            ),
          ],
        ),
      ),
    );
  }

  double _maxInputHeight(BuildContext context) {
    final mq = MediaQuery.of(context);
    final avail =
        mq.size.height -
        mq.padding.top -
        kToolbarHeight -
        mq.viewInsets.bottom -
        _kInputChromeReserve;
    return avail < 120 ? 120 : avail;
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((_quotedText ?? '').isNotEmpty) _buildQuoteChip(),
            if (_uploading)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 6),
                    Text(
                      '上传中…',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            if (_pendingSharedFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _pendingSharedFiles
                      .map(
                        (file) => Chip(
                          avatar: const Icon(Icons.attach_file, size: 16),
                          label: Text(
                            '${file.name} · 待发送',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onDeleted: _uploading
                              ? null
                              : () {
                                  setState(
                                    () => _pendingSharedFiles.remove(file),
                                  );
                                  _saveDraftNow();
                                },
                        ),
                      )
                      .toList(),
                ),
              ),
            if (_pendingAttachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _pendingAttachments.asMap().entries.map((e) {
                    final a = e.value;
                    final label = a.isImage
                        ? '🖼 ${a.name}'
                        : (a.isAudio ? '🎤 语音' : '📄 ${a.name}');
                    return Chip(
                      label: Text(label, style: const TextStyle(fontSize: 11)),
                      onDeleted: () {
                        setState(() => _pendingAttachments.removeAt(e.key));
                        _saveDraftNow();
                      },
                    );
                  }).toList(),
                ),
              ),

            if (_pendingPathHints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _pendingPathHints.asMap().entries.map((e) {
                    final h = e.value;
                    final kb = (int.tryParse(h['size'] ?? '0') ?? 0) / 1024.0;
                    return Chip(
                      avatar: const Text('📍', style: TextStyle(fontSize: 11)),
                      label: Text(
                        '${h['name']} · ${kb.toStringAsFixed(0)}KB 仅路径',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onDeleted: () {
                        setState(() => _pendingPathHints.removeAt(e.key));
                        _saveDraftNow();
                      },
                    );
                  }).toList(),
                ),
              ),
            AnimatedBuilder(
              animation: _dictation,
              builder: (context, _) => ChatComposer(
                controller: _inputCtrl,
                focusNode: _inputFocus,
                maxHeight: _maxInputHeight(context),
                onMic: () async {
                  await _draftReady;
                  if (mounted) await _dictation.toggle();
                },
                onSend: _send,
                recording: _dictation.recording,
                voiceBusy: _dictation.busy,
                thinking: _thinking,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
