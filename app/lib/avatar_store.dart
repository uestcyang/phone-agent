import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

import 'customization_store_io.dart';

const int kAvatarSize = 256;
const String _legacyPrefAvatarPrefix = 'agent_avatar_path_';

class AgentAvatarStore {
  static final Map<String, ValueNotifier<String?>> _notifiers = {};

  static final Map<String, int> _revs = {};

  static ValueNotifier<String?> notifierFor(String agentId) =>
      _notifiers.putIfAbsent(agentId, () => ValueNotifier<String?>(null));

  static int revFor(String agentId) => _revs[agentId] ?? 0;

  static Future<void> load(String agentId) async {
    final file = await avatarFile(agentId);
    notifierFor(agentId).value = await file.exists() ? file.path : null;
  }

  static Future<void> loadAll(Iterable<String> agentIds) async {
    for (final id in agentIds) {
      await load(id);
    }
  }

  static img.Image _circleMask(img.Image square) {
    final w = square.width;
    final h = square.height;
    final cx = w / 2.0;
    final cy = h / 2.0;
    final r = (w < h ? w : h) / 2.0;
    final canvas = img.Image(width: w, height: h, numChannels: 4);
    img.compositeImage(canvas, square);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x + 0.5 - cx;
        final dy = y + 0.5 - cy;
        if (dx * dx + dy * dy > r * r) {
          final p = canvas.getPixel(x, y);
          canvas.setPixelRgba(x, y, p.r, p.g, p.b, 0);
        }
      }
    }
    return canvas;
  }

  static Future<bool> pick(String agentId) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (xfile == null) return false;
    final bytes = await xfile.readAsBytes();
    var decoded = img.decodeImage(bytes);
    if (decoded == null) return false;
    final side = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final x = ((decoded.width - side) / 2).round();
    final y = ((decoded.height - side) / 2).round();
    decoded = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
    final square = img.copyResize(
      decoded,
      width: kAvatarSize,
      height: kAvatarSize,
    );
    final circled = _circleMask(square);

    final file = await avatarFile(agentId);
    await file.writeAsBytes(img.encodePng(circled), flush: true);
    await evictImageCache(file);

    _revs[agentId] = revFor(agentId) + 1;

    final n = notifierFor(agentId);
    n.value = null;
    n.value = file.path;
    return true;
  }

  static Future<void> clear(String agentId) async {
    final file = await avatarFile(agentId);
    if (await file.exists()) await file.delete();
    await evictImageCache(file);
    try {
      await (await SharedPreferences.getInstance()).remove(
        '$_legacyPrefAvatarPrefix$agentId',
      );
    } catch (_) {}
    _revs[agentId] = revFor(agentId) + 1;
    notifierFor(agentId).value = null;
  }
}
