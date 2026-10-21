import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

import 'customization_store_io.dart';

const String _legacyPrefBgPath = 'chat_background_path';
const String _legacyPrefBgDim = 'chat_background_dim';
const String _kSettingsKeyDim = 'bg_dim';
const double kDefaultBgDim = 0.35;
const double kMaxBgDim = 0.8;
const int _kMaxLongEdge = 1440;

class ChatBackgroundSettings {
  final String? path;
  final double dim;

  final int rev;
  const ChatBackgroundSettings({
    this.path,
    this.dim = kDefaultBgDim,
    this.rev = 0,
  });
}

final ValueNotifier<ChatBackgroundSettings> chatBackground = ValueNotifier(
  const ChatBackgroundSettings(),
);

Future<void> loadChatBackground() async {
  final file = await chatBackgroundFile();
  final settings = await readSettings();

  double dim;
  final raw = settings[_kSettingsKeyDim];
  if (raw is num) {
    dim = raw.toDouble();
  } else {
    double? legacy;
    try {
      legacy = (await SharedPreferences.getInstance()).getDouble(
        _legacyPrefBgDim,
      );
    } catch (_) {
      legacy = null;
    }
    dim = legacy ?? kDefaultBgDim;
    await patchSettings(_kSettingsKeyDim, dim);
  }
  dim = dim.clamp(0.0, kMaxBgDim);

  chatBackground.value = await file.exists()
      ? ChatBackgroundSettings(path: file.path, dim: dim)
      : ChatBackgroundSettings(dim: dim);
}

Future<void> setChatBackgroundDim(double dim) async {
  final clamped = dim.clamp(0.0, kMaxBgDim);
  await patchSettings(_kSettingsKeyDim, clamped);
  final cur = chatBackground.value;
  chatBackground.value = ChatBackgroundSettings(
    path: cur.path,
    dim: clamped,
    rev: cur.rev,
  );
}

img.Image _resizeLongEdge(img.Image src, int maxEdge) {
  final longEdge = src.width > src.height ? src.width : src.height;
  if (longEdge <= maxEdge) return src;
  return src.width >= src.height
      ? img.copyResize(src, width: maxEdge)
      : img.copyResize(src, height: maxEdge);
}

Future<bool> pickChatBackground() async {
  final picker = ImagePicker();
  final xfile = await picker.pickImage(
    source: ImageSource.gallery,
    imageQuality: 92,
  );
  if (xfile == null) return false;
  final bytes = await xfile.readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return false;
  final resized = _resizeLongEdge(decoded, _kMaxLongEdge);
  final file = await chatBackgroundFile();
  await file.writeAsBytes(img.encodeJpg(resized, quality: 85), flush: true);
  await evictImageCache(file);
  final cur = chatBackground.value;
  chatBackground.value = ChatBackgroundSettings(
    path: file.path,
    dim: cur.dim,
    rev: cur.rev + 1,
  );
  return true;
}

Future<void> clearChatBackground() async {
  final file = await chatBackgroundFile();
  if (await file.exists()) await file.delete();
  await evictImageCache(file);

  try {
    await (await SharedPreferences.getInstance()).remove(_legacyPrefBgPath);
  } catch (_) {}
  final cur = chatBackground.value;
  chatBackground.value = ChatBackgroundSettings(dim: cur.dim, rev: cur.rev + 1);
}

class ChatBackgroundLayer extends StatelessWidget {
  const ChatBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatBackgroundSettings>(
      valueListenable: chatBackground,
      builder: (context, bg, _) {
        final path = bg.path;
        if (path == null || !File(path).existsSync()) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(path),
                key: ValueKey('bg-$path-${bg.rev}'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
              Container(color: Colors.black.withValues(alpha: bg.dim)),
            ],
          ),
        );
      },
    );
  }
}

class BackgroundScaffold extends StatelessWidget {
  const BackgroundScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatBackgroundSettings>(
      valueListenable: chatBackground,
      builder: (context, bg, _) {
        final hasBg = bg.path != null && File(bg.path!).existsSync();
        final theme = Theme.of(context);
        final scaffold = Scaffold(
          backgroundColor: hasBg ? Colors.transparent : null,
          appBar: appBar,
          body: body,
          floatingActionButton: floatingActionButton,
        );
        if (!hasBg) return scaffold;
        return Stack(
          children: [
            const ChatBackgroundLayer(),

            Theme(
              data: theme.copyWith(
                appBarTheme: theme.appBarTheme.copyWith(
                  backgroundColor: Colors.black.withValues(alpha: 0.25),
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                ),
              ),
              child: scaffold,
            ),
          ],
        );
      },
    );
  }
}
