import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class NetworkEventOutbox {
  final String scope;
  final Directory? directory;
  final Map<String, Map<String, dynamic>> _rows = {};
  Future<void> _serial = Future.value();
  File? _file;
  NetworkEventOutbox(this.scope, {this.directory});
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _load() async {
    if (_file != null) return;
    final root = directory ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/phone_agent_network_events');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${sha256.convert(utf8.encode(scope))}.json');
    if (await file.exists()) {
      for (final raw in jsonDecode(await file.readAsString()) as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        _rows[row['event_id'] as String] = row;
      }
    }
    _file = file;
  }

  Future<void> _persist() async {
    final tmp = File('${_file!.path}.tmp');
    await tmp.writeAsString(jsonEncode(_rows.values.toList()), flush: true);
    await tmp.rename(_file!.path);
  }

  Future<void> add(String kind, String from, String to, {int durationMs = 0}) =>
      _exclusive(() async {
        await _load();

        if (_rows.values.any(
          (r) => r['kind'] == kind && r['from'] == from && r['to'] == to,
        )) {
          return;
        }
        final random = Random.secure();
        final bytes = List.generate(24, (_) => random.nextInt(256));
        final id = 'net_${base64Url.encode(bytes).replaceAll('=', '')}';
        _rows[id] = {
          'event_id': id,
          'kind': kind,
          'from': from,
          'to': to,
          'occurred_ms': DateTime.now().millisecondsSinceEpoch,
          'duration_ms': durationMs,
        };
        try {
          await _persist();
        } catch (_) {
          _rows.remove(id);
          rethrow;
        }
      });
  Future<List<Map<String, dynamic>>> pending() => _exclusive(() async {
    await _load();
    return _rows.values.map(Map<String, dynamic>.from).toList();
  });
  Future<void> acknowledge(String id, {required bool durable}) =>
      _exclusive(() async {
        if (!durable) return;
        await _load();
        final old = _rows.remove(id);
        if (old == null) return;
        try {
          await _persist();
        } catch (_) {
          _rows[id] = old;
          rethrow;
        }
      });
}
