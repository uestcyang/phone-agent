import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_agent_app/message_outbox.dart';
import 'package:phone_agent_app/transport_routes.dart';
import 'package:phone_agent_app/backend_identity.dart';
import 'package:phone_agent_app/agent_registry.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('single neutral default has no deployed endpoint', () {
    expect(kAgentRegistryFallback.length, 1);
    expect(kAgentRegistryFallback.first.host, 'localhost');
    expect(kAgentRegistryFallback.first.port, 8080);
  });
  test('credential identity includes exact endpoint', () {
    expect(BackendIdentity.credentialKey('localhost', 8080), isNot(BackendIdentity.credentialKey('localhost', 8081)));
  });
  test('default route stays on explicitly configured endpoint', () {
    final routes=TransportRoutes();
    expect(routes.websocket('localhost',8080).toString(),'ws://localhost:8080/ws');
    expect(routes.uri('localhost',8080,'/upload',upload:true).port,9080);
  });
  test('public origin must be HTTPS and cannot contain credentials', () {
    expect(() => TransportRoutes(origin:'http://example.invalid'),throwsArgumentError);
    expect(() => TransportRoutes(origin:'https://account@example.invalid'),throwsArgumentError);
  });
  test('path traversal and external relative URL rejected', () {
    final routes=TransportRoutes();
    expect(() => routes.uri('localhost',8080,'/../secret'),throwsArgumentError);
    expect(() => routes.uri('localhost',8080,'https://example.invalid/'),throwsArgumentError);
  });
  test('public routing has generic role only', () {
    final routes=TransportRoutes(origin:'https://example.invalid');
    expect(routes.websocket('localhost',8080).path,'/agents/agent_a');
  });
  test('durable outbox survives reload', () async {
    final d=await Directory.systemTemp.createTemp('outbox-test-');
    try {
      final first=MessageOutbox('test-endpoint',directory:d);
      final entry=await first.enqueue('session-a','synthetic message');
      final second=MessageOutbox('test-endpoint',directory:d);
      expect((await second.pending('session-a')).single['client_message_id'],entry['client_message_id']);
      await second.acknowledge('session-a',entry['client_message_id'] as String);
      expect(await MessageOutbox('test-endpoint',directory:d).pending('session-a'),isEmpty);
    } finally {await d.delete(recursive:true);}
  });
  test('wrong-session acknowledgment preserves message', () async {
    final outbox=MessageOutbox('test',memoryOnly:true);
    final entry=await outbox.enqueue('session-a','synthetic message');
    await outbox.acknowledge('session-b',entry['client_message_id'] as String);
    expect(await outbox.pending('session-a'),hasLength(1));
  });
  test('rejected message is not retransmitted', () async {
    final outbox=MessageOutbox('test',memoryOnly:true);
    final entry=await outbox.enqueue('session-a','synthetic message');
    await outbox.reject('session-a',entry['client_message_id'] as String);
    expect(await outbox.pending('session-a'),isEmpty);
  });
  test('erased memory-only outbox cannot accept input', () async {
    final outbox=MessageOutbox('test',memoryOnly:true);outbox.clearMemory();
    await expectLater(outbox.enqueue('session-a','synthetic'),throwsStateError);
  });
}
