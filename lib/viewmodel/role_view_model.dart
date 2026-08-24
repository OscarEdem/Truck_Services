// ====================================================================================================================                                                                                                                                                            me            #*eddiere
// CargoMate Mobile App - Pure REST API Role View Model
// ====================================================================================================================

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';
import '../services/prefs.dart';

class RoleViewModel extends ChangeNotifier {
  final _auth = FirebaseAuth.instance;

  bool _loading = true;
  bool get loading => _loading;

  String _role = 'customer';
  String get role => _role;

  String? _userId;
  String? get userId => _userId;

  /// Bootstraps active user role from Go REST API gateway / Prefs
  Future<void> bootstrap() async {
    _loading = true;
    notifyListeners();

    try {
      final user = _auth.currentUser;
      if (user == null) {
        _role = 'customer';
        _userId = null;
        _loading = false;
        notifyListeners();
        return;
      }

      _userId = user.uid;
      final savedRole = await Prefs.I.getRole();
      if (savedRole != null && savedRole.isNotEmpty) {
        _role = savedRole;
      }

      final me = await ApiService.I.getMe();
      final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
      final apiRole = (userObj['role'] as String? ?? me['role'] as String?)?.trim().toLowerCase();

      if (apiRole != null && apiRole.isNotEmpty) {
        _role = apiRole;
        await Prefs.I.setRole(_role);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading role: $e');
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Change role locally (does not save to Firestore yet)
  void setRole(String newRole) {
    _role = newRole;
    notifyListeners();
  }

  /// Persist new role via Go REST API gateway & local Prefs
  Future<void> saveRole(String newRole) async {
    try {
      await ApiService.I.updateMe({'role': newRole});
      await Prefs.I.setRole(newRole);
      _role = newRole;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        print('Error saving role: $e');
      }
    }
  }

  /// Reset role to default customer
  Future<void> clearRole() async {
    try {
      await ApiService.I.updateMe({'role': 'customer'});
      await Prefs.I.setRole('customer');
    } catch (e) {
      if (kDebugMode) {
        print('Error clearing role: $e');
      }
    }

    _role = 'customer';
    _userId = null;
    _loading = false;
    notifyListeners();
  }
}
