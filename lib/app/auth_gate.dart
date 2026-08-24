import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../routes/navRoutes.dart';
import '../services/prefs.dart';

// Optional: if you want to fetch Firestore here you can; keeping it light.

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _bootRoute; // decide once

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      // not logged in
      setState(() => _bootRoute = NavRoutes.signUpPhone);
      return;
    }

    // user exists locally; check prefs for quick route
    final hasProfile = await Prefs.I.getHasProfile();
    final role = await Prefs.I.getRole() ?? 'customer';

    if (!mounted) return;
    if (!hasProfile) {
      setState(() => _bootRoute = NavRoutes.completeProfile);
    } else {
      if (role == 'driver' || role == 'bikerider') {
        setState(() => _bootRoute = NavRoutes.driverHome);
      } else {
        setState(() => _bootRoute = NavRoutes.homePage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bootRoute == null) {
      // small splash while deciding
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Use a placeholder and then pushReplacement to keep Navigator clean
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.pushReplacementNamed(context, _bootRoute!);
    });
    return const Scaffold(body: SizedBox.shrink());
  }
}
