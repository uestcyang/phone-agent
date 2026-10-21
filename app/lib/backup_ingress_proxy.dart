import 'dart:io';

class BackupIngressProxy extends HttpOverrides {
  final Uri backup;
  BackupIngressProxy(this.backup);

  static String proxyFor(Uri request, Uri backup) =>
      (request.scheme == 'https' || request.scheme == 'wss') &&
          request.host == backup.host &&
          request.port == backup.port
      ? 'PROXY 127.0.0.1:17890'
      : HttpClient.findProxyFromEnvironment(request);

  static void install(Uri? backup) {
    if (Platform.isAndroid && backup != null) {
      HttpOverrides.global = BackupIngressProxy(backup);
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) => proxyFor(uri, backup);
}
