import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import 'media_download_queue.dart';
import 'models.dart';

String _formatBytes(int? bytes) {
  if (bytes == null) return '?';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

String _displayPath(String fullPath) {
  const prefix = '/storage/emulated/0/';
  return fullPath.startsWith(prefix)
      ? fullPath.substring(prefix.length)
      : fullPath;
}

IconData _iconFor(String kind) {
  switch (kind) {
    case 'image':
      return Icons.image_outlined;
    case 'video':
      return Icons.videocam_outlined;
    case 'audio':
      return Icons.audiotrack_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

class MediaAttachmentBubble extends StatefulWidget {
  final MediaAttachment att;
  final String host;
  final int port;
  const MediaAttachmentBubble({
    super.key,
    required this.att,
    required this.host,
    required this.port,
  });

  @override
  State<MediaAttachmentBubble> createState() => _MediaAttachmentBubbleState();
}

class _MediaAttachmentBubbleState extends State<MediaAttachmentBubble> {
  @override
  void initState() {
    super.initState();
    MediaDownloadQueue.instance.addListener(_onQueueChanged);
    unawaited(
      MediaDownloadQueue.instance.enqueue(
        widget.att,
        host: widget.host,
        port: widget.port,
      ),
    );
  }

  @override
  void dispose() {
    MediaDownloadQueue.instance.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openFile(String localPath) async {
    final result = await OpenFilex.open(localPath);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有能打开这个文件的应用，已为你跳转到文件夹')));
      await _openFolder(localPath);
    }
  }

  Future<void> _openFolder(String localPath) async {
    final dir = File(localPath).parent.path;
    final ok = await MediaStorageAccess.openFolder(dir);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开文件管理器')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = MediaDownloadQueue.instance.stateFor(widget.att);
    final done =
        state.status == MediaDownloadStatus.done && state.localPath != null;
    final failed = state.status == MediaDownloadStatus.failed;
    final removed = state.status == MediaDownloadStatus.removed;
    final downloading = state.status == MediaDownloadStatus.downloading;

    String subtitle;
    if (done) {
      subtitle = _displayPath(state.localPath!);
    } else if (removed) {
      subtitle = '文件已清理，点击重新下载';
    } else if (failed) {
      subtitle = state.error ?? '下载失败，点击重试';
    } else if (downloading) {
      subtitle = '下载中 · ${_formatBytes(widget.att.size)}';
    } else {
      subtitle = '排队下载 · ${_formatBytes(widget.att.size)}';
    }

    return GestureDetector(
      onTap: () {
        if (done) {
          unawaited(_openFile(state.localPath!));
        } else if (failed || removed) {
          MediaDownloadQueue.instance.retry(
            widget.att,
            host: widget.host,
            port: widget.port,
          );
        }
      },
      onLongPress: done ? () => unawaited(_openFolder(state.localPath!)) : null,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              failed ? Icons.error_outline : _iconFor(widget.att.kind),
              size: 26,
              color: failed
                  ? Colors.redAccent
                  : (done ? Colors.blueGrey : Colors.grey),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.att.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatBytes(widget.att.size),
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  if (downloading) ...[
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: state.progress >= 0 ? state.progress : null,
                      minHeight: 3,
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10,
                      color: failed ? Colors.redAccent : Colors.grey,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (done)
              InkWell(
                onTap: () => unawaited(_openFolder(state.localPath!)),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4, top: 2),
                  child: Icon(
                    Icons.folder_open_outlined,
                    size: 18,
                    color: Colors.grey,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
