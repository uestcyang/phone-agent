library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

const String kCustomizationDirName = 'phone_agent_customization';
const String kAvatarsDirName = 'avatars';
const String kBgFileName = 'chat_bg.jpg';
const String kSettingsFileName = 'settings.json';

Future<Directory> customizationDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/$kCustomizationDirName');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

Future<Directory> avatarsDir() async {
  final base = await customizationDir();
  final dir = Directory('${base.path}/$kAvatarsDirName');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

Future<File> chatBackgroundFile() async =>
    File('${(await customizationDir()).path}/$kBgFileName');

Future<File> avatarFile(String agentId) async =>
    File('${(await avatarsDir()).path}/avatar_$agentId.png');

Future<Map<String, dynamic>> readSettings() async {
  try {
    final f = File('${(await customizationDir()).path}/$kSettingsFileName');
    if (!await f.exists()) return <String, dynamic>{};
    final raw = await f.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<void> writeSettings(Map<String, dynamic> data) async {
  final dir = await customizationDir();
  final tmp = File('${dir.path}/$kSettingsFileName.tmp');
  final dst = File('${dir.path}/$kSettingsFileName');
  await tmp.writeAsString(jsonEncode(data), flush: true);
  await tmp.rename(dst.path);
}

Future<void> patchSettings(String key, Object? value) async {
  final cur = await readSettings();
  if (value == null) {
    cur.remove(key);
  } else {
    cur[key] = value;
  }
  await writeSettings(cur);
}

Future<void> evictImageCache(File file) async {
  try {
    await FileImage(file).evict();
  } catch (_) {}
  PaintingBinding.instance.imageCache.clearLiveImages();
}
