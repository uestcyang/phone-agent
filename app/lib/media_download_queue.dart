import 'transport_routes.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_credentials.dart';
import 'models.dart';

class MediaStorageAccess {
  static const _channel = MethodChannel('org.phoneagent.app/permissions');

  static Future<bool> hasManageExternalStorage() async {
    try {
      return (await _channel.invokeMethod<bool>('hasManageExternalStorage')) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestManageExternalStorage() async {
    try {
      await _channel.invokeMethod('requestManageExternalStorage');
    } catch (_) {}
  }

  static Future<bool> openFolder(String path) async {
    try {
      return (await _channel.invokeMethod<bool>('openFolder', {
            'path': path,
          })) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

enum MediaDownloadStatus { idle, queued, downloading, done, failed, removed }

class MediaDownloadState {
  final MediaDownloadStatus status;
  final double progress;
  final String? localPath;
  final int attempt;
  final String? error;
  final bool syncFolderWritable;

  const MediaDownloadState({
    required this.status,
    this.progress = -1,
    this.localPath,
    this.attempt = 0,
    this.error,
    this.syncFolderWritable = true,
  });
}

class _PendingItem {
  final MediaAttachment att;
  final String host;
  final int port;
  int attempt;

  _PendingItem(this.att, this.host, this.port, {this.attempt = 0});

  Map<String, dynamic> toJson() => {
    ...att.toJson(),
    'host': host,
    'port': port,
    'attempt': attempt,
  };

  static _PendingItem fromJson(Map<String, dynamic> j) => _PendingItem(
    MediaAttachment.fromJson(j),
    (j['host'] ?? '') as String,
    (j['port'] as num?)?.toInt() ?? 0,
    attempt: (j['attempt'] as num?)?.toInt() ?? 0,
  );
}

class MediaDownloadQueue extends ChangeNotifier {
  MediaDownloadQueue._();
  static final MediaDownloadQueue instance = MediaDownloadQueue._();

  static const _prefsPendingKey = 'media_dlq_pending_v1';
  static const _prefsLocalPathPrefix = 'media_dlq_localpath_';
  static const int _maxConcurrent = 2;
  static const int _maxBackoffSeconds = 60;

  static const int _maxAttempts = 5;

  bool _loaded = false;
  bool? _syncFolderWritableCache;
  final Map<String, _PendingItem> _pending = {};
  final Map<String, MediaDownloadState> _states = {};
  final Set<String> _active = {};

  String _key(MediaAttachment a) => a.sha256.isNotEmpty ? a.sha256 : a.url;

  MediaDownloadState stateFor(MediaAttachment a) =>
      _states[_key(a)] ??
      const MediaDownloadState(status: MediaDownloadStatus.idle);

  Future<void> ensureStarted() async {
    await _ensureLoaded();
    _pump();
  }

  Future<void> enqueueAll(
    List<MediaAttachment> atts, {
    required String host,
    required int port,
  }) async {
    await _ensureLoaded();
    for (final a in atts) {
      await _enqueueOne(a, host: host, port: port);
    }
    _pump();
  }

  Future<void> enqueue(
    MediaAttachment a, {
    required String host,
    required int port,
  }) async {
    await _ensureLoaded();
    await _enqueueOne(a, host: host, port: port);
    _pump();
  }

  Future<void> retry(
    MediaAttachment a, {
    required String host,
    required int port,
  }) async {
    await _ensureLoaded();
    final key = _key(a);
    _pending[key] = _PendingItem(a, host, port, attempt: 0);
    await _persistPending();
    _setState(
      key,
      const MediaDownloadState(status: MediaDownloadStatus.queued),
    );
    _pump();
  }

  Future<void> _enqueueOne(
    MediaAttachment a, {
    required String host,
    required int port,
  }) async {
    final key = _key(a);

    if (_pending.containsKey(key) || _active.contains(key)) return;
    final known = await _localPathFor(key);
    if (known != null) {
      if (await File(known).exists()) {
        _setState(
          key,
          MediaDownloadState(
            status: MediaDownloadStatus.done,
            localPath: known,
            progress: 1,
          ),
        );
      } else {
        _setState(
          key,
          const MediaDownloadState(status: MediaDownloadStatus.removed),
        );
      }
      return;
    }
    _pending[key] = _PendingItem(a, host, port);
    await _persistPending();
    _setState(
      key,
      const MediaDownloadState(status: MediaDownloadStatus.queued),
    );
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPendingKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final j in list) {
        final item = _PendingItem.fromJson(j);
        final key = _key(item.att);
        final known = await _localPathFor(key);
        if (known != null && await File(known).exists()) continue;
        _pending[key] = item;
        if (item.attempt >= _maxAttempts) {
          _setState(
            key,
            MediaDownloadState(
              status: MediaDownloadStatus.failed,
              attempt: item.attempt,
              error: '重试已达上限($_maxAttempts 次)，点击重试',
            ),
          );
        } else {
          _setState(
            key,
            const MediaDownloadState(status: MediaDownloadStatus.queued),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _persistPending() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _pending.values.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsPendingKey, jsonEncode(list));
  }

  Future<String?> _localPathFor(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefsLocalPathPrefix$key');
  }

  Future<void> _saveLocalPath(String key, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefsLocalPathPrefix$key', path);
  }

  void _setState(String key, MediaDownloadState s) {
    _states[key] = s;
    notifyListeners();
  }

  void _pump() {
    if (_active.length >= _maxConcurrent) return;
    final next = _pending.entries
        .where(
          (e) => !_active.contains(e.key) && e.value.attempt < _maxAttempts,
        )
        .map((e) => e.key)
        .toList();
    for (final key in next) {
      if (_active.length >= _maxConcurrent) break;
      final item = _pending[key];
      if (item == null) continue;
      _active.add(key);
      unawaited(_download(key, item));
    }
  }

  Future<Directory> _targetDir() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeName(String name) {
    final base = name.split('/').last.split('\\').last;
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._一-鿿-]'), '_');
    return safe.isEmpty ? 'file.bin' : safe;
  }

  Future<void> _download(String key, _PendingItem item) async {
    final a = item.att;
    final writable =
        _syncFolderWritableCache ??
        await MediaStorageAccess.hasManageExternalStorage();
    _setState(
      key,
      MediaDownloadState(
        status: MediaDownloadStatus.downloading,
        attempt: item.attempt,
        syncFolderWritable: writable,
      ),
    );
    try {
      final dir = await _targetDir();
      final finalPath = '${dir.path}/${_safeName(a.name)}';
      final partPath = '$finalPath.part';
      final partFile = File(partPath);
      final offset = await partFile.exists() ? await partFile.length() : 0;

      final uri = backendUri(item.host, item.port, a.url);
      final req = http.Request('GET', uri)..followRedirects = false;
      if (offset > 0) req.headers['Range'] = 'bytes=$offset-';

      final token = tokenFor(item.host, item.port);
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      final client = http.Client();
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 20));
      if (streamed.statusCode != 200 && streamed.statusCode != 206) {
        client.close();
        throw Exception('HTTP ${streamed.statusCode}');
      }
      final append = offset > 0 && streamed.statusCode == 206;
      final sink = partFile.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = append ? offset : 0;
      final total = a.size > 0 ? a.size : null;
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null) {
          _setState(
            key,
            MediaDownloadState(
              status: MediaDownloadStatus.downloading,
              progress: (received / total).clamp(0, 1).toDouble(),
              attempt: item.attempt,
              syncFolderWritable: writable,
            ),
          );
        }
      }
      await sink.flush();
      await sink.close();
      client.close();

      if (a.sha256.isNotEmpty) {
        final digest = await sha256.bind(partFile.openRead()).first;
        if (digest.toString() != a.sha256) {
          await partFile.delete();
          throw Exception('sha256 mismatch');
        }
      }
      await partFile.rename(finalPath);
      _pending.remove(key);
      _active.remove(key);
      await _persistPending();
      await _saveLocalPath(key, finalPath);
      _setState(
        key,
        MediaDownloadState(
          status: MediaDownloadStatus.done,
          localPath: finalPath,
          progress: 1,
          syncFolderWritable: writable,
        ),
      );
    } catch (e) {
      _active.remove(key);
      item.attempt += 1;
      _pending[key] = item;
      await _persistPending();
      final exhausted = item.attempt >= _maxAttempts;
      _setState(
        key,
        MediaDownloadState(
          status: MediaDownloadStatus.failed,
          attempt: item.attempt,
          error: exhausted
              ? '${e.toString()}(已重试 ${item.attempt} 次，达上限，点击重试)'
              : e.toString(),
          syncFolderWritable: writable,
        ),
      );
      if (!exhausted) {
        final backoff = (1 << item.attempt).clamp(1, _maxBackoffSeconds);
        Timer(Duration(seconds: backoff), () {
          if (_pending.containsKey(key)) {
            _setState(
              key,
              MediaDownloadState(
                status: MediaDownloadStatus.queued,
                attempt: item.attempt,
                syncFolderWritable: writable,
              ),
            );
            _pump();
          }
        });
      }
    } finally {
      _pump();
    }
  }
}
