import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'backend_identity.dart';
import 'transport_routes.dart';
import 'constants.dart';

class DeviceCredentials {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _cache = {};

  static String _cacheKey(String host, int port) =>
      BackendIdentity.credentialKey(host, port);
  static String _storageKey(String host, int port) =>
      BackendIdentity.credentialKey(host, port);

  static String? peek(String host, int port) => _cache[_cacheKey(host, port)];

  static Future<String?> load(String host, int port) async {
    final ck = _cacheKey(host, port);
    final cached = _cache[ck];
    if (cached != null) return cached;
    var v = await _storage.read(key: _storageKey(host, port));

    if (v != null && v.isNotEmpty) _cache[ck] = v;
    return v;
  }

  static Future<void> save(String host, int port, String token) async {
    _cache[_cacheKey(host, port)] = token;
    await _storage.write(key: _storageKey(host, port), value: token);
  }

  static Future<void> clear(String host, int port) async {
    _cache.remove(_cacheKey(host, port));
    await _storage.delete(key: _storageKey(host, port));
  }
}

String tokenFor(String host, int port) =>
    DeviceCredentials.peek(host, port) ?? '';

class WidgetTokenMirror {
  static const _channel = MethodChannel('org.phoneagent.app/widget_token');

  static Future<void> publish(String token) async {
    try {
      await _channel.invokeMethod('publish', {
        'token': token,
        'wallet_token': '',
        'summary_url': backendUri(
          kDefaultHost,
          kDefaultPort,
          '/widget_summary',
        ).toString(),
        'ack_url': backendUri(
          kDefaultHost,
          kDefaultPort,
          '/pai/ack',
        ).toString(),
      });
    } catch (_) {}
  }

  static Future<void> refresh() async {
    try {
      await _channel.invokeMethod('refresh');
    } catch (_) {}
  }
}
