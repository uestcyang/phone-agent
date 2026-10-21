import 'package:flutter/material.dart';

import 'ws_client.dart';

class DiagnosticsPage extends StatelessWidget {
  final WsClient ws;

  const DiagnosticsPage({super.key, required this.ws});

  Color _kindColor(String kind) {
    switch (kind) {
      case 'heartbeat_timeout':
        return Colors.orangeAccent;
      case 'connect_fail':
        return Colors.redAccent;
      case 'done':
        return Colors.blueGrey;
      default:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接诊断'),
        actions: [
          IconButton(
            tooltip: '立即重连',
            icon: const Icon(Icons.refresh),
            onPressed: () => ws.reconnectNow(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<ConnDiagEntry>>(
        valueListenable: ws.diagLog,
        builder: (context, entries, _) {
          if (entries.isEmpty) {
            return const Center(child: Text('暂无断连记录（自 App 启动以来还没断过）'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            separatorBuilder: (context, i) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          e.tsLabel,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _kindColor(e.kind).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            e.kind,
                            style: TextStyle(
                              fontSize: 11,
                              color: _kindColor(e.kind),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          e.foreground
                              ? Icons.visibility
                              : Icons.visibility_off,
                          size: 14,
                          color: Colors.grey,
                        ),
                        Text(
                          e.foreground ? ' 前台' : ' 后台',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'code=${e.closeCode ?? '?'} reason=${e.closeReason ?? ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (e.detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          e.detail,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
