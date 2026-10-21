import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'transport_routes.dart';

Future<String> transcribeDraftAudio({
  required String host,
  required int port,
  required String token,
  required File file,
  http.Client? client,
}) async {
  final own = client == null;
  final uploader = client ?? http.Client();
  try {
    final response = await uploader
        .post(
          backendUri(host, port, '/upload', upload: true),
          headers: {
            'Authorization': 'Bearer $token',
            'X-Filename':
                'demo_legacy-dictation-v1-${DateTime.now().microsecondsSinceEpoch}.m4a',
            'X-Mime': 'audio/mp4',
            'X-Draft-Dictation': '1',
            'Content-Type': 'application/octet-stream',
          },
          body: await file.readAsBytes(),
        )
        .timeout(const Duration(minutes: 16));
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode != 200 || body['ok'] != true) {
      throw UploadException((body['error'] ?? '语音转写失败，原录音已保留').toString());
    }
    if (body['text'] is! String) {
      final rel = body['rel'];
      if (rel is! String ||
          !RegExp(r'^/upload/[0-9]{8}/[A-Za-z0-9._-]+$').hasMatch(rel)) {
        throw UploadException('服务端未返回转写文字或有效录音回执');
      }
      final deadline = DateTime.now().add(const Duration(minutes: 16));
      while (DateTime.now().isBefore(deadline)) {
        final result = await uploader
            .get(
              backendUri(host, port, '$rel.dictation.json', upload: true),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 10));
        if (result.statusCode == 200) {
          final transcript =
              jsonDecode(utf8.decode(result.bodyBytes)) as Map<String, dynamic>;
          if (transcript['ok'] != true) {
            throw UploadException((transcript['error'] ?? '本机转写失败').toString());
          }
          if (transcript['text'] is! String) throw UploadException('转写结果格式无效');
          return transcript['text'] as String;
        }
        if (result.statusCode != 404) {
          throw UploadException('转写结果读取失败：${result.statusCode}');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      throw UploadException('转写等待超时，录音和原文字已保留');
    }
    return body['text'] as String;
  } finally {
    if (own) uploader.close();
  }
}

Future<bool> supportsDraftTranscription({
  required String host,
  required int port,
  required String token,
}) async {
  try {
    final response = await http
        .get(
          backendUri(host, port, '/healthz'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 4));
    final body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return response.statusCode == 200 &&
        body['local_draft_dictation'] == 'continuous-cpu/v1';
  } catch (_) {
    return false;
  }
}

int uploadPortFor(int chatPort) => chatPort + 1000;

Uri realtimeVoiceTtsUri(String host, int chatPort) =>
    backendUri(host, chatPort, '/voice/tts', upload: true);

String _asciiSafeName(String name) {
  final safe = name.replaceAll(RegExp(r'[^\x20-\x7E]'), '_');
  return safe.isEmpty ? 'upload.bin' : safe;
}

class UploadException implements Exception {
  final String message;
  UploadException(this.message);
  @override
  String toString() => message;
}

Future<Uint8List> fetchRealtimeVoiceAudio({
  required String host,
  required int port,
  required String token,
  required String text,
}) async {
  http.Response response;
  try {
    response = await http
        .post(
          realtimeVoiceTtsUri(host, port),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    throw UploadException('语音合成失败(网络): $e');
  }
  if (response.statusCode != 200) {
    final detail = utf8.decode(response.bodyBytes, allowMalformed: true);
    final detailEnd = detail.length < 240 ? detail.length : 240;
    throw UploadException(
      '语音合成失败: HTTP ${response.statusCode} '
      '${detail.substring(0, detailEnd)}',
    );
  }
  final contentType = response.headers['content-type'] ?? '';
  if (!contentType.startsWith('audio/') || response.bodyBytes.length < 100) {
    throw UploadException('语音合成失败: 服务端没有返回有效音频');
  }
  return response.bodyBytes;
}

Future<ChatAttachment> uploadFile({
  required String host,
  required int port,
  required String token,
  required File file,
  required String filename,
  required String mime,
  http.Client? client,
}) async {
  final uri = backendUri(host, port, '/upload', upload: true);
  final bytes = await file.readAsBytes();
  http.Response resp;
  final ownClient = client == null;
  final uploader = client ?? http.Client();

  final seconds = (30 + (bytes.length / (64 * 1024)).ceil()).clamp(120, 600);
  try {
    resp = await uploader
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'X-Filename': _asciiSafeName(filename),
            'X-Mime': mime,
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        )
        .timeout(Duration(seconds: seconds));
  } catch (e) {
    throw UploadException('上传失败(网络): $e');
  } finally {
    if (ownClient) uploader.close();
  }
  if (resp.statusCode != 200) {
    throw UploadException('上传失败: HTTP ${resp.statusCode} ${resp.body}');
  }
  final j = jsonDecode(resp.body) as Map<String, dynamic>;
  if (j['ok'] != true) {
    throw UploadException('上传失败: ${j['error'] ?? resp.body}');
  }
  if ((j['size'] as num?)?.toInt() != bytes.length) {
    throw UploadException('文件未完整送达，草稿已保留，请重试');
  }
  return ChatAttachment(
    rel: j['rel'] as String,
    mime: (j['mime'] as String?) ?? mime,
    name: filename,
    size: (j['size'] as num?)?.toInt() ?? bytes.length,
  );
}

String attachmentUrl(String host, int port, String rel) {
  return backendUri(host, port, rel, upload: true).toString();
}

String attachmentUrlWithToken(String host, int port, String token, String rel) {
  final uri = backendUri(host, port, rel, upload: true);
  return uri
      .replace(queryParameters: {...uri.queryParameters, 'token': token})
      .toString();
}

Map<String, String> authHeader(String token) => {
  'Authorization': 'Bearer $token',
};
