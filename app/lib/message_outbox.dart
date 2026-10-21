import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class MessageOutbox {
  final String scope;
  final bool memoryOnly;
  final Directory? directory;
  final Map<String, Map<String, dynamic>> _entries = {};
  Future<void> _serial = Future<void>.value();
  Future<void>? _loaded;
  File? _file;
  bool _erased = false;

  MessageOutbox(this.scope, {this.memoryOnly = false, this.directory});

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _serial.then((_) => operation());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _load() => _loaded ??= _read();

  Future<void> _read() async {
    if (memoryOnly) return;
    final root = directory ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/phone_agent_delivery');
    await dir.create(recursive: true);
    final digest = sha256.convert(utf8.encode(scope));
    _file = File('${dir.path}/$digest.json');
    if (!await _file!.exists()) return;
    final parsed = jsonDecode(await _file!.readAsString()) as List;
    for (final row in parsed) {
      final entry = Map<String, dynamic>.from(row as Map);
      _entries[entry['client_message_id'] as String] = entry;
    }
  }

  Future<void> _persist() async {
    if (memoryOnly) return;
    final tmp = File('${_file!.path}.tmp');
    await tmp.writeAsString(jsonEncode(_entries.values.toList()), flush: true);
    await tmp.rename(_file!.path);
  }

  Future<Map<String, dynamic>> enqueue(
    String sid,
    String text, {
    List<Map<String, dynamic>>? attachments,
    bool steer = false,
  }) => _exclusive(() async {
    await _load();
    if (_erased) throw StateError('无痕会话已关闭，输入未发送');
    if (_entries.length >= 100) {
      throw StateError('待送达消息已满，请先处理现有消息');
    }
    final random = Random.secure();
    final id =
        'msg_${base64Url.encode(List.generate(24, (_) => random.nextInt(256))).replaceAll('=', '')}';
    final entry = <String, dynamic>{
      'client_message_id': id,
      'sid': sid,
      'text': text,
      if (steer) 'type': 'steer',
      if (attachments != null && attachments.isNotEmpty)
        'attachments': jsonDecode(jsonEncode(attachments)),
    };
    _entries[id] = entry;
    try {
      await _persist();
    } catch (_) {
      _entries.remove(id);
      rethrow;
    }
    return Map<String, dynamic>.from(entry);
  });

  Future<List<Map<String, dynamic>>> pending(String sid) =>
      _exclusive(() async {
        await _load();
        if (_erased) return <Map<String, dynamic>>[];
        return _entries.values
            .where((e) => e['sid'] == sid && e['rejected'] != true)
            .map(Map<String, dynamic>.from)
            .toList();
      });

  Future<void> acknowledge(String sid, String id) => _exclusive(() async {
    await _load();
    final entry = _entries[id];
    if (entry == null || entry['sid'] != sid) return;
    _entries.remove(id);
    try {
      await _persist();
    } catch (_) {
      _entries[id] = entry;
      rethrow;
    }
  });

  Future<void> reject(String sid, String id) => _exclusive(() async {
    await _load();
    final entry = _entries[id];
    if (entry == null || entry['sid'] != sid) return;
    entry['rejected'] = true;
    await _persist();
  });

  void clearMemory() {
    if (memoryOnly) {
      _erased = true;
      _entries.clear();
    }
  }
}
