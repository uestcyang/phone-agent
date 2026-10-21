import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runtime_status_policy.dart';

const String _prefCurrentSidPrefix = 'current_sid_';
const String _prefCurrentLastSeqPrefix = 'current_last_seq_';
const String _prefIncognitoActivePrefix = 'incognito_active_';
const String _prefIncognitoSidPrefix = 'incognito_sid_';
const String _prefIncognitoLastSeqPrefix = 'incognito_last_seq_';
const String _prefIncognitoSavedSidPrefix = 'incognito_saved_sid_';
const String _prefIncognitoSavedLastSeqPrefix = 'incognito_saved_last_seq_';
const String _prefSessionsCachePrefix = 'sessions_cache_json_';
const String _prefDraftPrefix = 'input_draft_';
const String _prefLineCountPrefix = 'chat_line_count_';
const String _prefLastAgentId = 'last_agent_id';

class LocalRecord {
  final String kind;
  final String ts;
  final int? seq;
  final Map<String, dynamic> payload;

  LocalRecord.user(
    String text,
    this.ts, {
    List<Map<String, dynamic>>? attachments,
  }) : kind = 'user',
       seq = null,
       payload = {
         'text': text,
         if (attachments != null && attachments.isNotEmpty)
           'attachments': attachments,
       };

  LocalRecord.frame(Map<String, dynamic> frame)
    : kind = 'frame',
      seq = (frame['seq'] as num?)?.toInt(),
      ts = (frame['ts'] ?? '') as String,
      payload = frame;

  LocalRecord._raw(this.kind, this.ts, this.seq, this.payload);

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'ts': ts,
    'seq': seq,
    'payload': payload,
  };

  static LocalRecord fromJson(Map<String, dynamic> j) => LocalRecord._raw(
    j['kind'] as String,
    (j['ts'] ?? '') as String,
    (j['seq'] as num?)?.toInt(),
    (j['payload'] as Map).cast<String, dynamic>(),
  );
}

class LocalStore {
  static const int archiveMaxBytes = 5 * 1024 * 1024;
  static const int archiveMaxLines = 5000;
  static const int maxArchives = 5;

  static const int defaultLoadLimit = 200;

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/phone_agent_chat');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _fileFor(String sid) async {
    final dir = await _dir();
    return File('${dir.path}/chat_$sid.jsonl');
  }

  static Future<File> _archiveFile(String sid, int n) async {
    final dir = await _dir();
    return File('${dir.path}/chat_$sid.$n.jsonl');
  }

  static Future<List<String>> _readNonEmptyLines(File file) async {
    if (!await file.exists()) return [];
    try {
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static List<LocalRecord> _decode(List<String> lines) {
    final out = <LocalRecord>[];
    for (final line in lines) {
      try {
        out.add(LocalRecord.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  static List<LocalRecord> _compactRuntime(List<LocalRecord> records) {
    final out = <LocalRecord?>[];
    final runtime = <String, int>{};
    void clear(String key) {
      final index = runtime.remove(key);
      if (index != null) out[index] = null;
    }

    void clearAll() {
      for (final index in runtime.values) {
        out[index] = null;
      }
      runtime.clear();
    }

    for (final record in records) {
      final frame = record.payload;
      final type = record.kind == 'frame' ? frame['type'] : null;
      if (record.kind == 'user' ||
          type == 'done' ||
          type == 'error' ||
          type == 'interrupted') {
        clearAll();
      }
      if (record.kind == 'frame') {
        final key = RuntimeStatusPolicy.frameKey(frame);
        if (key != null) {
          clear(key);
          if (key == 'codex_connection' && frame['state'] == 'connected') {
            continue;
          }
          runtime[key] = out.length;
          out.add(record);
          continue;
        }
        if ((type == 'narration' &&
                (frame['text'] as String? ?? '').trim().isNotEmpty) ||
            type == 'tool' ||
            type == 'tool_result' ||
            type == 'assistant') {
          clear('codex_connection');
        }
      }
      out.add(record);
    }
    return out.whereType<LocalRecord>().toList();
  }

  static Future<List<LocalRecord>> loadAll(String sid, {int? limit}) async {
    final current = await _readNonEmptyLines(await _fileFor(sid));
    if (limit == null) {
      final archived = <String>[];
      for (var n = maxArchives; n >= 1; n--) {
        archived.addAll(await _readNonEmptyLines(await _archiveFile(sid, n)));
      }
      return _decode([...archived, ...current]);
    }
    if (limit <= 0) return [];
    var records = _decode(current);
    var compacted = _compactRuntime(records);
    for (var n = 1; n <= maxArchives && compacted.length < limit; n++) {
      final archived = _decode(
        await _readNonEmptyLines(await _archiveFile(sid, n)),
      );
      records = [...archived, ...records];
      compacted = _compactRuntime(records);
    }
    return compacted.length > limit
        ? compacted.sublist(compacted.length - limit)
        : compacted;
  }

  static Future<bool> hasMore(String sid, int loadedCount) async {
    return (await loadAll(sid, limit: loadedCount + 1)).length > loadedCount;
  }

  static Future<void> appendUser(
    String sid,
    String text,
    String ts, {
    List<Map<String, dynamic>>? attachments,
  }) async {
    await _append(sid, LocalRecord.user(text, ts, attachments: attachments));
  }

  static Future<void> appendFrame(
    String sid,
    Map<String, dynamic> frame,
  ) async {
    await _append(sid, LocalRecord.frame(frame));
  }

  static final Map<String, Future<void>> _appendChains = {};

  static Future<void> _append(String sid, LocalRecord rec) {
    final previous = _appendChains[sid] ?? Future<void>.value();
    final result = previous.then((_) async {
      final file = await _fileFor(sid);
      await file.writeAsString(
        '${jsonEncode(rec.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      await _maybeRotate(sid, file);
    });
    _appendChains[sid] = result.catchError((_) {});
    return result;
  }

  static Future<void> pendingFlush(String sid) =>
      _appendChains[sid] ?? Future<void>.value();

  static Future<int?> lastFrameSeq(String sid) async {
    final lines = await _readNonEmptyLines(await _fileFor(sid));
    for (var i = lines.length - 1; i >= 0; i--) {
      try {
        final rec = LocalRecord.fromJson(
          jsonDecode(lines[i]) as Map<String, dynamic>,
        );
        if (rec.kind == 'frame' && rec.seq != null) return rec.seq;
      } catch (_) {}
    }
    return null;
  }

  static Future<void> _maybeRotate(String sid, File file) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefLineCountPrefix$sid';
    final lineCount = (prefs.getInt(key) ?? 0) + 1;
    final overBytes = await file.length() >= archiveMaxBytes;
    if (!overBytes && lineCount < archiveMaxLines) {
      await prefs.setInt(key, lineCount);
      return;
    }
    await _rotate(sid, file);
    await prefs.setInt(key, 0);
  }

  static Future<void> _rotate(String sid, File current) async {
    final dir = await _dir();
    final oldest = await _archiveFile(sid, maxArchives);
    if (await oldest.exists()) await oldest.delete();
    for (var n = maxArchives - 1; n >= 1; n--) {
      final src = await _archiveFile(sid, n);
      if (await src.exists()) {
        await src.rename('${dir.path}/chat_$sid.${n + 1}.jsonl');
      }
    }

    await current.rename('${dir.path}/chat_$sid.1.jsonl');
  }

  static Future<(String?, int)> loadCurrentSession(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getString('$_prefCurrentSidPrefix$agentId'),
      prefs.getInt('$_prefCurrentLastSeqPrefix$agentId') ?? 0,
    );
  }

  static Future<void> saveCurrentSession(
    String agentId,
    String sid,
    int lastSeq,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefCurrentSidPrefix$agentId', sid);
    await prefs.setInt('$_prefCurrentLastSeqPrefix$agentId', lastSeq);
  }

  static Future<(bool, String?, int, String?, int)> loadIncognitoState(
    String agentId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getBool('$_prefIncognitoActivePrefix$agentId') ?? false,
      prefs.getString('$_prefIncognitoSidPrefix$agentId'),
      prefs.getInt('$_prefIncognitoLastSeqPrefix$agentId') ?? 0,
      prefs.getString('$_prefIncognitoSavedSidPrefix$agentId'),
      prefs.getInt('$_prefIncognitoSavedLastSeqPrefix$agentId') ?? 0,
    );
  }

  static Future<void> saveIncognitoState(
    String agentId, {
    required String? incognitoSid,
    required int lastSeq,
    required String? savedSid,
    required int savedLastSeq,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefIncognitoActivePrefix$agentId', true);
    if (incognitoSid == null) {
      await prefs.remove('$_prefIncognitoSidPrefix$agentId');
    } else {
      await prefs.setString('$_prefIncognitoSidPrefix$agentId', incognitoSid);
    }
    await prefs.setInt('$_prefIncognitoLastSeqPrefix$agentId', lastSeq);
    if (savedSid == null) {
      await prefs.remove('$_prefIncognitoSavedSidPrefix$agentId');
    } else {
      await prefs.setString('$_prefIncognitoSavedSidPrefix$agentId', savedSid);
    }
    await prefs.setInt(
      '$_prefIncognitoSavedLastSeqPrefix$agentId',
      savedLastSeq,
    );
  }

  static Future<void> clearIncognitoState(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove('$_prefIncognitoActivePrefix$agentId'),
      prefs.remove('$_prefIncognitoSidPrefix$agentId'),
      prefs.remove('$_prefIncognitoLastSeqPrefix$agentId'),
      prefs.remove('$_prefIncognitoSavedSidPrefix$agentId'),
      prefs.remove('$_prefIncognitoSavedLastSeqPrefix$agentId'),
    ]);
  }

  static Future<void> saveSessionsCache(
    String agentId,
    List<dynamic> sessions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_prefSessionsCachePrefix$agentId',
      jsonEncode(sessions),
    );
  }

  static Future<List<dynamic>> loadSessionsCache(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefSessionsCachePrefix$agentId');
    if (raw == null) return [];
    try {
      return jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveDraft(String agentId, String text) async {
    final prefs = await SharedPreferences.getInstance();
    if (text.isEmpty) {
      await prefs.remove('$_prefDraftPrefix$agentId');
    } else {
      await prefs.setString('$_prefDraftPrefix$agentId', text);
    }
  }

  static Future<String?> loadDraft(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefDraftPrefix$agentId');
  }

  static Future<void> clearDraft(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefDraftPrefix$agentId');
  }

  static Future<String?> loadLastAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefLastAgentId);
  }

  static Future<void> saveLastAgentId(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastAgentId, agentId);
  }
}
