// lib/screens/auth/otp_verify_screen.dart
// ignore_for_file: unnecessary_null_comparison

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';

import 'package:cargomate_v3/models/otp_args.dart';
import 'package:cargomate_v3/services/prefs.dart';
import 'package:cargomate_v3/services/api_service.dart';
import 'package:cargomate_v3/routes/navRoutes.dart';
import 'package:cargomate_v3/widgets/widgets.dart'; // LoadingOverlay, AppSnack
import 'package:cargomate_v3/viewmodel/role_view_model.dart';

class OtpVerifyScreen extends StatefulWidget {
  const OtpVerifyScreen({super.key});
  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _codeNodes = List.generate(6, (_) => FocusNode());
  final _codeCtrls = List.generate(6, (_) => TextEditingController());
  bool _busy = false;

  late String _verificationId;
  late String _phone;
  int? _resendToken;

  static const int _initialResendSeconds = 30;
  int _secondsLeft = _initialResendSeconds;
  Timer? _timer;

  final _auth = FirebaseAuth.instance;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is OtpArgs) {
      _verificationId = args.verificationId;
      _phone = args.phone;
      _resendToken = args.resendToken;
      _restartTimer();
      // Autofocus first box
      Future.microtask(() => _codeNodes.first.requestFocus());
    }
  }

  @override
  void dispose() {
    for (final n in _codeNodes) {
      n.dispose();
    }
    for (final c in _codeCtrls) {
      c.dispose();
    }
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    setState(() => _secondsLeft = _initialResendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  String get _code => _codeCtrls.map((c) => c.text).join();

  Future<void> _routeAfterAuth(User user) async {
    try {
      final hasProfile = await Prefs.I.getHasProfile();
      final me = await ApiService.I.getMe();
      final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
      final role = (userObj['role'] as String? ?? me['role'] as String?)?.trim().toLowerCase() ?? 'customer';
      final name = (userObj['full_name'] as String? ?? userObj['fullName'] as String? ?? me['full_name'] as String? ?? '').trim();
      final isComplete = (me['profile_complete'] as bool?) ?? (userObj['profile_complete'] as bool?) ?? hasProfile;
      final isDummyName = name.isEmpty || name.toLowerCase() == 'cargomate user' || name.toLowerCase() == 'user';

      if (!isComplete || isDummyName) {
        await Prefs.I.setHasProfile(false);
        if (!mounted) return;
        Navigator.pushNamedAndRemoveUntil(
          context,
          NavRoutes.signUp,
          (_) => false,
        );
        return;
      }

      await Prefs.I.setRole(role);
      await Prefs.I.setHasProfile(true);

      if (mounted) context.read<RoleViewModel>().setRole(role);

      if (!mounted) return;
      final roleKey = role.replaceAll(' ', '');
      if (roleKey == 'driver' || roleKey == 'bikerider') {
        Navigator.pushNamedAndRemoveUntil(
          context,
          NavRoutes.driverHome,
          (_) => false,
        );
      } else {
        Navigator.pushNamedAndRemoveUntil(
          context,
          NavRoutes.homePage,
          (_) => false,
        );
      }
    } catch (_) {
      if (!mounted) return;
      await Prefs.I.setHasProfile(false);
      Navigator.pushNamedAndRemoveUntil(
        context,
        NavRoutes.signUp,
        (_) => false,
      );
    }
  }

  Future<void> _verify() async {
    if (_code.length != 6 || _code.contains(RegExp(r'[^0-9]'))) {
      AppSnack.show(context, 'Enter the 6-digit code');
      return;
    }
    setState(() => _busy = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: _code,
      );
      final userCred = await _auth.signInWithCredential(credential);
      final user = userCred.user;
      if (user == null) {
        AppSnack.show(context, 'Verification failed. Try again.');
        return;
      }
      await Prefs.I.setUid(user.uid);
      await Prefs.I.setPhone(_phone);

      // Exchange Firebase ID Token for CargoMate Go Backend System Token
      final idToken = await user.getIdToken() ?? '';
      try {
        final loginResponse = await ApiService.I.firebaseLogin(
          firebaseToken: idToken,
          phone: _phone,
        );
        
        final userObj = loginResponse['user'] as Map<String, dynamic>?;
        final role = (userObj?['role'] as String?) ?? 'customer';
        final isComplete = (loginResponse['profile_complete'] as bool?) ?? false;

        await Prefs.I.setRole(role);
        await Prefs.I.setHasProfile(isComplete);

        if (mounted) context.read<RoleViewModel>().setRole(role);
      } catch (backendErr) {
        // Fallback if backend is running in offline sandbox mode
        print('[Backend Warning] Go Gateway login check: $backendErr');
      }

      await _routeAfterAuth(user);
    } on FirebaseAuthException catch (e) {
      AppSnack.show(context, e.message ?? 'Invalid code');
    } catch (e) {
      AppSnack.show(context, 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0) return;
    setState(() => _busy = true);
    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: _phone,
        forceResendingToken: _resendToken,
        verificationCompleted: (cred) async {
          try {
            final userCred = await _auth.signInWithCredential(cred);
            if (userCred.user != null) {
              await _routeAfterAuth(userCred.user!);
            }
          } catch (_) {
            /* ignore */
          }
        },
        verificationFailed: (e) =>
            AppSnack.show(context, e.message ?? 'Couldn’t resend code'),
        codeSent: (String verificationId, int? resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _restartTimer();
          for (final c in _codeCtrls) {
            c.clear();
          }
          _codeNodes.first.requestFocus();
          AppSnack.show(context, 'Code resent');
        },
        codeAutoRetrievalTimeout: (_) {},
      );
    } catch (e) {
      AppSnack.show(context, 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changePhone() {
    Navigator.pushNamedAndRemoveUntil(context, NavRoutes.signIn, (_) => false);
  }

  // ---- OTP box change handler with paste support ----
  void _onBoxChanged(int index, String value) {
    final digitsOnly = value.replaceAll(RegExp(r'[^0-9]'), '');

    // If user pasted multiple chars (likely all 6)
    if (digitsOnly.length > 1) {
      final chars = digitsOnly.split('');
      for (var i = 0; i < 6; i++) {
        _codeCtrls[i].text = i < chars.length ? chars[i] : '';
      }
      // move focus to last non-empty or stay at end
      final lastFilled = _codeCtrls
          .lastIndexWhere((c) => c.text.isNotEmpty)
          .clamp(0, 5);
      _codeNodes[lastFilled].requestFocus();
      if (_code.length == 6) _verify();
      return;
    }

    // Normal 1-char input / deletion
    if (value.isEmpty && index > 0) {
      _codeNodes[index - 1].requestFocus();
    } else if (value.isNotEmpty && index < 5) {
      _codeNodes[index + 1].requestFocus();
    }

    // Auto-verify when all 6 are filled
    if (_code.length == 6 && !_code.contains(RegExp(r'[^0-9]'))) {
      _verify();
    }
  }

  @override
  Widget build(BuildContext context) {
    final minutes = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsLeft % 60).toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LoadingOverlay(
          show: _busy,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                // Top bar (back)
                Row(
                  children: [
                    IconButton(
                      onPressed: _changePhone,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 4),

                // Logo
                Image.asset(
                  'assets/icons/cargomatebluelogo.png',
                  height: 48,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),

                const Text(
                  'Verify code',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'A 6-digit code was sent to $_phone',
                  style: const TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 24),

                // Responsive modern OTP boxes
                LayoutBuilder(
                  builder: (context, constraints) {
                    const boxes = 6;
                    const gap = 12.0;
                    final totalGaps = gap * (boxes - 1);
                    final boxW = ((constraints.maxWidth - totalGaps) / boxes)
                        .clamp(44.0, 60.0);

                    final children = <Widget>[];
                    for (var i = 0; i < boxes; i++) {
                      if (i > 0) children.add(const SizedBox(width: gap));
                      children.add(
                        _OtpBox(
                          width: boxW,
                          controller: _codeCtrls[i],
                          focusNode: _codeNodes[i],
                          onChanged: (val) => _onBoxChanged(i, val),
                          onSubmitted: (_) {
                            if (i == 5) _verify();
                          },
                        ),
                      );
                    }
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: children,
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Verify
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFF3D5AFE),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _verify,
                    child: const Text(
                      'Verify',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Resend
                TextButton(
                  onPressed: _secondsLeft == 0 ? _resend : null,
                  child: Text(
                    _secondsLeft == 0
                        ? 'Resend code'
                        : 'Resend in $minutes:$seconds',
                  ),
                ),

                // Change phone quick link
                TextButton(
                  onPressed: _changePhone,
                  child: const Text(
                    'Change phone number',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OtpBox extends StatelessWidget {
  final double width;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const _OtpBox({
    required this.width,
    required this.controller,
    required this.focusNode,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        // No maxLength to allow full 6-digit paste; we manage distribution in onChanged
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.oneTimeCode],
        enableSuggestions: false,
        autocorrect: false,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: const Color(0xFFF0F4FF),
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    );
  }
}
