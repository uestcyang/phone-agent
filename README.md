# Phone Agent

### Your native AI agent, from your Android phone.

**Phone Agent is a self-hosted Android client and durable task transport for an agent CLI you already use.** Pair your phone, send work to your own machine, reconnect after a network change, and retrieve the output files. The existing CLI keeps control of the model, tools and agent loop.

[中文说明](README.zh-CN.md) · [Setup](docs/SETUP.md) · [Validation](docs/VALIDATION.md) · [Security](SECURITY.md) · [MIT license](LICENSE)

**Core Edition · source release · Android + Python**

## The workflow

```text
Android phone                         Your host
┌──────────────────┐                 ┌─────────────────────────┐
│ Pair once        │  authenticated  │ Durable task queue      │
│ Send a task      │ ◄─────────────► │ Native CLI adapter      │
│ Reconnect later  │   WebSocket +   │ Your existing agent CLI │
│ Retrieve files   │      HTTP       │ Local workspace/output  │
└──────────────────┘                 └─────────────────────────┘
```

This is **not** a model running on the phone, a phone GUI automation agent, or another agent framework. It is the mobile entry point and delivery layer around your configured executor.

## What the core edition does

| Need | Implementation |
|---|---|
| Reach your own agent from Android | Flutter client, explicit server configuration and native CLI adapter |
| Avoid losing tasks on a flaky connection | Persisted client outbox, durable acknowledgements and server-side receipts |
| Avoid rerunning an acknowledged task | Message-id deduplication and conflicting-payload rejection |
| Resume a conversation after reconnecting | Persisted, ordered event replay |
| Receive actual work products | Authenticated uploads/downloads and bounded artifact collection |
| Keep devices separated | Administrator-approved pairing, revocation and per-device session/file checks |

An interrupted in-flight job is **not automatically repeated after a server restart**. External side effects cannot be made magically exactly-once by a WebSocket wrapper; the operator decides how to resume the job.

## Start here

You need Android, a Flutter toolchain for building the client, Python 3.11+ on Linux or macOS, and an executor you control. There is no hosted subscription or bundled model credential.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r server/requirements.lock
```

Then follow the [setup guide](docs/SETUP.md) to generate an administrator token locally, configure the executor command, start the service, build the app and approve a device. A missing token or executor command prevents startup. Nothing defaults to a maintainer's server.

`server/native_runner.py` adapts a trusted CLI that accepts a prompt on stdin and emits text on stdout. Provider-specific flags and authorization remain your responsibility. **A published adapter boundary is not a claim of tested compatibility with every commercial agent.**

## Tested, without inflating the claim

The reviewed core passed **37 server tests on both Linux and macOS**, **10 Flutter tests**, a synthetic native-CLI adapter test, and an Android debug build. The tests exercise real local HTTP/WebSocket connections and child processes. [Full scope and limitations](docs/VALIDATION.md).

No paid-model account or physical-device UI end-to-end test is claimed. The release contains source, not a prebuilt APK.

## Deliberately outside this release

Personal deployment topology, account/quota collectors, infrastructure repair, private role presets and runtime data are excluded. The standalone server does not implement voice, incognito storage or a device-control tunnel. Some extension UI can support other backends, but that is not functionality promised by this core server.

Remote deployments require your own HTTPS configuration. The executor is **not an OS sandbox**; use an appropriately restricted account or container. See [SECURITY.md](SECURITY.md).

## Related open-source projects

- [DeepMemo](https://github.com/uestcyang/deepmemo): persistent semantic memory and deterministic fact updates for agents.
- [Coldstore](https://github.com/uestcyang/coldstore): hot/warm/cold workspace tiering with proof-gated eviction.

They address different layers and are **not required dependencies** of Phone Agent.

## Contribute

The most useful early contributions are reproducible setup reports, tested native-CLI adapters and client connectivity fixes. [Contribution guide](CONTRIBUTING.md). Use synthetic examples and remove tokens, hostnames and personal paths before attaching logs.

If the project solves a real problem for you, a Star helps other developers discover it. Usage reports and reproducible issues are even more useful.
