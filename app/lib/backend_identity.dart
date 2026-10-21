import 'constants.dart';

class BackendIdentity {
  static const endpointHost = kDefaultHost;
  static const ports = <String, int>{'agent_a': kDefaultPort};
  static String? role(String host, int port) =>
      host == endpointHost && port == kDefaultPort ? 'agent_a' : null;
  static String credentialKey(String host, int port) =>
      'device_token_${Uri.encodeComponent(host)}:$port';
}
