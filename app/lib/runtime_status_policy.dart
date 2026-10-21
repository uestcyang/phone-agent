class RuntimeStatusPolicy {
  static final _legacyProgress = RegExp(
    r'^Codex 已处理 \d+(?:\.\d+)? 分钟；最近进展在 \d+(?:\.\d+)? 秒前$',
  );
  static final _currentProgress = RegExp(
    r'^Codex 已处理 \d+(?:\.\d+)? 分钟；仍在等待官方终态，可随时手动暂停$',
  );

  static bool isRetry(String text, String? key) =>
      key == 'codex_connection' || text.trim() == 'Codex 链路短暂中断，正在自动重连；任务未停止';

  static bool isProgress(String text, String? key) =>
      key == 'codex_progress' ||
      _legacyProgress.hasMatch(text) ||
      _currentProgress.hasMatch(text);

  static String? replacementKey(String text, String? key) {
    if (isRetry(text, key)) return 'codex_connection';
    if (isProgress(text, key)) return 'codex_progress';
    return null;
  }

  static String? frameKey(Map<String, dynamic> frame) {
    if (frame['type'] != 'status') return null;
    final text = frame['text'] as String? ?? '';
    return replacementKey(text, frame['status_key'] as String?) ??
        (text.startsWith('思考中…(codex ') ? 'codex_thinking' : null);
  }
}
