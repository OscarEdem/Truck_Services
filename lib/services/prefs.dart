// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter App - User Preferences & Local Persistence Service
// ====================================================================================================================

import 'package:shared_preferences/shared_preferences.dart';

class Prefs {
  Prefs._();
  static final Prefs I = Prefs._();

  Future<SharedPreferences> get _p async => SharedPreferences.getInstance();

  // CargoMate System JWT Token Persistence
  Future<void> setToken(String token) async => (await _p).setString('jwt_token', token);
  Future<String?> getToken() async => (await _p).getString('jwt_token');
  Future<void> removeToken() async => (await _p).remove('jwt_token');

  // Firebase User ID & Profile Persistent Metadata
  Future<void> setUid(String uid) async => (await _p).setString('uid', uid);
  Future<String?> getUid() async => (await _p).getString('uid');

  Future<void> setPhone(String phone) async => (await _p).setString('phone', phone);
  Future<String?> getPhone() async => (await _p).getString('phone');

  Future<void> setRole(String role) async => (await _p).setString('role', role);
  Future<String?> getRole() async => (await _p).getString('role');

  Future<void> setAvatarUrl(String url) async => (await _p).setString('avatar_url', url);
  Future<String?> getAvatarUrl() async => (await _p).getString('avatar_url');

  Future<void> setHasProfile(bool v) async => (await _p).setBool('has_profile', v);
  Future<bool> getHasProfile() async => (await _p).getBool('has_profile') ?? false;

  Future<void> setLastDial({required String iso2, required String dial}) async {
    final p = await _p;
    await p.setString('last_dial_iso', iso2);
    await p.setString('last_dial_code', dial);
  }

  Future<(String iso2, String dial)?> getLastDial() async {
    final p = await _p;
    final iso = p.getString('last_dial_iso');
    final dial = p.getString('last_dial_code');
    if (iso == null || dial == null) return null;
    return (iso, dial);
  }

  Future<void> clearAll() async => (await _p).clear();
}
