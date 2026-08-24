import 'package:flutter/material.dart';
import '../routes/navRoutes.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // white background like your design
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // --- Image (delivery guy illustration) ---
              Expanded(
                flex: 2,
                child: Center(
                  child: Image.asset(
                    "assets/icons/man.png",
                    fit: BoxFit.contain,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // --- Title ---
              const Text(
                "Welcome to CargoMate",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),

              const SizedBox(height: 12),

              // --- Subtitle ---
              const Text(
                "Fast, reliable, and affordable deliveries across Ghana –\n"
                "from bikes to trucks, right at your doorstep.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                  height: 1.4,
                ),
              ),

              const Spacer(),

              // --- Button ---
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.blue, // matches design
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, NavRoutes.signIn),
                  child: const Text(
                    'Get Started',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
