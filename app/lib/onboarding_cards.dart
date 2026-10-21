import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kCardLockRecents = 'onboard_background_dismissed';
const String kCardNotificationGuide = 'onboard_notifications_dismissed';
Future<Set<String>> loadDismissedCards(List<String> keys) async {
  final prefs = await SharedPreferences.getInstance();
  return keys.where((key) => prefs.getBool(key) ?? false).toSet();
}

Future<void> dismissCard(String key) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(key, true);
}

class GuideCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String bodyText;
  final String? actionLabel;
  final VoidCallback? onAction;

  final VoidCallback? onDismiss;
  final Color? tint;

  const GuideCard({
    super.key,
    required this.icon,
    required this.title,
    required this.bodyText,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = (tint ?? scheme.primaryContainer).withValues(alpha: 0.28);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: tint ?? scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    bodyText,
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                  if (actionLabel != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: onAction,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(
                        actionLabel!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: '不再提示',
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

class LockRecentsCard extends StatelessWidget {
  final VoidCallback? onDismiss;
  const LockRecentsCard({super.key, this.onDismiss});
  @override
  Widget build(BuildContext context) => GuideCard(
    icon: Icons.lock_outline,
    title: '后台运行说明',
    bodyText: '需要后台接收消息时，请按设备系统设置允许通知和后台运行。不同设备的限制不同；应用不会假定相关权限已获得。',
    onDismiss: onDismiss,
  );
}

class NotificationGuideCard extends StatelessWidget {
  final VoidCallback? onDismiss;
  const NotificationGuideCard({super.key, this.onDismiss});
  @override
  Widget build(BuildContext context) => GuideCard(
    icon: Icons.notifications_outlined,
    title: '通知设置',
    bodyText: '请在系统设置中检查此应用的通知权限、声音与免打扰选项。是否转发至其他设备由你自行配置。',
    onDismiss: onDismiss,
  );
}
