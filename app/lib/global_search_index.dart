import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_registry.dart';
import 'local_store.dart';
import 'models.dart';

enum AgentMatch { currentSession, ledger, sessionsCache, unknown }

class SidOwner {
  const SidOwner(this.agentId, this.match);

  final String agentId;
  final AgentMatch match;
}

class IndexedMessage {
  IndexedMessage({
    required this.sid,
    required this.agentId,
    required this.agentLabel,
    required this.agentMatch,
    required this.sessionMtime,
    required this.indexInSession,
    required this.message,
  }) : haystackLower = message.searchableText.toLowerCase();

  final String sid;

  final String? agentId;

  final String agentLabel;

  final AgentMatch agentMatch;

  final DateTime sessionMtime;

  final int indexInSession;
  final ChatMessage message;

  final String haystackLower;
}

class IndexedSession {
  IndexedSession({
    required this.sid,
    required this.agentId,
    required this.agentLabel,
    required this.agentMatch,
    required this.mtime,
    required this.messageCount,
  });

  final String sid;
  final String? agentId;
  final String agentLabel;
  final AgentMatch agentMatch;
  final DateTime mtime;
  final int messageCount;
}

class GlobalSearchIndex {
  const GlobalSearchIndex({
    required this.messages,
    required this.sessions,
    this.truncated = false,
  });

  const GlobalSearchIndex._empty()
    : messages = const [],
      sessions = const [],
      truncated = false;

  final List<IndexedMessage> messages;

  final List<IndexedSession> sessions;

  final bool truncated;

  static const GlobalSearchIndex empty = GlobalSearchIndex._empty();

  static const int maxIndexedMessages = 60000;

  int get sessionCount => sessions.length;

  int get unknownSessionCount =>
      sessions.where((s) => s.agentMatch == AgentMatch.unknown).length;

  static final RegExp _sidPattern = RegExp(r'^chat_(.+)\.jsonl$');

  static const String _ledgerKey = 'global_search_sid_agent_ledger_v1';

  static Future<GlobalSearchIndex> build({
    void Function(int done, int total)? onProgress,
  }) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/phone_agent_chat');
    if (!await dir.exists()) {
      onProgress?.call(0, 0);
      return empty;
    }

    final sids = <String>[];
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final m = _sidPattern.firstMatch(f.uri.pathSegments.last);
      if (m != null) sids.add(m.group(1)!);
    }

    final owners = await buildSidOwnerMap();

    await _persistLedger(owners, sids.toSet());

    final mtimes = <String, DateTime>{};
    for (final sid in sids) {
      try {
        mtimes[sid] = (await File(
          '${dir.path}/chat_$sid.jsonl',
        ).stat()).modified;
      } catch (_) {
        mtimes[sid] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    sids.sort((a, b) => mtimes[b]!.compareTo(mtimes[a]!));

    onProgress?.call(0, sids.length);

    final messages = <IndexedMessage>[];
    final sessions = <IndexedSession>[];
    var truncated = false;
    for (var i = 0; i < sids.length; i++) {
      if (messages.length >= maxIndexedMessages) {
        truncated = true;
        onProgress?.call(sids.length, sids.length);
        break;
      }
      final sid = sids[i];
      final owner = owners[sid];
      final agentId = owner?.agentId;
      final match = owner?.match ?? AgentMatch.unknown;
      final label = _labelFor(agentId);
      final mtime = mtimes[sid]!;

      final (replayed, _) = replayLocalRecords(await LocalStore.loadAll(sid));
      if (replayed.isNotEmpty) {
        sessions.add(
          IndexedSession(
            sid: sid,
            agentId: agentId,
            agentLabel: label,
            agentMatch: match,
            mtime: mtime,
            messageCount: replayed.length,
          ),
        );
        for (var k = 0; k < replayed.length; k++) {
          final msg = replayed[k];

          if (msg.searchableText.trim().isEmpty) continue;
          messages.add(
            IndexedMessage(
              sid: sid,
              agentId: agentId,
              agentLabel: label,
              agentMatch: match,
              sessionMtime: mtime,
              indexInSession: k,
              message: msg,
            ),
          );
        }
      }
      onProgress?.call(i + 1, sids.length);

      await Future<void>.delayed(Duration.zero);
    }

    return GlobalSearchIndex(
      messages: messages,
      sessions: sessions,
      truncated: truncated,
    );
  }

  static Future<List<ChatMessage>> messagesOf(String sid) async {
    final (replayed, _) = replayLocalRecords(await LocalStore.loadAll(sid));
    return replayed;
  }

  static Future<Map<String, SidOwner>> buildSidOwnerMap() async {
    final owners = <String, SidOwner>{};
    for (final spec in kAgentRegistryFallback) {
      final (sid, _) = await LocalStore.loadCurrentSession(spec.id);
      if (sid != null && sid.isNotEmpty) {
        owners[sid] = SidOwner(spec.id, AgentMatch.currentSession);
      }
    }
    for (final entry in (await _readLedger()).entries) {
      owners.putIfAbsent(
        entry.key,
        () => SidOwner(entry.value, AgentMatch.ledger),
      );
    }
    for (final spec in kAgentRegistryFallback) {
      for (final raw in await LocalStore.loadSessionsCache(spec.id)) {
        if (raw is! Map) continue;
        final sid = raw['sid'] ?? raw['session_id'] ?? raw['id'];
        if (sid is! String || sid.isEmpty) continue;
        owners.putIfAbsent(
          sid,
          () => SidOwner(spec.id, AgentMatch.sessionsCache),
        );
      }
    }
    return owners;
  }

  static Future<Map<String, String>> _readLedger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_ledgerKey);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _persistLedger(
    Map<String, SidOwner> owners,
    Set<String> sidsOnDisk,
  ) async {
    try {
      final merged = <String, String>{};
      for (final e in (await _readLedger()).entries) {
        if (sidsOnDisk.contains(e.key)) merged[e.key] = e.value;
      }
      for (final e in owners.entries) {
        merged[e.key] = e.value.agentId;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ledgerKey, jsonEncode(merged));
    } catch (_) {}
  }

  static String _labelFor(String? agentId) {
    if (agentId == null) return '未知角色';
    for (final spec in kAgentRegistryFallback) {
      if (spec.id == agentId) return spec.displayName;
    }
    return agentId;
  }
}
