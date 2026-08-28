// lib/screens/auth/sign_in_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../routes/navRoutes.dart';
import '../../services/prefs.dart';
import '../../widgets/widgets.dart';
import '../../models/otp_args.dart'; // shared OTP args model

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

/// Lightweight country model
class _Country {
  final String name, iso2, dialCode;
  const _Country(this.name, this.iso2, this.dialCode);
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();

  // Phone inputs
  final _numberCtl = TextEditingController();
  _Country _country = const _Country('Ghana', 'GH', '233');

  // OTP send state
  final _auth = FirebaseAuth.instance;
  bool _busy = false, _sending = false;
  DateTime? _lastSendAt;
  static const _cooldown = Duration(seconds: 30);
  int _cooldownLeft = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _numberCtl.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  /// Enforce EXACTLY 9 digits for the local number (after country code)
  String? _validateLocalNumber(String? v) {
    var s = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (s.isEmpty) return 'Enter your phone number';
    if (s.startsWith('0')) {
      s = s.substring(1);
    }
    if (s.length != 9) return 'Enter 9 digits after country code';
    return null;
  }

  String get _fullE164 {
    var local = _numberCtl.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (local.startsWith('0')) {
      local = local.substring(1);
    }
    return '+${_country.dialCode}$local';
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownLeft = _cooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldownLeft <= 1) {
        t.cancel();
        if (mounted) setState(() => _cooldownLeft = 0);
      } else {
        if (mounted) setState(() => _cooldownLeft--);
      }
    });
  }

  bool _isCoolingDown() {
    if (_cooldownLeft > 0) return true;
    if (_lastSendAt == null) return false;
    return DateTime.now().difference(_lastSendAt!) < _cooldown;
  }

  void _openCountryPicker() async {
    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _CountrySheet(
        selected: _country,
        onSelect: (c) => setState(() => _country = c),
      ),
    );
  }

  // ------ Send code ------
  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    if (_sending || _isCoolingDown()) {
      final secs = _cooldownLeft > 0
          ? _cooldownLeft
          : (_lastSendAt != null
                ? (_cooldown - DateTime.now().difference(_lastSendAt!))
                      .inSeconds
                : _cooldown.inSeconds);
      AppSnack.show(context, 'Please wait ${secs}s before trying again.');
      return;
    }

    final phone = _fullE164;
    await Prefs.I.setPhone(phone);
    await Prefs.I.setLastDial(iso2: _country.iso2, dial: _country.dialCode);
    // ❌ No role saved here; role is fetched after auth for navigation.

    setState(() {
      _busy = true;
      _sending = true;
    });
    _lastSendAt = DateTime.now();
    _startCooldown();

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (_) {},
        verificationFailed: (e) =>
            AppSnack.show(context, _friendlyPhoneAuthError(e)),
        codeSent: (verificationId, resendToken) {
          if (!mounted) return;
          Navigator.pushNamed(
            context,
            NavRoutes.otpVerify,
            arguments: OtpArgs(
              verificationId: verificationId,
              phone: phone,
              resendToken: resendToken,
            ),
          );
        },
        codeAutoRetrievalTimeout: (_) {},
      );
    } catch (e) {
      AppSnack.show(context, 'Unexpected error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sending = false;
        });
      }
    }
  }

  String _friendlyPhoneAuthError(FirebaseAuthException e) {
    final code = (e.code).toLowerCase();
    switch (code) {
      case 'too-many-requests':
        return 'Too many attempts from this device. Try again later.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'invalid-phone-number':
        return 'That phone number looks invalid. Please check and try again.';
      case 'quota-exceeded':
        return 'SMS quota exceeded for this project. Try again later.';
      default:
        return e.message ?? 'Couldn’t send code (error: $code).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCooling = _isCoolingDown();
    final label = isCooling ? 'Sign In (${_cooldownLeft}s)' : 'Sign In';
    final onSurfaceSubtle = Theme.of(
      context,
    ).colorScheme.onSurface.withOpacity(0.7);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LoadingOverlay(
          show: _busy,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  const SizedBox(height: 42),
                  // Logo
                  Image.asset(
                    'assets/icons/cargomatebluelogo.png', // make sure file exists & in pubspec
                    height: 48,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 100),

                  const Text(
                    'Enter your number',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // Country + Phone Row
                  Row(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _openCountryPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F4FF),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _country.iso2,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '+${_country.dialCode}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _numberCtl,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: InputDecoration(
                            hintText: '24XXXXXXX',
                            filled: true,
                            fillColor: const Color(0xFFF0F4FF),
                            suffixIcon: _numberCtl.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () =>
                                        setState(() => _numberCtl.clear()),
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          validator: _validateLocalNumber,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
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
                      onPressed: (_busy || isCooling) ? null : _sendCode,
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // const _OrDivider(),
                  const SizedBox(height: 12),

                  // TextButton(
                  //   onPressed: () => Navigator.pushReplacementNamed(
                  //     context,
                  //     NavRoutes.signUp,
                  //   ),
                  //   child: const Text(
                  //     'Create a new account',
                  //     style: TextStyle(
                  //       fontSize: 16,
                  //       fontWeight: FontWeight.w700,
                  //       color: Color(0xFF3D5AFE),
                  //     ),
                  //   ),
                  // ),
                  const SizedBox(height: 24),
                  Text(
                    "By signing up, you agree to our Terms & Conditions, acknowledge our Privacy Policy, "
                    "and confirm that you're over 18. We may send promotions related to our services — "
                    "you can unsubscribe anytime in Communication Settings under your profile.",
                    style: TextStyle(fontSize: 12, color: onSurfaceSubtle),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountrySheet extends StatefulWidget {
  final _Country selected;
  final ValueChanged<_Country> onSelect;
  const _CountrySheet({required this.selected, required this.onSelect});

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  final _searchCtl = TextEditingController();
  late List<_Country> _filtered;

  static const _all = <_Country>[
    _Country('Ghana', 'GH', '233'),
    _Country('Nigeria', 'NG', '234'),
    _Country('Kenya', 'KE', '254'),
    _Country('South Africa', 'ZA', '27'),
    _Country('United Kingdom', 'GB', '44'),
    _Country('United States', 'US', '1'),
    _Country('Canada', 'CA', '1'),
    _Country('France', 'FR', '33'),
    _Country('Germany', 'DE', '49'),
    _Country('India', 'IN', '91'),
    _Country('UAE', 'AE', '971'),
  ];

  @override
  void initState() {
    super.initState();
    _filtered = _all;
    _searchCtl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtl.removeListener(_onSearch);
    _searchCtl.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _searchCtl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _all
          : _all
                .where(
                  (c) =>
                      c.name.toLowerCase().contains(q) ||
                      c.iso2.toLowerCase().contains(q) ||
                      c.dialCode.contains(q),
                )
                .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected.iso2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Select your country',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchCtl,
            decoration: const InputDecoration(
              hintText: 'Search by country or code',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _filtered.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = _filtered[i];
                final isSel = c.iso2 == sel;
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(c.iso2, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  title: Text(c.name),
                  subtitle: Text('+${c.dialCode} • ${c.iso2}'),
                  trailing: isSel
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : null,
                  onTap: () {
                    widget.onSelect(c);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
