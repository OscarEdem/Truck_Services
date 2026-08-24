import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

import '../../widgets/widgets.dart';
import '../../routes/navRoutes.dart';
import '../../services/prefs.dart';
import '../../services/api_service.dart';
import '../../viewmodel/role_view_model.dart';
import '../../models/otp_args.dart'; // ✅ for pushing to OTP

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

/// Lightweight country model (matches Sign In)
class _Country {
  final String name, iso2, dialCode, flag;
  const _Country(this.name, this.iso2, this.dialCode, this.flag);
}

class _SignUpScreenState extends State<SignUpScreen> {
  // --- Profile form ---
  final _formKey = GlobalKey<FormState>();
  final _firstCtl = TextEditingController();
  final _lastCtl = TextEditingController();
  final _emailCtl = TextEditingController();

  DateTime? _dob;
  String _role = 'customer';
  bool _busy = false;
  bool _accepted = false;

  // --- 3-Step Driver Compliance Multi-Step Form ---
  int _currentStep = 0; // 0: Basic Identity, 1: KYC Documents, 2: Vehicle Specs
  String? _avatarUrl;
  String? _driverSelfieUrl;
  final _nationalIdCtl = TextEditingController();
  final _licenseNumberCtl = TextEditingController();

  String _vehicleType = 'truck'; // 'bike' | 'van' | 'truck'
  final _vehicleModelCtl = TextEditingController();
  final _licensePlateCtl = TextEditingController();
  final List<String> _vehiclePhotos = [];
  bool _isUploadingAsset = false;

  // --- Phone / OTP (same UX as Sign In) ---
  final _auth = FirebaseAuth.instance;

  final _numberCtl = TextEditingController();
  _Country _country = const _Country('Ghana', 'GH', '233', '🇬🇭');

  bool _sending = false;
  DateTime? _lastSendAt;
  static const _cooldown = Duration(seconds: 30);
  int _cooldownLeft = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _firstCtl.dispose();
    _lastCtl.dispose();
    _emailCtl.dispose();
    _numberCtl.dispose();
    _nationalIdCtl.dispose();
    _licenseNumberCtl.dispose();
    _vehicleModelCtl.dispose();
    _licensePlateCtl.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _pickAndUploadAsset({
    required String purpose,
    ImageSource source = ImageSource.gallery,
  }) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1200,
    );
    if (image == null) return;

    setState(() => _isUploadingAsset = true);
    try {
      final bytes = await image.readAsBytes();
      final url = await ApiService.I.uploadAssetFile(bytes, image.name, purpose);
      final ext = image.name.split('.').last.toLowerCase();
      final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';
      final dataUri = 'data:$mime;base64,${base64Encode(bytes)}';
      final finalUrl = url.isNotEmpty ? url : dataUri;

      if (finalUrl.isNotEmpty && mounted) {
        setState(() {
          if (purpose == 'avatar') _avatarUrl = finalUrl;
          if (purpose == 'selfie') _driverSelfieUrl = finalUrl;
          if (purpose == 'vehicle') _vehiclePhotos.add(finalUrl);
        });
        AppSnack.show(context, 'Uploaded successfully!');
      }
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _isUploadingAsset = false);
    }
  }

  bool _isAdult(DateTime? dob) {
    if (dob == null) return false;
    final now = DateTime.now();
    int years = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      years--;
    }
    return years >= 18;
  }

  Future<void> _pickDob() async {
    final today = DateTime.now();
    final latestAllowed = DateTime(today.year - 18, today.month, today.day);
    final initial = _dob ?? latestAllowed;
    final firstDate = DateTime(today.year - 80);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: latestAllowed,
      helpText: 'Select Date of Birth (18+)',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  // Phone: enforce EXACTLY 9 digits
  String? _validateLocalNumber(String? v) {
    final s = (v ?? '').replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return 'Enter your phone number';
    if (!RegExp(r'^[0-9]{9}$').hasMatch(s)) return 'Enter exactly 9 digits';
    return null;
  }

  String get _fullE164 {
    final local = _numberCtl.text.replaceAll(RegExp(r'[^0-9]'), '');
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

  void _showAccountTypeDetailsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Account Types & Benefits',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEFF6FF),
                    child: Icon(Icons.inventory_2_rounded, color: Color(0xFF2563EB)),
                  ),
                  title: const Text('Shipper / Customer', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Book doorstep pickups for parcels, cargo vans, or heavy freight trucks with instant price estimates.'),
                  onTap: () {
                    setState(() => _role = 'customer');
                    Navigator.pop(context);
                  },
                ),
                const Divider(height: 24),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFECFDF5),
                    child: Icon(Icons.directions_bus_outlined, color: Color(0xFF059669)),
                  ),
                  title: const Text('Driver & Logistics Partner', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text('Earn daily fares accepting nearby delivery requests for Motorbikes, Vans, or Heavy Trucks.'),
                  onTap: () {
                    setState(() => _role = 'driver');
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ----------------- OTP Send (for users not yet signed-in) -----------------

  Future<void> _sendCode() async {
    // Validate only the phone when sending OTP
    if (!_validateLocalNumber(_numberCtl.text).isNullOrEmpty) {
      final msg = _validateLocalNumber(_numberCtl.text)!;
      AppSnack.show(context, msg);
      return;
    }
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

  // ----------------- Complete Profile (for users already signed-in) -----------------
  Future<void> _complete() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isAdult(_dob)) {
      AppSnack.show(context, 'You must be at least 18 years old to continue.');
      return;
    }
    if (!_accepted) {
      AppSnack.show(context, 'Please accept the Terms to continue.');
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      AppSnack.show(context, 'Verify your phone first.');
      return;
    }

    // Driver Compliance Validations
    if (_role != 'customer') {
      if (_avatarUrl == null || _avatarUrl!.isEmpty) {
        AppSnack.show(context, 'Driver profile photo (avatar) is required');
        setState(() => _currentStep = 1);
        return;
      }
      if (_driverSelfieUrl == null || _driverSelfieUrl!.isEmpty) {
        AppSnack.show(context, 'Driver verification selfie photo is required');
        setState(() => _currentStep = 1);
        return;
      }
      if (_nationalIdCtl.text.trim().isEmpty) {
        AppSnack.show(context, 'National ID number is required');
        setState(() => _currentStep = 1);
        return;
      }
      if (_licenseNumberCtl.text.trim().isEmpty) {
        AppSnack.show(context, 'Driver license number is required');
        setState(() => _currentStep = 1);
        return;
      }
      if (_vehicleModelCtl.text.trim().isEmpty) {
        AppSnack.show(context, 'Vehicle make & model is required');
        setState(() => _currentStep = 2);
        return;
      }
      if (_licensePlateCtl.text.trim().isEmpty) {
        AppSnack.show(context, 'Vehicle license plate number is required');
        setState(() => _currentStep = 2);
        return;
      }
      if (_vehiclePhotos.length < 2) {
        AppSnack.show(context, 'At least 2 photos of the vehicle are required');
        setState(() => _currentStep = 2);
        return;
      }
    }

    setState(() => _busy = true);
    try {
      final first = _firstCtl.text.trim();
      final last = _lastCtl.text.trim();
      final email = _emailCtl.text.trim();
      final displayName = '$first $last'.trim();

      if (displayName.isNotEmpty) {
        await user.updateDisplayName(displayName);
      }

      final savedPhone = await Prefs.I.getPhone();
      final phone = (user.phoneNumber != null && user.phoneNumber!.isNotEmpty)
          ? user.phoneNumber!
          : ((savedPhone != null && savedPhone.isNotEmpty) ? savedPhone : _fullE164);

      final regRes = await ApiService.I.register(
        phone: phone,
        fullName: displayName,
        role: _role,
        email: email,
        avatarUrl: _avatarUrl,
        nationalId: _nationalIdCtl.text.trim(),
        licenseNumber: _licenseNumberCtl.text.trim(),
        driverSelfieUrl: _driverSelfieUrl,
        vehicleType: _vehicleType,
        vehicleModel: _vehicleModelCtl.text.trim(),
        licensePlate: _licensePlateCtl.text.trim(),
        vehiclePhotos: _vehiclePhotos,
      );

      final token = regRes['token'] as String?;
      if (token != null && token.isNotEmpty) {
        await Prefs.I.setToken(token);
      }

      await Prefs.I.setUid(user.uid);
      await Prefs.I.setPhone(phone);
      await Prefs.I.setRole(_role);
      await Prefs.I.setHasProfile(true);

      if (mounted) context.read<RoleViewModel>().setRole(_role);

      if (!mounted) return;
      if (_role == 'driver' || _role == 'bikeRider') {
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
    } catch (e) {
      AppSnack.show(context, 'Could not save profile: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ----------------- UI -----------------
  @override
  Widget build(BuildContext context) {
    final phoneAuthed = FirebaseAuth.instance.currentUser?.phoneNumber;
    final isSignedIn = phoneAuthed != null && phoneAuthed.isNotEmpty;

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
                  const SizedBox(height: 8),
                  Image.asset(
                    'assets/icons/cargomatebluelogo.png',
                    height: 48,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 24),

                  const Text(
                    'Create a new account',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Use your real name so that drivers can identify you faster and easier. '
                    'This helps make your rides safer.',
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 24),

                  // ---- Phone area ----
                  if (!isSignedIn) ...[
                    // Country + Phone Row (same look as Sign In)
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
                                  _country.flag,
                                  style: const TextStyle(fontSize: 18),
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
                              LengthLimitingTextInputFormatter(
                                9,
                              ), // ✅ exactly 9 digits
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
                    const SizedBox(height: 16),
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
                        onPressed: (_busy || _isCoolingDown())
                            ? null
                            : _sendCode,
                        child: Text(
                          _isCoolingDown()
                              ? 'Verify number (${_cooldownLeft}s)'
                              : 'Verify number',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _OrDivider(),
                    const SizedBox(height: 16),
                  ] else ...[
                    // Already verified via OTP
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Phone: $phoneAuthed',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ---- 3-Step Progress Stepper Header for Drivers ----
                  if (_role != 'customer') ...[
                    _buildStepperHeader(),
                    const SizedBox(height: 16),
                  ],

                  // ---- STEP 0: IDENTITY & ACCOUNT TYPE ----
                  if (_currentStep == 0) ...[
                    _filledField(
                      controller: _firstCtl,
                      label: 'First name',
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter first name' : null,
                      capitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 12),
                    _filledField(
                      controller: _lastCtl,
                      label: 'Last name',
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter last name' : null,
                      capitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 12),
                    _filledField(
                      controller: _emailCtl,
                      label: 'Email (optional)',
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return null;
                        return RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s) ? null : 'Enter a valid email';
                      },
                    ),
                    const SizedBox(height: 12),

                    _buildRoleSelectionBlend(),
                    const SizedBox(height: 12),

                    InkWell(
                      onTap: _pickDob,
                      child: InputDecorator(
                        decoration: _filledDecoration('Date of Birth (18+)'),
                        child: Text(
                          _dob == null
                              ? 'Tap to select'
                              : '${_dob!.year}-${_dob!.month.toString().padLeft(2, '0')}-${_dob!.day.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: _dob == null ? Colors.grey : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: _accepted,
                          onChanged: (v) => setState(() => _accepted = v ?? false),
                        ),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: Theme.of(context).textTheme.bodyMedium,
                              children: const [
                                TextSpan(text: 'I agree to the '),
                                TextSpan(text: 'Terms of Service', style: TextStyle(decoration: TextDecoration.underline)),
                                TextSpan(text: ' and '),
                                TextSpan(text: 'Privacy Policy', style: TextStyle(decoration: TextDecoration.underline)),
                                TextSpan(text: '.'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: const Color(0xFF3D5AFE),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: () {
                          if (!_formKey.currentState!.validate()) return;
                          if (!_isAdult(_dob)) {
                            AppSnack.show(context, 'You must be at least 18 years old to continue.');
                            return;
                          }
                          if (!_accepted) {
                            AppSnack.show(context, 'Please accept the Terms to continue.');
                            return;
                          }

                          if (_role == 'customer') {
                            _complete();
                          } else {
                            setState(() => _currentStep = 1);
                          }
                        },
                        child: Text(
                          _role == 'customer' ? 'Sign Up 🚀' : 'Next: Driver KYC (1/3) ➔',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],

                  // ---- STEP 1: DRIVER KYC & COMPLIANCE DOCUMENTS ----
                  if (_currentStep == 1 && _role != 'customer') ...[
                    _buildStep1KycView(),
                  ],

                  // ---- STEP 2: VEHICLE SPECS & PHOTOS ----
                  if (_currentStep == 2 && _role != 'customer') ...[
                    _buildStep2VehicleView(),
                  ],

                  const SizedBox(height: 24),
                  const _OrDivider(),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pushReplacementNamed(
                      context,
                      NavRoutes.signIn,
                    ),
                    child: const Text(
                      'Sign In',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3D5AFE),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Stepper Progress Indicator ----
  Widget _buildStepperHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _stepDot(0, '1. Identity'),
          const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Color(0xFF94A3B8)),
          _stepDot(1, '2. KYC Docs'),
          const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Color(0xFF94A3B8)),
          _stepDot(2, '3. Vehicle'),
        ],
      ),
    );
  }

  Widget _stepDot(int index, String label) {
    final active = _currentStep == index;
    final done = _currentStep > index;
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? const Color(0xFF10B981)
                : (active ? const Color(0xFF3D5AFE) : const Color(0xFFCBD5E1)),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : Text(
                    '${index + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.w500,
            color: active ? const Color(0xFF1E293B) : const Color(0xFF64748B),
          ),
        ),
      ],
    );
  }

  // ---- Role Selection Blend ----
  Widget _buildRoleSelectionBlend() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Account Type',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
          ),
        ),
        const SizedBox(height: 8),

        Container(
          height: 48,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _role = 'customer';
                    _currentStep = 0;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: _role == 'customer' ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: _role == 'customer'
                          ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))]
                          : [],
                    ),
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.local_shipping_outlined, size: 18, color: _role == 'customer' ? const Color(0xFF2563EB) : const Color(0xFF64748B)),
                          const SizedBox(width: 6),
                          Text(
                            'Ship Cargo',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _role == 'customer' ? const Color(0xFF1E40AF) : const Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (_role == 'customer') _role = 'driver';
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: _role != 'customer' ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: _role != 'customer'
                          ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))]
                          : [],
                    ),
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.directions_bus_outlined, size: 18, color: _role != 'customer' ? const Color(0xFF059669) : const Color(0xFF64748B)),
                          const SizedBox(width: 6),
                          Text(
                            'Drive & Earn',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _role != 'customer' ? const Color(0xFF065F46) : const Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _role == 'customer' ? const Color(0xFFEFF6FF) : const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _role == 'customer' ? const Color(0xFF3B82F6) : const Color(0xFF10B981),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _role == 'customer' ? const Color(0xFF2563EB) : const Color(0xFF059669),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _role == 'customer' ? Icons.inventory_2_rounded : Icons.badge_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _role == 'customer' ? 'Personal & Business Shipper' : 'Fleet Driver & Logistics Partner',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: _role == 'customer' ? const Color(0xFF1E3A8A) : const Color(0xFF064E3B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _role == 'customer'
                          ? 'Book motorbikes, vans, & freight trucks for quick doorstep deliveries.'
                          : 'Accept nearby delivery jobs and earn daily income on your schedule.',
                      style: TextStyle(
                        fontSize: 11,
                        color: _role == 'customer' ? const Color(0xFF3B82F6) : const Color(0xFF047857),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        if (_role != 'customer') ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ChoiceChip(
                  label: const Text('🏍️ Bike', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  selected: _role == 'bikeRider',
                  onSelected: (_) => setState(() {
                    _role = 'bikeRider';
                    _vehicleType = 'bike';
                  }),
                  selectedColor: const Color(0xFFA7F3D0),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ChoiceChip(
                  label: const Text('🚐 Van / Truck', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  selected: _role == 'driver',
                  onSelected: (_) => setState(() => _role = 'driver'),
                  selectedColor: const Color(0xFFA7F3D0),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 8),
        GestureDetector(
          onTap: _showAccountTypeDetailsSheet,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF2563EB)),
              SizedBox(width: 4),
              Text(
                'Compare account types & benefits',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2563EB),
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- STEP 1: DRIVER KYC & COMPLIANCE VIEW ----
  Widget _buildStep1KycView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Driver Verification & Identity',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
        ),
        const SizedBox(height: 4),
        const Text(
          'Upload official government documents and a live selfie for safety verification.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),

        // Avatar Upload Box
        const Text('1. Profile Photo (avatar_url)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _pickAndUploadAsset(purpose: 'avatar', source: ImageSource.gallery),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _avatarUrl != null ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 1.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 50,
                    height: 50,
                    color: const Color(0xFFE2E8F0),
                    child: _avatarUrl != null
                        ? SmartAvatar(url: _avatarUrl, name: 'Avatar', radius: 25)
                        : const Icon(Icons.add_a_photo_rounded, color: Color(0xFF64748B)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _avatarUrl != null ? 'Profile Photo Uploaded ✅' : 'Tap to select Profile Picture',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _avatarUrl != null ? const Color(0xFF047857) : const Color(0xFF334155),
                        ),
                      ),
                      const Text('Clear facial view required', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Facial Selfie Box
        const Text('2. Live Driver Facial Selfie (driver_selfie_url)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _pickAndUploadAsset(purpose: 'selfie', source: ImageSource.camera),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _driverSelfieUrl != null ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 1.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 50,
                    height: 50,
                    color: const Color(0xFFE2E8F0),
                    child: _driverSelfieUrl != null
                        ? SmartAvatar(url: _driverSelfieUrl, name: 'Selfie', radius: 25)
                        : const Icon(Icons.camera_front_rounded, color: Color(0xFF059669)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _driverSelfieUrl != null ? 'Selfie Proof Captured ✅' : 'Take Facial Verification Selfie',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _driverSelfieUrl != null ? const Color(0xFF047857) : const Color(0xFF334155),
                        ),
                      ),
                      const Text('Tap to launch camera snapshot', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                const Icon(Icons.camera_alt_rounded, color: Color(0xFF059669)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        _filledField(
          controller: _nationalIdCtl,
          label: 'National ID / Ghana Card Number (national_id)',
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter National ID number' : null,
        ),
        const SizedBox(height: 12),
        _filledField(
          controller: _licenseNumberCtl,
          label: 'Driver License Number (license_number)',
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter driver license number' : null,
        ),
        const SizedBox(height: 20),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => setState(() => _currentStep = 0),
                child: const Text('⬅ Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF3D5AFE),
                ),
                onPressed: () {
                  if (_avatarUrl == null || _avatarUrl!.isEmpty) {
                    AppSnack.show(context, 'Please upload profile photo first.');
                    return;
                  }
                  if (_driverSelfieUrl == null || _driverSelfieUrl!.isEmpty) {
                    AppSnack.show(context, 'Please capture live selfie first.');
                    return;
                  }
                  if (_nationalIdCtl.text.trim().isEmpty || _licenseNumberCtl.text.trim().isEmpty) {
                    AppSnack.show(context, 'Enter National ID & License number.');
                    return;
                  }
                  setState(() => _currentStep = 2);
                },
                child: const Text('Next: Vehicle (2/3) ➔', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- STEP 2: VEHICLE SPECS & PHOTOS VIEW ----
  Widget _buildStep2VehicleView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Vehicle Specifications & Photos',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
        ),
        const SizedBox(height: 4),
        const Text(
          'Provide details and upload at least 2 clear photos of your vehicle.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),

        const Text('Vehicle Category (vehicle_type)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'bike', label: Text('🏍️ Bike'), icon: Icon(Icons.two_wheeler)),
            ButtonSegment(value: 'van', label: Text('🚐 Van'), icon: Icon(Icons.airport_shuttle)),
            ButtonSegment(value: 'truck', label: Text('🚛 Truck'), icon: Icon(Icons.local_shipping)),
          ],
          selected: {_vehicleType},
          onSelectionChanged: (s) => setState(() => _vehicleType = s.first),
        ),
        const SizedBox(height: 14),

        _filledField(
          controller: _vehicleModelCtl,
          label: 'Vehicle Model (e.g. Mercedes Benz Actros)',
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter vehicle model' : null,
        ),
        const SizedBox(height: 12),
        _filledField(
          controller: _licensePlateCtl,
          label: 'Registration License Plate (e.g. GW-9821-25)',
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter license plate' : null,
        ),
        const SizedBox(height: 16),

        // Vehicle Photos Upload Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Vehicle Photos (vehicle_photos)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Text(
              '${_vehiclePhotos.length} / 2 required',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: _vehiclePhotos.length >= 2 ? const Color(0xFF059669) : Colors.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._vehiclePhotos.map(
              (photoUrl) => Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 80,
                      height: 80,
                      color: const Color(0xFFE2E8F0),
                      child: SmartAvatar(url: photoUrl, name: 'Vehicle', radius: 40),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => setState(() => _vehiclePhotos.remove(photoUrl)),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        child: const Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _pickAndUploadAsset(purpose: 'vehicle', source: ImageSource.gallery),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF94A3B8), style: BorderStyle.solid),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: Color(0xFF2563EB)),
                    SizedBox(height: 2),
                    Text('Add Photo', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => setState(() => _currentStep = 1),
                child: const Text('⬅ Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF059669),
                ),
                onPressed: _complete,
                child: const Text('Submit Driver Profile 🚀', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- Shared filled field styles (light blue like Sign In) ---
  InputDecoration _filledDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFFF0F4FF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _filledField({
    required TextEditingController controller,
    required String label,
    TextCapitalization capitalization = TextCapitalization.none,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      textCapitalization: capitalization,
      keyboardType: keyboardType,
      decoration: _filledDecoration(label),
      validator: validator,
    );
  }
}

// ----------------- Light blue OR divider -----------------
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).dividerColor;
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: c)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('OR', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        Expanded(child: Container(height: 1, color: c)),
      ],
    );
  }
}

// ----------------- Country picker (same as Sign In) -----------------
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
    _Country('Ghana', 'GH', '233', '🇬🇭'),
    _Country('Nigeria', 'NG', '234', '🇳🇬'),
    _Country('Kenya', 'KE', '254', '🇰🇪'),
    _Country('South Africa', 'ZA', '27', '🇿🇦'),
    _Country('United Kingdom', 'GB', '44', '🇬🇧'),
    _Country('United States', 'US', '1', '🇺🇸'),
    _Country('Canada', 'CA', '1', '🇨🇦'),
    _Country('France', 'FR', '33', '🇫🇷'),
    _Country('Germany', 'DE', '49', '🇩🇪'),
    _Country('India', 'IN', '91', '🇮🇳'),
    _Country('UAE', 'AE', '971', '🇦🇪'),
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
                  leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
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

// ----------------- tiny helper -----------------
extension _StrNullX on String? {
  bool get isNullOrEmpty => this == null || this!.isEmpty;
}
