#!/usr/bin/env bash
# Generates the native desktop runners (macos/, windows/, linux/) around the
# existing Dart code and fetches packages.
#
# `flutter create` never overwrites existing files, so lib/, test/, pubspec.yaml
# and the custom macOS entitlements are kept as-is.
set -euo pipefail
cd "$(dirname "$0")"

flutter config --enable-macos-desktop --enable-windows-desktop --enable-linux-desktop
flutter create . --project-name gitty --org dev.gitty --platforms=macos,windows,linux
flutter pub get
dart format lib test >/dev/null

echo ""
echo "Gitty is ready. Run it with:"
echo "  flutter run -d macos     # or: -d windows / -d linux"
echo ""
echo "Optional real GitHub sign-in (device flow):"
echo "  flutter run -d macos --dart-define=GITHUB_CLIENT_ID=<your OAuth app client id>"
