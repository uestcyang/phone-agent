import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'device_credentials.dart';
import 'backend_identity.dart';
import 'transport_routes.dart';

class PendingPairing {
  final String agentId;
  final String displayName;
  final String host;
  final int port;
  final String code;
  final DateTime expiresAt;
  PendingPairing({
    required this.agentId,
    required this.displayName,
    required this.host,
    required this.port,
    required this.code,
    required this.expiresAt,
  });
}

class PairingManager {
  static final Map<String, PendingPairing> pending = {};

  static final Map<String, Future<String?>> _inFlight = {};
  static final _listeners = <void Function()>[];

  static void addListener(void Function() cb) => _listeners.add(cb);
  static void removeListener(void Function() cb) => _listeners.remove(cb);
  static void _notify() {
    for (final cb in List<void Function()>.of(_listeners)) {
      cb();
    }
  }

  static String _key(String host, int port) =>
      BackendIdentity.credentialKey(host, port);

  static Future<String?> ensureToken(
    String agentId,
    String displayName,
    String host,
    int port,
  ) async {
    final existing = await DeviceCredentials.load(host, port);
    if (existing != null && existing.isNotEmpty) return existing;

    final key = _key(host, port);
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;
    final future = _requestAndPoll(agentId, displayName, host, port, key);
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  static Future<String?> _requestAndPoll(
    String agentId,
    String displayName,
    String host,
    int port,
    String key,
  ) async {
    try {
      final reqResp = await TransportRoutes.instance.get(
        host,
        port,
        '/pair/request',
      );
      if (reqResp.statusCode != 200) return null;
      final reqJson = jsonDecode(reqResp.body) as Map<String, dynamic>;
      final pairingId = reqJson['pairing_id'] as String;
      final code = reqJson['code'] as String;
      final expiresIn = (reqJson['expires_in'] as num?)?.toInt() ?? 300;
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

      pending[key] = PendingPairing(
        agentId: agentId,
        displayName: displayName,
        host: host,
        port: port,
        code: code,
        expiresAt: expiresAt,
      );
      _notify();
      developer.log(
        '配对码($displayName @ $host:$port): $code，有效期 ${expiresIn}s',
        name: 'pairing',
      );

      while (DateTime.now().isBefore(expiresAt)) {
        await Future.delayed(const Duration(seconds: 4));
        try {
          final pollResp = await TransportRoutes.instance.get(
            host,
            port,
            '/pair/poll?pairing_id=$pairingId',
          );
          if (pollResp.statusCode != 200) continue;
          final pollJson = jsonDecode(pollResp.body) as Map<String, dynamic>;
          if (pollJson['status'] == 'approved') {
            final token = pollJson['token'] as String;
            await DeviceCredentials.save(host, port, token);
            pending.remove(key);
            _notify();
            return token;
          }
        } catch (_) {}
      }
    } catch (_) {}
    pending.remove(key);
    _notify();
    return null;
  }
}
