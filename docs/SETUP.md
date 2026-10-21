# Phone Agent

An Android client and self-hosted transport for operating a configured native agent executor from a phone.

## Scope of this source release

This is a privacy-minimized **core edition**, not a copy of a personal deployment. It includes the existing Flutter/Android client, persistent message receipts and replay logic extracted from the original transport, and a standalone HTTP/WebSocket binding. A configured CLI owns model selection, tools, permissions and the agent loop. The transport does not build another model-planning loop.

Supported: explicit device pairing and revocation; per-device session isolation; durable message acknowledgement and duplicate-content rejection; restart-aware queued-message recovery; reconnect replay; authenticated upload/download; bounded native command execution and artifact collection.

Excluded: personal roles, model/account presets, billing/quota collectors, infrastructure repair, private model adapters, private scheduled duties, deployment history and device identifiers. The standalone server does not provide voice, incognito storage, a device-control tunnel, or account widgets. Unsupported incognito requests are rejected before persistence. Some client extension UI remains for compatible backends; it is not a claim that this standalone server implements those extensions.

## Server setup

Use Python 3.11 or newer on Linux or macOS. Start in the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r server/requirements.lock
export PA_ADMIN_TOKEN="$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export PA_STATE_DIR="$PWD/state"
export PA_RUNNER_COMMAND='["python3", "/absolute/path/to/your/executor_adapter.py"]'
.venv/bin/python server/server.py
```

The adapter path above is a placeholder: configure an executable you control. A token or command missing from the configuration prevents startup. Store the generated administrator token privately; do not commit it or give it to the phone. The phone receives a separate revocable device token after approval.

An adapter receives one JSON object on stdin with `session_id`, `message_id`, `text`, `attachments` and recent `history`. It must write `{"text":"response", "files":["relative-artifact.txt"]}` to stdout. Files must be regular, non-hardlinked, non-symlink files within that job's working directory. The server treats prompt text as data, never a shell command.

`server/native_runner.py` adapts a native CLI that reads a prompt from stdin and emits plain text on stdout. Set `PA_RUNNER_COMMAND` to its absolute Python command and explicitly supply `PA_NATIVE_COMMAND_JSON` through `PA_RUNNER_ENV_JSON`. Native CLI flags vary by provider. Use a provider-supported noninteractive invocation; this project does not extract browser cookies, reuse consumer sessions, or bypass provider authorization. An optional `artifacts.json` produced by that CLI is a list of relative output paths.

The executor's default HOME is an isolated job directory and its environment is minimal. Any credentials, HOME override or tool permissions needed by a native executor must be deliberately configured in `PA_RUNNER_ENV_JSON`. This is not an OS sandbox: run a powerful executor as a restricted OS account or container and pair only trusted operators.

## Android build and local connection

Use a Flutter SDK compatible with the Dart constraint in `app/pubspec.yaml`, Java 17 and Android SDK 36.

```sh
python3 tools/bootstrap_android.py
cd app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build apk --debug
```

The bootstrap command generates machine-local wrapper/configuration files using your SDK. They are ignored by Git and were not copied from a developer machine. No prebuilt APK, private icon, signing key or native bridge binary is shipped.

The default endpoint is `localhost:8080` with attachments on `localhost:9080`. For a USB-connected development device, explicitly authorize ADB and run `adb reverse tcp:8080 tcp:8080` and `adb reverse tcp:9080 tcp:9080`. This is a local development route, not a public ADB deployment. Open the app, request pairing, then approve the code displayed on that device:

```sh
.venv/bin/python server/manage.py THE_DISPLAYED_CODE
```

For remote use, put both server listeners behind your own authenticated TLS-capable reverse proxy. Non-loopback cleartext traffic is blocked by the default Android network policy. `PA_PUBLIC_ORIGIN` and `PA_BACKUP_ORIGIN` are optional build-time HTTPS origins; they are empty by default. The client maps these to `/agents/agent_a` for WebSocket and `/agents/agent_a/...` or `/agents/agent_a/_upload/...` for HTTP; configure your proxy accordingly. Do not expose the server without TLS on an untrusted network.

## Tests and limitations

```sh
.venv/bin/python -B -m unittest discover -s server/tests -v
```

Protocol tests create real loopback HTTP/WebSocket listeners and real child processes using synthetic executors. They check authentication, pairing, isolation, message-id reuse, replay, file paths, output limits and timeouts. They are not a test of any model's intelligence, a live paid-provider account, or physical-device UI behavior.

Delivery is not an impossible exactly-once guarantee for arbitrary external side effects: a message accepted but interrupted while executing is marked interrupted and is not automatically repeated. A user must decide whether to resume such a task. `/reset` and `/clear` create a new session; they do not erase old persisted history.

Media players may use a device token in download query parameters for compatibility. The server disables access logging; configure your reverse proxy to redact queries and use HTTPS. Device tokens must not appear in screenshots or shared links.

See `SECURITY.md` for deployment boundaries and `THIRD_PARTY.md` for dependency attribution. Project source is MIT licensed.
