import 'dart:convert';
import 'constants.dart';

import 'device_credentials.dart';
import 'transport_routes.dart';

enum AgentKind { phoneDemo, agentApi }

class AgentSpec {
  final String id;
  final String displayName;
  final AgentKind kind;
  final String host;
  final int port;
  final String? apiKey;
  final String? note;
  final String? machine;
  final String? model;
  final bool enabled;
  final bool forceIncognito;
  final bool legacy;
  final bool? alive;

  const AgentSpec({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.host,
    required this.port,
    this.apiKey,
    this.note,
    this.machine,
    this.model,
    this.enabled = true,
    this.forceIncognito = false,
    this.legacy = false,
    this.alive,
  });

  AgentSpec copyWith({
    String? host,
    int? port,
    String? note,
    bool? alive,
    String? model,
  }) => AgentSpec(
    id: id,
    displayName: displayName,
    kind: kind,
    host: host ?? this.host,
    port: port ?? this.port,
    apiKey: apiKey,
    note: note ?? this.note,
    machine: machine,
    model: model ?? this.model,
    enabled: enabled,
    forceIncognito: forceIncognito,
    legacy: legacy,
    alive: alive ?? this.alive,
  );
}

/// The open-source build starts with one user-configured endpoint.
const List<AgentSpec> kAgentRegistryFallback = [
  AgentSpec(
    id: 'agent_a',
    displayName: 'Agent',
    kind: AgentKind.phoneDemo,
    host: kDefaultHost,
    port: kDefaultPort,
    note: 'Configure a server endpoint and pair this device.',
  ),
];

class AgentRegistry {
  static Future<List<AgentSpec>> discover({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final byId = <String, AgentSpec>{
      for (final s in kAgentRegistryFallback) s.id: s,
    };
    final triedHosts = <String>{};
    for (final base in kAgentRegistryFallback) {
      if (!base.enabled || base.id == 'agent_cron') continue;
      if (!triedHosts.add(base.host)) continue;
      try {
        final tok = await DeviceCredentials.load(base.host, base.port) ?? '';
        if (tok.isEmpty) continue;
        final resp = await TransportRoutes.instance.get(
          base.host,
          base.port,
          '/roles',
          headers: {'Authorization': 'Bearer $tok'},
          timeout: timeout,
        );
        if (resp.statusCode != 200) continue;
        final body = jsonDecode(resp.body);
        final list = (body is Map ? body['roles'] : body) as List<dynamic>?;
        if (list == null) continue;
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final name = m['name'] as String?;
          if (name == null || name == 'agent_cron') continue;
          final port = (m['port'] as num?)?.toInt();
          final alive = m['alive'] == true;
          final existing = byId[name];
          if (existing == null) continue;

          final srvModel = m['model'] as String?;
          byId[name] = existing.copyWith(
            port: port,
            alive: alive,
            model: (srvModel != null && srvModel.isNotEmpty) ? srvModel : null,
          );
        }
      } catch (_) {
        continue;
      }
    }

    await Future.wait(
      byId.keys.toList().map((id) async {
        final agent = byId[id]!;
        if (!agent.enabled || agent.id == 'agent_cron') return;
        try {
          final token = await DeviceCredentials.load(agent.host, agent.port);
          if (token == null || token.isEmpty) return;
          final response = await TransportRoutes.instance.get(
            agent.host,
            agent.port,
            '/healthz',
            headers: {'Authorization': 'Bearer $token'},
            timeout: timeout,
          );
          if (response.statusCode != 200) return;
          final health = jsonDecode(response.body);
          if (health is! Map) return;
          final liveModel = health['model'];
          if (liveModel is String && liveModel.isNotEmpty) {
            byId[id] = agent.copyWith(model: liveModel);
          }
        } catch (_) {}
      }),
    );
    return byId.values.toList(growable: false);
  }
}

AgentSpec? adjacentAgent(
  String currentId, {
  required bool next,
  List<AgentSpec> list = kAgentRegistryFallback,
}) {
  final enabled = list.where((a) => a.enabled).toList(growable: false);
  if (enabled.length < 2) return null;
  final i = enabled.indexWhere((a) => a.id == currentId);
  if (i < 0) return null;
  return enabled[(i + (next ? 1 : -1) + enabled.length) % enabled.length];
}

const Map<String, String> kRetiredAgentSuccessor = {};

AgentSpec? resolveAgent(
  String? agentId, {
  List<AgentSpec> list = kAgentRegistryFallback,
}) {
  if (agentId == null || agentId.isEmpty) return null;
  final id = kRetiredAgentSuccessor[agentId] ?? agentId;
  for (final a in list) {
    if (a.id == id && a.enabled) return a;
  }
  return null;
}

const List<AgentSpec> kAgentRegistry = kAgentRegistryFallback;
