// ====================================================================================================================                                                                                                                                                            me            #*eddiere
// CargoMate Mobile App - Pure REST API Role View Model
// ====================================================================================================================

import 'package:cloud_firestore/cloud_firestore.dart';
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

  /// Bootstraps active user role directly from Go REST API gateway / Firestore for current UID
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

      // 1. Primary: Fetch user profile from Go REST API gateway
      String? resolvedRole;
      try {
        final me = await ApiService.I.getMe();
        final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
        resolvedRole = (userObj['role'] as String? ?? me['role'] as String?)?.trim().toLowerCase();
      } catch (e) {
        if (kDebugMode) print('[ROLE_VM] ApiService getMe error: $e');
      }

      // 2. Secondary: Fallback to Firestore profiles/{uid}
      if (resolvedRole == null || resolvedRole.isEmpty) {
        try {
          final doc = await FirebaseFirestore.instance.collection('profiles').doc(user.uid).get();
          if (doc.exists) {
            resolvedRole = (doc.data()?['role'] as String?)?.trim().toLowerCase();
          }
        } catch (e) {
          if (kDebugMode) print('[ROLE_VM] Firestore profile read error: $e');
        }
      }

      // 3. Fallback: Local storage for this specific UID
      if (resolvedRole == null || resolvedRole.isEmpty) {
        resolvedRole = await Prefs.I.getRoleForUser(user.uid);
      }

      if (resolvedRole != null && resolvedRole.isNotEmpty) {
        _role = resolvedRole;
        await Prefs.I.setRoleForUser(user.uid, _role);
      } else {
        _role = 'customer';
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

  /// Change role locally
  void setRole(String newRole) {
    _role = newRole;
    final uid = _auth.currentUser?.uid;
    if (uid != null && uid.isNotEmpty) {
      Prefs.I.setRoleForUser(uid, newRole);
    }
    notifyListeners();
  }

  /// Persist new role via Go REST API gateway & local Prefs
  Future<void> saveRole(String newRole) async {
    try {
      final uid = _auth.currentUser?.uid;
      await ApiService.I.updateMe({'role': newRole});
      if (uid != null && uid.isNotEmpty) {
        await Prefs.I.setRoleForUser(uid, newRole);
      }
      _role = newRole;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        print('Error saving role: $e');
      }
    }
  }

  /// Reset in-memory role state on logout (NEVER mutate backend DB on logout!)
  void clearRole() {
    _role = 'customer';
    _userId = null;
    _loading = false;
    notifyListeners();
  }
}
