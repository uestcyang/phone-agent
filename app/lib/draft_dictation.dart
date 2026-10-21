import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract interface class DictationGateway {
  Future<void> start();
  Future<String> finish();
  Future<void> cancel();
}

class NativeDictationGateway implements DictationGateway {
  static const channel = MethodChannel('org.phoneagent.app/draft_dictation');
  static int _next = 0;
  final String owner = '${DateTime.now().microsecondsSinceEpoch}-${_next++}';
  final Future<String> Function(String) transcribe;
  NativeDictationGateway({
    required void Function(String, String) onEnded,
    required this.transcribe,
  }) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'ended') {
        final args = call.arguments as Map?;
        if (args?['owner'] == owner) {
          final path = (args?['audioPath'] ?? '').toString();
          try {
            final text = path.isEmpty ? '' : await transcribe(path);
            onEnded(text, (args?['error'] ?? '').toString());
          } catch (e) {
            onEnded('', '语音转文字失败，录音和原文字已保留：$e');
          }
        }
      }
    });
  }
  @override
  Future<void> start() async {
    await channel.invokeMethod<void>('start', {'owner': owner});
  }

  @override
  Future<String> finish() async {
    final path =
        await channel.invokeMethod<String>('finish', {'owner': owner}) ?? '';
    return path.isEmpty ? '' : transcribe(path);
  }

  @override
  Future<void> cancel() async {
    await channel.invokeMethod<void>('cancel', {'owner': owner});
  }
}

enum DictationPhase { idle, starting, recording, transcribing }

String appendDictation(String current, String transcript) {
  final words = transcript.trim();
  if (words.isEmpty) return current;
  return current.isEmpty
      ? words
      : '$current${current.endsWith('\n') ? '' : '\n'}$words';
}

class DraftDictationController extends ChangeNotifier {
  DraftDictationController({
    required this.input,
    required this.gateway,
    required this.onError,
  });
  final TextEditingController input;
  final DictationGateway gateway;
  final void Function(String) onError;
  DictationPhase phase = DictationPhase.idle;
  bool _disposed = false;
  Future<void>? _operation;
  bool get recording => phase == DictationPhase.recording;
  bool get busy =>
      phase == DictationPhase.starting || phase == DictationPhase.transcribing;

  void _append(String text) {
    if (_disposed || text.trim().isEmpty) return;
    final value = appendDictation(input.text, text);
    input.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void ended(String text, String error) {
    if (_disposed ||
        phase == DictationPhase.idle ||
        phase == DictationPhase.transcribing) {
      return;
    }
    _append(text);
    phase = DictationPhase.idle;
    notifyListeners();
    if (error.isNotEmpty) onError(error);
  }

  Future<void> toggle() async {
    if (_disposed || busy) return;
    final operation = _toggle();
    _operation = operation;
    try {
      await operation;
    } finally {
      if (identical(_operation, operation)) _operation = null;
    }
  }

  Future<void> settle() async {
    await _operation;
    if (recording) await toggle();
    await _operation;
  }

  Future<void> _toggle() async {
    if (phase == DictationPhase.idle) {
      phase = DictationPhase.starting;
      notifyListeners();
      try {
        await gateway.start();
        if (_disposed) {
          await gateway.cancel();
          return;
        }
        if (phase != DictationPhase.starting) {
          return;
        }
        phase = DictationPhase.recording;
      } catch (_) {
        phase = DictationPhase.idle;
        if (!_disposed) onError('无法开始语音输入，请检查麦克风权限和语音识别服务。');
      }
      if (!_disposed) notifyListeners();
      return;
    }
    phase = DictationPhase.transcribing;
    notifyListeners();
    try {
      final text = await gateway.finish();
      _append(text);
      if (!_disposed && text.trim().isEmpty) onError('没有识别到语音，原文字已保留。');
    } catch (_) {
      if (!_disposed) onError('语音转文字失败，原文字已保留。');
    } finally {
      phase = DictationPhase.idle;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(gateway.cancel().catchError((_) {}));
    super.dispose();
  }
}
