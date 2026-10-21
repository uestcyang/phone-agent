import 'dart:async';

import 'agent_registry.dart';
import 'device_credentials.dart';
import 'foreground_service.dart';
import 'models.dart';
import 'mute_settings.dart';
import 'native_push.dart';
import 'pairing.dart';
import 'settings_page.dart' show loadServerAddress;
import 'ws_client.dart';

class KeepAliveBootstrap {
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    _started = true;

    await MuteSettings.instance.load();
    await ForegroundKeepAlive.requestPermissions();
    await ForegroundKeepAlive.start(title: '手机 Agent 在线', text: '正在连接各角色…');

    final agents = kAgentRegistry
        .where((a) => a.enabled && !a.legacy && a.id != 'agent_cron')
        .toList();
    for (final agent in agents) {
      if (agent.id == 'agent_cron') continue;
      unawaited(_connectAgent(agent, agents));
    }

    for (final agent in kAgentRegistry.where((a) => a.enabled && a.legacy)) {
      unawaited(_pairForWidgetOnly(agent));
    }

    WsClientRegistry.onTick = () {
      unawaited(_retryPairingOnTick(agents));
    };
    _onAnyStatusChanged(agents);
  }

  static Future<void> _retryPairingOnTick(List<AgentSpec> agents) async {
    for (final agent in agents) {
      if (agent.id == 'agent_cron') continue;
      if (WsClientRegistry.peek(agent.id) != null) {
        if (agent.id == 'agent_d') {
          unawaited(_republishWidgetToken(agent));
        }

        _bindTurnDone(WsClientRegistry.peek(agent.id)!, agent);
        continue;
      }
      unawaited(_connectAgent(agent, agents));
    }

    for (final agent in kAgentRegistry.where((a) => a.enabled && a.legacy)) {
      unawaited(_pairForWidgetOnly(agent));
    }
  }

  static Future<void> _republishWidgetToken(AgentSpec agent) async {
    final (host, port) = await loadServerAddress(
      agent.id,
      agent.host,
      agent.port,
    );
    final token =
        DeviceCredentials.peek(host, port) ??
        await DeviceCredentials.load(host, port);
    if (token == null || token.isEmpty) return;
    await WidgetTokenMirror.publish(token);
  }

  static Future<void> _connectAgent(
    AgentSpec agent,
    List<AgentSpec> agents,
  ) async {
    final (host, port) = await loadServerAddress(
      agent.id,
      agent.host,
      agent.port,
    );
    final token = await PairingManager.ensureToken(
      agent.id,
      agent.displayName,
      host,
      port,
    );
    if (token == null) {
      return;
    }

    if (agent.id == 'agent_d') {
      unawaited(WidgetTokenMirror.publish(token));
    }
    final client = WsClientRegistry.getOrCreate(
      agent.id,
      host,
      port,
      token,
      alwaysIncognito: agent.forceIncognito,
    );
    client.onPush = (push) async {
      if (push.kind != 'generic') return;

      final silent = await MuteSettings.instance.resolveSilent(
        agentId: agent.id,
        level: push.level,
      );
      NativePush.post(
        agentId: agent.id,
        agentDisplayName: agent.displayName,
        title: push.title.isEmpty ? agent.displayName : push.title,
        body: push.body,
        silent: silent,
      );
    };

    _bindTurnDone(client, agent);
    client.status.addListener(() => _onAnyStatusChanged(agents));
    client.connect();
    _onAnyStatusChanged(agents);
  }

  static void _bindTurnDone(WsClient client, AgentSpec agent) {
    client.onTurnDone = (text) async {
      final looking =
          client.isForeground && WsClientRegistry.activeChatAgentId == agent.id;
      if (looking) return;
      final silent = await MuteSettings.instance.resolveSilent(
        agentId: agent.id,
        level: 'info',
      );

      final body = text.length > 200 ? '${text.substring(0, 200)}…' : text;
      NativePush.post(
        agentId: agent.id,
        agentDisplayName: agent.displayName,
        title: agent.displayName,
        body: body,
        silent: silent,
      );
    };
  }

  static Future<void> _pairForWidgetOnly(AgentSpec agent) async {
    final (host, port) = await loadServerAddress(
      agent.id,
      agent.host,
      agent.port,
    );
    final token = await PairingManager.ensureToken(
      agent.id,
      agent.displayName,
      host,
      port,
    );
    if (token == null) return;
    await WidgetTokenMirror.publish(token);
  }

  static void _onAnyStatusChanged(List<AgentSpec> agents) {
    final connected = agents.where((a) {
      final c = WsClientRegistry.peek(a.id);
      return c?.status.value == ConnStatus.connected;
    }).length;
    unawaited(
      ForegroundKeepAlive.updateStatus(
        title: '手机 Agent 在线',
        text: '已连接 $connected/${agents.length} 个角色',
      ),
    );
  }
}
