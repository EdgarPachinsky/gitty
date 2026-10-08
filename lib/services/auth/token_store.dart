import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores provider access tokens in the OS keychain / credential manager.
class TokenStore {
  TokenStore()
    : _storage = Platform.isMacOS
          // The legacy (file-based) keychain doesn't require the
          // keychain-access-groups entitlement or a provisioning profile,
          // so the app runs unsigned during development.
          ? const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            )
          : const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String provider) => 'gitty.$provider.token';

  Future<String?> read(String provider) async {
    try {
      return await _storage.read(key: _key(provider));
    } catch (_) {
      return null; // Keychain unavailable/locked — treat as signed out.
    }
  }

  Future<void> write(String provider, String token) =>
      _storage.write(key: _key(provider), value: token);

  Future<void> delete(String provider) async {
    try {
      await _storage.delete(key: _key(provider));
    } catch (_) {
      // Nothing to delete.
    }
  }
}
