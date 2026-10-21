import 'dart:io';

import 'package:flutter/services.dart';

class NativePush {
  static const MethodChannel _channel = MethodChannel(
    'org.phoneagent.app/push',
  );

  static Future<void> post({
    required String agentId,
    required String agentDisplayName,
    required String title,
    required String body,
    bool silent = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('post', {
        'title': title,
        'body': body,
        'agentId': agentId,
        'agentDisplayName': agentDisplayName,
        'silent': silent,
      });
    } catch (_) {}
  }
}
