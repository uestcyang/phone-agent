import 'dart:async';
import 'package:http/http.dart' as http;
import 'backend_identity.dart';

enum TransportPath { vps, standby, direct }

class _RouteState {
  TransportPath path = TransportPath.vps;
  int failures = 0;
  DateTime? retryPublicAfter;
}

class TransportRoutes {
  static const configuredOrigin = String.fromEnvironment(
    'PA_PUBLIC_ORIGIN',
    defaultValue: '',
  );
  static const configuredBackupOrigin = String.fromEnvironment(
    'PA_BACKUP_ORIGIN',
    defaultValue: '',
  );
  static const _profile = 'default';
  static final instance = TransportRoutes(
    origin: configuredOrigin,
    backupOrigin: configuredBackupOrigin,
    profile: _profile,
  );
  final Uri? origin;
  final Uri? backupOrigin;
  final DateTime Function() clock;
  final Map<String, _RouteState> _states = {};

  TransportRoutes({
    String origin = '',
    String backupOrigin = '',
    String profile = 'default',
    DateTime Function()? clock,
  }) : origin = profile == 'default' ? _validated(origin) : null,
       backupOrigin = profile == 'default' && origin.isNotEmpty
           ? _validated(backupOrigin, backup: true)
           : null,
       clock = clock ?? DateTime.now;

  static Uri? _validated(String value, {bool backup = false}) {
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        (uri.port != 443 && !(backup && uri.port == 8443)) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError(
        'Ingress must be a plain HTTPS origin on an allowed TLS port',
      );
    }
    return uri.replace(path: '');
  }

  bool supports(String host, int port) =>
      origin != null && BackendIdentity.role(host, port) != null;
  bool supportsStandby(String host, int port) =>
      supports(host, port) && backupOrigin != null;
  _RouteState _state(String host, int port) =>
      _states.putIfAbsent(BackendIdentity.role(host, port)!, _RouteState.new);
  TransportPath path(String host, int port) =>
      supports(host, port) ? _state(host, port).path : TransportPath.direct;

  void networkChanged(String host, int port) {
    if (!supports(host, port)) return;
    final s = _state(host, port);
    s.path = TransportPath.vps;
    s.failures = 0;
    s.retryPublicAfter = null;
  }

  Uri uri(
    String host,
    int port,
    String relative, {
    bool upload = false,
    bool websocket = false,
    TransportPath? via,
  }) {
    if (Uri.decodeComponent(
      relative.split('?').first,
    ).split('/').contains('..')) {
      throw ArgumentError('Backend paths cannot contain parent segments');
    }
    final rel = Uri.parse(relative);
    if (rel.hasScheme ||
        rel.hasAuthority ||
        !rel.path.startsWith('/') ||
        rel.pathSegments.any((segment) => segment == '..')) {
      throw ArgumentError('Backend paths must be relative absolute paths');
    }
    final selected = via ?? path(host, port);
    if (selected == TransportPath.standby && !supportsStandby(host, port)) {
      throw ArgumentError('No public standby for this backend');
    }
    if (supports(host, port) && selected != TransportPath.direct) {
      final role = BackendIdentity.role(host, port)!;
      final target = selected == TransportPath.standby
          ? backupOrigin!
          : origin!;
      return target.replace(
        scheme: websocket ? 'wss' : 'https',
        path:
            '/agents/$role${websocket ? '' : '${upload ? '/_upload' : ''}${rel.path}'}',
        query: rel.hasQuery ? rel.query : null,
      );
    }
    return Uri(
      scheme: websocket ? 'ws' : 'http',
      host: host,
      port: upload ? port + 1000 : port,
      path: rel.path,
      query: rel.hasQuery ? rel.query : null,
    );
  }

  Uri websocket(String host, int port) {
    if (supports(host, port)) {
      final s = _state(host, port);
      if (s.path != TransportPath.vps &&
          s.retryPublicAfter != null &&
          !clock().isBefore(s.retryPublicAfter!)) {
        s.path = TransportPath.vps;
        s.failures = 0;
      }
    }
    return uri(host, port, '/ws', websocket: true);
  }

  void connected(String host, int port, Uri attempted) {
    final route = attemptedPath(host, port, attempted);
    if (supports(host, port) && route != null) {
      final s = _state(host, port);
      s.path = route;
      s.failures = 0;
      s.retryPublicAfter = route == TransportPath.vps
          ? null
          : s.retryPublicAfter ?? clock().add(const Duration(minutes: 15));
    }
  }

  TransportPath? attemptedPath(String host, int port, Uri attempted) {
    for (final route in TransportPath.values) {
      if (route == TransportPath.standby && !supportsStandby(host, port)) {
        continue;
      }
      final expected = uri(host, port, '/ws', websocket: true, via: route);
      if (attempted.scheme == expected.scheme &&
          attempted.host == expected.host &&
          attempted.port == expected.port &&
          attempted.path == expected.path) {
        return route;
      }
    }
    return null;
  }

  void failed(
    String host,
    int port,
    Uri attempted, {
    bool authentication = false,
  }) {
    if (!supports(host, port) || authentication) {
      return;
    }
    final s = _state(host, port);
    final attemptedRoute = attemptedPath(host, port, attempted);
    if (attemptedRoute == null || attemptedRoute != s.path) return;

    if (attemptedRoute == TransportPath.direct) {
      s.path = TransportPath.vps;
      s.failures = 0;
      s.retryPublicAfter = null;
      return;
    }
    if (++s.failures >= 2) {
      s.path =
          attemptedRoute == TransportPath.vps && supportsStandby(host, port)
          ? TransportPath.standby
          : TransportPath.direct;
      s.retryPublicAfter = clock().add(const Duration(minutes: 15));
      s.failures = 0;
    }
  }

  Future<http.Response> get(
    String host,
    int port,
    String relative, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    http.Client? client,
  }) async {
    if (RegExp(
      r'^/(pair/(approve|revoke)|pai/(ack|retry)|reset)([/?]|$)',
    ).hasMatch(relative)) {
      throw ArgumentError(
        'Actions must use an explicit transport without automatic retry',
      );
    }
    final own = client == null;
    final c = client ?? http.Client();
    final first = path(host, port);
    final candidates = [
      first,
      if (first == TransportPath.vps && supportsStandby(host, port))
        TransportPath.standby,
      if (first != TransportPath.direct) TransportPath.direct,
    ];
    try {
      for (var i = 0; i < candidates.length; i++) {
        try {
          final response = await _getOnce(
            c,
            uri(host, port, relative, via: candidates[i]),
            headers,
          ).timeout(timeout);
          if (response.statusCode < 502 ||
              response.statusCode > 504 ||
              i + 1 == candidates.length) {
            return response;
          }
        } catch (_) {
          if (i + 1 == candidates.length) rethrow;
        }
      }
      throw StateError('No backend route');
    } finally {
      if (own) c.close();
    }
  }

  static Future<http.Response> _getOnce(
    http.Client client,
    Uri uri,
    Map<String, String>? headers,
  ) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    if (headers != null) request.headers.addAll(headers);
    return http.Response.fromStream(await client.send(request));
  }
}

Uri backendUri(String host, int port, String path, {bool upload = false}) =>
    TransportRoutes.instance.uri(host, port, path, upload: upload);
