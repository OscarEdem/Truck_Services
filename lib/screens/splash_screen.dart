// lib/features/core/splash_screen.dart
import 'dart:async';
import 'package:cargomate_v3/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();

    // Wait 3 seconds then navigate
    Timer(const Duration(seconds: 3), () {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🔹 Make sure background behind transparent areas is pure blue
      backgroundColor: Colors.blue,
      body: Center(
        child: Image.asset(
          "assets/icons/CargomateAppLogo.png",
          fit: BoxFit.contain, // keeps aspect ratio
          width: MediaQuery.of(context).size.width, // scale to screen width
          height: MediaQuery.of(context).size.height, // scale to screen height
        ),
      ),
    );
  }
}
