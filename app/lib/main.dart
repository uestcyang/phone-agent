import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_registry.dart';
import 'avatar_store.dart';
import 'background_store.dart';
import 'chat_page.dart';
import 'task_summary_menu.dart';
import 'pai_ledger_page.dart';
import 'keepalive_bootstrap.dart';
import 'local_store.dart';
import 'incoming_share.dart';
import 'incoming_share_dialog.dart';
import 'backup_ingress_proxy.dart';
import 'transport_routes.dart';

const MethodChannel _routingChannel = MethodChannel(
  'org.phoneagent.app/routing',
);
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

AgentSpec? _findAgent(String? agentId) => resolveAgent(agentId);

void _handleRoutePush(MethodCall call) {
  if (call.method != 'routePush') return;
  final args = call.arguments;
  if (args is! Map) return;
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  final tab = args['tab'] as String?;
  if (tab != null && tab.isNotEmpty) {
    nav.push(
      MaterialPageRoute(
        builder: (_) => ownerTaskSummaryEnabled
            ? ChatPage(agent: kAgentRegistryFallback.first, initialTaskTab: tab)
            : PaiLedgerPage(initialTab: tab),
      ),
    );
    return;
  }
  final agent = _findAgent(args['agent_id'] as String?);
  if (agent != null) {
    nav.push(MaterialPageRoute(builder: (_) => ChatPage(agent: agent)));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackupIngressProxy.install(TransportRoutes.instance.backupOrigin);
  await loadChatBackground();

  await AgentAvatarStore.loadAll(kAgentRegistryFallback.map((a) => a.id));

  unawaited(KeepAliveBootstrap.start());

  AgentSpec? initialAgent;
  String? initialTab;
  try {
    final raw = await _routingChannel.invokeMethod('consumeInitialRoute');
    if (raw is Map) {
      initialTab = raw['tab'] as String?;
      initialAgent = _findAgent(raw['agent_id'] as String?);
    }
  } catch (_) {
    initialAgent = null;
    initialTab = null;
  }

  if (initialAgent == null && (initialTab == null || initialTab.isEmpty)) {
    final lastId = await LocalStore.loadLastAgentId();
    initialAgent = _findAgent(lastId) ?? kAgentRegistryFallback.first;
  }
  _routingChannel.setMethodCallHandler((call) async => _handleRoutePush(call));

  runApp(PhoneAgentApp(initialAgent: initialAgent, initialTab: initialTab));
}

class PhoneAgentApp extends StatefulWidget {
  final AgentSpec? initialAgent;
  final String? initialTab;
  const PhoneAgentApp({super.key, this.initialAgent, this.initialTab});

  @override
  State<PhoneAgentApp> createState() => _PhoneAgentAppState();
}

class _PhoneAgentAppState extends State<PhoneAgentApp>
    with WidgetsBindingObserver {
  bool _shareBusy = false;
  bool _shareCheckAgain = false;
  final Set<String> _offeredShares = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    IncomingShareInbox.channel.setMethodCallHandler((call) async {
      if (call.method == 'available') {
        unawaited(_checkShares());
      } else if (call.method == 'importFailed') {
        final context = rootNavigatorKey.currentContext;
        if (context != null && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('${call.arguments}')));
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkShares()),
    );
    unawaited(_publishShareTargets());
  }

  Future<void> _publishShareTargets() async {
    try {
      final lastId = await LocalStore.loadLastAgentId();
      final agents = kAgentRegistryFallback
          .where((a) => a.enabled && a.id != 'agent_cron')
          .toList();
      final recent = agents.where((a) => a.id == lastId).toList();
      await IncomingShareInbox.publishTargets([
        ...recent,
        ...agents.where((a) => a.id != lastId),
      ]);
    } on MissingPluginException {
    } on PlatformException {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkShares());
    }
  }

  Future<void> _checkShares() async {
    if (!mounted) return;
    if (_shareBusy) {
      _shareCheckAgain = true;
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _shareBusy = true;
    _shareCheckAgain = false;
    try {
      while (mounted) {
        final queue = await IncomingShareInbox.pending();
        final fresh = queue
            .where((s) => !_offeredShares.contains(s.id))
            .toList();
        if (fresh.isEmpty || !mounted) break;
        final share = fresh.first;
        final context = rootNavigatorKey.currentContext;
        if (context == null || !context.mounted) break;
        _offeredShares.add(share.id);
        final lastId = await LocalStore.loadLastAgentId();
        if (!context.mounted) break;
        final agents = kAgentRegistryFallback
            .where((a) => a.enabled && a.id != 'agent_cron')
            .toList();
        final decision =
            share.directTarget(agents) ??
            await showDialog<Object>(
              context: context,
              barrierDismissible: false,
              builder: (_) => IncomingShareDialog(
                share: share,
                initialAgentId: share.targetAgentId ?? lastId,
                agents: agents,
              ),
            );
        if (decision == false) {
          await IncomingShareInbox.discard(share.id);
        } else if (decision is AgentSpec) {
          final open = IncomingShareInbox.openDraft;
          if (open != null) {
            await open(decision, share);
          } else {
            rootNavigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (_) => ChatPage(agent: decision, incomingShare: share),
              ),
            );
          }
        } else {
          _offeredShares.remove(share.id);
          break;
        }
      }
    } on MissingPluginException {
    } catch (e) {
      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('分享未完成，内容已保留：$e')));
      }
    } finally {
      _shareBusy = false;
      if (_shareCheckAgain && mounted) unawaited(_checkShares());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    IncomingShareInbox.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (widget.initialTab != null && widget.initialTab!.isNotEmpty) {
      home = ownerTaskSummaryEnabled
          ? ChatPage(
              agent: widget.initialAgent ?? kAgentRegistryFallback.first,
              initialTaskTab: widget.initialTab!,
            )
          : PaiLedgerPage(initialTab: widget.initialTab!);
    } else {
      final agent = widget.initialAgent ?? kAgentRegistryFallback.first;
      home = ChatPage(agent: agent);
    }
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: '手机Agent',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
