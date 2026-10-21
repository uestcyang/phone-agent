# Security and privacy boundaries

No personal deployment, account credential, signing key, device serial, original history, chat archive or redaction map is part of the release.

The default service binds loopback. Administrator approval is required for pairing; there is no automatic approval based on a network address. A device cannot approve another device or read another device's sessions/files. Device tokens are hashed in the persistent database. The application client stores its device credential using platform secure storage.

Use HTTPS for remote access, restrict the executor's OS permissions, and configure a firewall. The transport is not a sandbox for a deliberately malicious locally installed executor. Credentials passed explicitly to that executor have the permissions you assign them.

The native device bridge is disabled by missing configuration/binary in this edition. Self-test/audit receivers are disabled in the app manifest. No production endpoint is a default or a fallback.

Before publishing a fork, inspect its current source, dependencies, generated assets and Git history. Do not commit runtime state, local.properties, debug packages, signing materials or audit maps. A clean source package does not automatically certify a separately built APK or later changes.
