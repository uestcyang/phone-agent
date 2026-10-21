import 'dart:async';
import 'constants.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_credentials.dart';

class PaiBackendException implements Exception {
  final String message;
  PaiBackendException(this.message);
  @override
  String toString() => message;
}

const String _paiHost = kDefaultHost;
const int _paiPort = kDefaultPort;
const Duration _paiTimeout = Duration(seconds: 6);

class PaiItem {
  final String id;
  final String label;
  final String role;
  final String machine;
  final String state;
  final int? startedEpoch;
  final int? endedEpoch;
  final int? ageSec;
  final int? lastWriteSec;
  final String? summary;
  final String? failReason;

  const PaiItem({
    required this.id,
    required this.label,
    required this.role,
    required this.machine,
    required this.state,
    this.startedEpoch,
    this.endedEpoch,
    this.ageSec,
    this.lastWriteSec,
    this.summary,
    this.failReason,
  });

  factory PaiItem.fromJson(Map<String, dynamic> j) => PaiItem(
    id: j['id'] as String? ?? '',
    label: j['label'] as String? ?? (j['id'] as String? ?? '?'),
    role: j['role'] as String? ?? '',
    machine: j['machine'] as String? ?? '',
    state: j['state'] as String? ?? '',
    startedEpoch: (j['started_epoch'] as num?)?.toInt(),
    endedEpoch: (j['ended_epoch'] as num?)?.toInt(),
    ageSec: (j['age_sec'] as num?)?.toInt(),
    lastWriteSec: (j['last_write_sec'] as num?)?.toInt(),
    summary: j['summary'] as String?,
    failReason: j['fail_reason'] as String?,
  );
}

class PaiStreamResult {
  final bool ok;
  final String id;
  final List<String> lines;
  final bool truncated;
  final int totalBytes;

  const PaiStreamResult({
    required this.ok,
    required this.id,
    required this.lines,
    required this.truncated,
    required this.totalBytes,
  });
}

class PaiLedgerClient {
  static Uri _uri(String path, [Map<String, String>? qp]) =>
      Uri.http('$_paiHost:$_paiPort', path, qp);

  static Future<Map<String, String>> _headers() async {
    final tok = await DeviceCredentials.load(_paiHost, _paiPort) ?? '';
    return {'Authorization': 'Bearer $tok', 'Content-Type': 'application/json'};
  }

  static Never _fail(int? statusCode, [String? detail]) {
    throw PaiBackendException(
      statusCode == null
          ? '后端未就绪（超时）'
          : '后端未就绪（$statusCode${detail != null ? ' $detail' : ''}）',
    );
  }

  static Future<List<PaiItem>> fetchList(String state, {int limit = 30}) async {
    final uri = _uri('/pai/list', {'state': state, 'limit': '$limit'});
    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: await _headers())
          .timeout(_paiTimeout);
    } catch (_) {
      _fail(null);
    }
    if (resp.statusCode != 200) _fail(resp.statusCode);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      _fail(resp.statusCode, '响应格式异常');
    }
    final items = body['items'] as List<dynamic>?;
    if (items == null) _fail(resp.statusCode, '缺少 items 字段');
    return items
        .whereType<Map>()
        .map((e) => PaiItem.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  static Future<PaiStreamResult> fetchStream(String id, {int tail = 80}) async {
    final uri = _uri('/pai/stream', {'id': id, 'tail': '$tail'});
    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: await _headers())
          .timeout(_paiTimeout);
    } catch (_) {
      _fail(null);
    }
    if (resp.statusCode != 200) _fail(resp.statusCode);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      _fail(resp.statusCode, '响应格式异常');
    }
    return PaiStreamResult(
      ok: body['ok'] == true,
      id: body['id'] as String? ?? id,
      lines: ((body['lines'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      truncated: body['truncated'] == true,
      totalBytes: (body['total_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<int> ack({List<String>? ids, bool allDone = false}) async {
    final uri = allDone
        ? _uri('/pai/ack', {'all_done': '1'})
        : _uri('/pai/ack', {'ids': (ids ?? const []).join(',')});
    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: await _headers())
          .timeout(_paiTimeout);
    } catch (_) {
      _fail(null);
    }
    if (resp.statusCode != 200) _fail(resp.statusCode);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      _fail(resp.statusCode, '响应格式异常');
    }
    if (body['ok'] != true) throw PaiBackendException('ack 未成功');
    return (body['acked'] as num?)?.toInt() ?? 0;
  }

  static Future<String> ask({required String id, required String role}) async {
    final uri = _uri('/pai/ask', {'id': id, 'role': role});
    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: await _headers())
          .timeout(_paiTimeout);
    } catch (_) {
      _fail(null);
    }
    if (resp.statusCode != 200) _fail(resp.statusCode);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      _fail(resp.statusCode, '响应格式异常');
    }
    if (body['ok'] != true) throw PaiBackendException('ask 未成功');
    return body['prefill'] as String? ?? '';
  }

  static Future<PaiRetryResult> retry({required String id}) async {
    final uri = _uri('/pai/retry', {'id': id});
    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: await _headers())
          .timeout(_paiTimeout);
    } catch (_) {
      _fail(null);
    }
    if (resp.statusCode != 200) _fail(resp.statusCode);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      _fail(resp.statusCode, '响应格式异常');
    }
    return PaiRetryResult(
      ok: body['ok'] == true,
      newId: body['new_id'] as String?,
      error: body['error'] as String?,
    );
  }
}

class PaiRetryResult {
  final bool ok;
  final String? newId;
  final String? error;

  const PaiRetryResult({required this.ok, this.newId, this.error});
}
