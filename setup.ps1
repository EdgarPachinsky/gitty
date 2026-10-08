# Windows equivalent of setup.sh — generates native runners and fetches packages.
# `flutter create` never overwrites existing files.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

flutter config --enable-windows-desktop
flutter create . --project-name gitty --org dev.gitty --platforms=macos,windows,linux
flutter pub get
dart format lib test | Out-Null

Write-Host ""
Write-Host "Gitty is ready. Run it with:  flutter run -d windows"
