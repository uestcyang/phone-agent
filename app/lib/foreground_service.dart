import 'dart:io';

import 'package:flutter/services.dart';

class ForegroundKeepAlive {
  static const MethodChannel _channel = MethodChannel(
    'org.phoneagent.app/keepalive',
  );
  static const MethodChannel _permChannel = MethodChannel(
    'org.phoneagent.app/permissions',
  );

  static Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkNotificationPermission') ??
          false;
      if (!granted) {
        await _permChannel.invokeMethod<bool>('requestNotificationPermission');
      }
    } catch (_) {}
  }

  static Future<void> start({
    String title = '手机 Agent 在线',
    String text = '正在连接…',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start', {'title': title, 'text': text});
    } catch (_) {}
  }

  static Future<void> updateStatus({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('update', {'title': title, 'text': text});
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _permChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _permChannel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
