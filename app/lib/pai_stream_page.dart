import 'package:flutter/material.dart';

import 'pai_ledger_client.dart';

class PaiStreamPage extends StatefulWidget {
  final String taskId;
  final String label;
  const PaiStreamPage({super.key, required this.taskId, required this.label});

  @override
  State<PaiStreamPage> createState() => _PaiStreamPageState();
}

class _PaiStreamPageState extends State<PaiStreamPage> {
  List<String> _lines = const [];
  bool _truncated = false;
  bool _loading = true;
  String? _error;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await PaiLedgerClient.fetchStream(widget.taskId, tail: 80);
      if (!mounted) return;
      setState(() {
        _lines = result.lines;
        _truncated = result.truncated;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('输出流 · ${widget.label}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
              )
            : _error != null
            ? ListView(
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
              )
            : _lines.isEmpty
            ? ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text('暂无输出', style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(12),
                itemCount: _lines.length + (_truncated ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_truncated && i == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        '（前面还有内容，已截断，仅展示末尾部分）',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    );
                  }
                  final idx = _truncated ? i - 1 : i;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      _lines[idx],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
