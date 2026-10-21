import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_registry.dart';
import 'background_store.dart';
import 'chat_page.dart';
import 'device_credentials.dart';
import 'pai_ledger_client.dart';
import 'pai_stream_page.dart';

class PaiLedgerPage extends StatefulWidget {
  final String initialTab;
  const PaiLedgerPage({super.key, this.initialTab = 'running'});

  @override
  State<PaiLedgerPage> createState() => _PaiLedgerPageState();
}

class _PaiLedgerPageState extends State<PaiLedgerPage>
    with SingleTickerProviderStateMixin {
  static const _states = ['running', 'done', 'failed'];
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    final idx = _states.indexOf(widget.initialTab);
    _tabCtrl = TabController(
      length: _states.length,
      vsync: this,
      initialIndex: idx < 0 ? 0 : idx,
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BackgroundScaffold(
      appBar: AppBar(
        title: const Text('任务台账'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: '工作中'),
            Tab(text: '已完成'),
            Tab(text: '已失败'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _PaiListView(state: 'running'),
          _PaiListView(state: 'done'),
          _PaiListView(state: 'failed'),
        ],
      ),
    );
  }
}

class _PaiListView extends StatefulWidget {
  final String state;
  const _PaiListView({required this.state});

  @override
  State<_PaiListView> createState() => _PaiListViewState();
}

class _PaiListViewState extends State<_PaiListView>
    with AutomaticKeepAliveClientMixin {
  List<PaiItem>? _items;
  String? _error;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await PaiLedgerClient.fetchList(widget.state);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  AgentSpec? _agentForRole(String role) {
    for (final a in kAgentRegistryFallback) {
      if (a.id == role) return a;
    }
    return null;
  }

  void _openChat(String role, {String? prefill}) {
    final agent = _agentForRole(role);
    if (agent == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('找不到角色: $role')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(agent: agent, prefillText: prefill),
      ),
    );
  }

  void _openStream(PaiItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PaiStreamPage(taskId: item.id, label: item.label),
      ),
    );
  }

  Future<void> _ackOne(PaiItem item) async {
    final items = _items;
    if (items == null) return;
    final idx = items.indexOf(item);
    if (idx < 0) return;
    setState(() => items.removeAt(idx));
    try {
      await PaiLedgerClient.ack(ids: [item.id]);

      unawaited(WidgetTokenMirror.refresh());
    } catch (e) {
      if (!mounted) return;
      setState(() => items.insert(idx, item));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清除失败，已还原：$e')));
    }
  }

  Future<void> _retryOne(PaiItem item) async {
    final items = _items;
    if (items == null) return;
    final idx = items.indexOf(item);
    if (idx < 0) return;
    setState(() => items.removeAt(idx));
    try {
      final result = await PaiLedgerClient.retry(id: item.id);
      if (!result.ok) {
        if (!mounted) return;
        setState(() => items.insert(idx, item));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重派失败：${result.error ?? "未知原因"}')),
        );
        return;
      }
      if (!mounted) return;
      unawaited(WidgetTokenMirror.refresh());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已重派：${item.label}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => items.insert(idx, item));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重派失败，已还原：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final items = _items ?? const [];
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('暂无任务', style: TextStyle(color: Colors.grey)),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final item = items[i];
          return _PaiCard(
            item: item,
            state: widget.state,
            onTapName: () => _openChat(item.role),
            onStream: () => _openStream(item),
            onAck: () => _ackOne(item),
            onRetry: () => _retryOne(item),
          );
        },
      ),
    );
  }
}

class _PaiCard extends StatelessWidget {
  final PaiItem item;
  final String state;
  final VoidCallback onTapName;
  final VoidCallback onStream;
  final VoidCallback onAck;
  final VoidCallback onRetry;

  const _PaiCard({
    required this.item,
    required this.state,
    required this.onTapName,
    required this.onStream,
    required this.onAck,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTapName,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.role} · ${item.machine}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if ((item.summary ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.summary!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                    if (state == 'failed' &&
                        (item.failReason ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.failReason!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 12),
              _actionButton(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(BuildContext context) {
    switch (state) {
      case 'running':
        return _actionCircle(
          label: 'D',
          color: Colors.blue,
          onTap: onStream,
          tooltip: '查看输出流',
        );
      case 'done':
        return _actionCircle(
          label: '❌',
          color: Colors.green,
          onTap: onAck,
          tooltip: '清除',
        );
      case 'failed':
        return _actionCircle(
          label: '↻',
          color: Colors.redAccent,
          onTap: onRetry,
          tooltip: '重派',
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _actionCircle({
    required String label,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color.withValues(alpha: 0.15),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
