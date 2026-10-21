# Validation of the reviewed core

| Check | Observed result | What it establishes |
|---|---|---|
| Server tests on Linux | 37 passed | Real loopback HTTP/WebSocket and synthetic child-process behavior |
| Same server tests on macOS | 37 passed | Cross-platform transport regression; not 37 additional unique tests |
| Flutter tests | 10 passed | Neutral defaults, route validation and durable outbox behavior |
| Native CLI adapter | One synthetic integration passed | Configured subprocess boundary; not model intelligence or a paid provider |
| Android debug build | Exit code 0 | Compilation, not physical-device UI E2E |
| Dart analysis | No errors or warnings; 8 informational lints | Static analysis only |

Coverage includes rejected unauthenticated access, explicit pairing, device revocation, cross-device session/file denial, message-id reuse, replay after reconnect/restart, authenticated artifacts, traversal and symlink rejection, output limits and execution timeout.

The reviewed source-only baseline contains 149 text files. The publication presentation layer adds documentation; application and server source are unchanged from that baseline. Private audit inputs, redaction maps, author-specific deployment records and original Git history are not distributed.

## Reproduce

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r server/requirements.lock
.venv/bin/python -B -m unittest discover -s server/tests -v
python3 tools/bootstrap_android.py
cd app
flutter pub get
flutter test
flutter analyze --no-fatal-infos
flutter build apk --debug
```

The test executor uses synthetic content and temporary state. Do not replace those fixtures with real account tokens, chat histories or production paths.

No automated result here certifies arbitrary third-party executors as safe. Subsequent source changes, a separately produced APK and physical-device behavior require their own checks.
