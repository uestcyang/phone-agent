# Dependency and attribution notes

The release tree contains project source plus package manifests. No installed dependency tree, native tunnel binary, SDK, signing key, or old repository history is included.

The Android build resolves Flutter and Dart packages listed in `app/pubspec.yaml` and `app/pubspec.lock`, plus the Gradle dependencies in `app/android/app/build.gradle.kts`. The Shizuku API/provider is a dependency, not a bundled private device configuration. The server resolves aiohttp and its dependencies from `server/requirements.lock`.

Dependencies retain their original licenses and notices. `tools/bootstrap_android.py` asks the locally installed Flutter SDK to generate its standard wrapper files; it does not substitute project ownership for SDK ownership. Preserve upstream notices in any distributed binaries. The project MIT license does not relicense dependencies.

This source review found no third-party copyright notices in the selected original application source that needed removal. It does not certify the provenance of code not included in this release.
