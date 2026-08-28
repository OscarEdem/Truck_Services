import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/saved_location.dart';
import '../../services/location_service.dart';
import '../../services/api_service.dart';
import '../../services/prefs.dart';
import '../../routes/navRoutes.dart';
import '../../widgets/widgets.dart';
import '../widgets/circular_selfie_camera.dart';
import '../../viewmodel/role_view_model.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final roleVm = context.watch<RoleViewModel?>();
    final role = roleVm?.role;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text(
          'Account Profile',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: user == null
          ? const Center(
              child: Text(
                'Not signed in',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            )
          : const _ProfileBody(),
      floatingActionButton: (user != null && role == 'customer')
          ? Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: const LinearGradient(
                  colors: [Color(0xFF3D5AFE), Color(0xFF2563EB)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withOpacity(0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: FloatingActionButton.extended(
                elevation: 0,
                focusElevation: 0,
                hoverElevation: 0,
                highlightElevation: 0,
                backgroundColor: Colors.transparent,
                onPressed: () => _onAddLocation(context),
                icon: const Icon(Icons.add_location_alt_rounded, color: Colors.white),
                label: const Text(
                  'Add location',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            )
          : null,
      bottomNavigationBar: MainBottomNav(currentRoute: ModalRoute.of(context)?.settings.name),
    );
  }

  static Future<void> _onAddLocation(BuildContext context) async {
    final result = await Navigator.pushNamed(context, NavRoutes.mapPicker);
    if (result is Map && result.containsKey('address')) {
      final address = result['address'] as String? ?? '';
      final lat = (result['lat'] as num?)?.toDouble() ?? 0.0;
      final lng = (result['lng'] as num?)?.toDouble() ?? 0.0;

      if (address.isEmpty || lat == 0 || lng == 0) {
        AppSnack.show(context, 'Could not get a valid location.');
        return;
      }

      final info = await showDialog<_LocationMeta>(
        context: context,
        builder: (dialogCtx) => _LocationMetaDialog(initialAddress: address),
      );
      if (info == null) return;

      try {
        await LocationService().addLocation(
          label: info.label,
          address: address,
          lat: lat,
          lng: lng,
          type: info.type,
          makeDefault: info.makeDefault,
        );
        if (!context.mounted) return;
        AppSnack.show(context, 'Location saved');
      } catch (e) {
        if (!context.mounted) return;
        AppSnack.show(context, 'Failed to save: $e');
      }
    }
  }
}

class _ProfileBody extends StatefulWidget {
  const _ProfileBody();

  @override
  State<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<_ProfileBody> {
  // ---- DETERMINISTIC PROFILE AVATAR CACHING -------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  bool _isUploading = false;
  Map<String, dynamic> _apiProfile = {};
  String? _cachedAvatarUrl;

  @override
  void initState() {
    super.initState();
    _loadCachedAvatar();
    _fetchBackendProfile();
  }

  Future<void> _loadCachedAvatar() async {
    final cached = await Prefs.I.getAvatarUrl();
    final photo = FirebaseAuth.instance.currentUser?.photoURL;
    if (mounted && ((cached != null && cached.isNotEmpty) || (photo != null && photo.isNotEmpty))) {
      setState(() {
        _cachedAvatarUrl = (cached != null && cached.isNotEmpty) ? cached : photo;
      });
    }
  }

  Future<void> _fetchBackendProfile() async {
    try {
      final me = await ApiService.I.getMe();
      if (mounted) {
        final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
        final savedRole = await Prefs.I.getRole();
        if (savedRole != null && savedRole.trim().isNotEmpty) {
          userObj['role'] = savedRole.trim();
          me['role'] = savedRole.trim();
        }

        final remote = (userObj['avatar_url'] as String? ?? userObj['avatarUrl'] as String? ?? me['avatar_url'] as String? ?? me['avatarUrl'] as String? ?? me['avatar'] as String? ?? '').trim();
        if (remote.isNotEmpty) {
          Prefs.I.setAvatarUrl(remote);
          setState(() {
            _cachedAvatarUrl = remote;
            _apiProfile = me;
          });
        } else {
          setState(() {
            _apiProfile = me;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _uploadImage({
    required String purpose, // "avatar", "selfie", "vehicle"
    required Function(String url) onSuccess,
  }) async {
    File? fileToUpload;
    String fileName = 'file_${DateTime.now().millisecondsSinceEpoch}.jpg';

    if (purpose == 'selfie') {
      final captured = await CircularSelfieCamera.show(
        context,
        title: 'Live Driver Facial Selfie',
        hintText: 'Center your face inside the circle',
      );
      if (captured == null) return;
      fileToUpload = captured;
      fileName = 'selfie_${DateTime.now().millisecondsSinceEpoch}.jpg';
    } else {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1200,
      );
      if (image == null) return;
      fileToUpload = File(image.path);
      fileName = image.name;
    }

    setState(() => _isUploading = true);
    try {
      final bytes = await fileToUpload.readAsBytes();
      final url = await ApiService.I.uploadAssetFile(bytes, fileName, purpose);
      final ext = fileName.split('.').last.toLowerCase();
      final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';
      final dataUri = 'data:$mime;base64,${base64Encode(bytes)}';

      final finalUrl = url.isNotEmpty ? url : dataUri;

      if (finalUrl.isNotEmpty) {
        if (mounted) {
          setState(() {
            if (purpose == 'avatar') {
              _apiProfile['avatar_url'] = finalUrl;
              _cachedAvatarUrl = finalUrl;
              Prefs.I.setAvatarUrl(finalUrl);
            }
            if (purpose == 'selfie') _apiProfile['driver_selfie_url'] = finalUrl;
            if (purpose == 'vehicle') {
              final photos = List<String>.from(_apiProfile['vehicle_photos'] ?? []);
              photos.add(finalUrl);
              _apiProfile['vehicle_photos'] = photos;
            }
          });
        }
        await onSuccess(finalUrl);
        if (mounted) {
          AppSnack.show(context, 'Image uploaded successfully!');
        }
      }
    } catch (e) {
      if (mounted) {
        AppSnack.show(context, 'Upload failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(
        child: Text('Not signed in', style: TextStyle(color: Color(0xFF64748B))),
      );
    }
    final roleVm = context.watch<RoleViewModel?>();
    final cachedRole = roleVm?.role;

    final profile = _apiProfile;
    final userObj = (profile['user'] is Map) ? profile['user'] as Map<String, dynamic> : profile;

    final displayName = (user.displayName ?? '').trim();
    final title = displayName.isNotEmpty
        ? displayName
        : (userObj['full_name'] as String? ?? userObj['fullName'] as String? ?? profile['full_name'] as String? ?? 'Unnamed User');

    final phone = user.phoneNumber ?? (userObj['phone'] as String? ?? userObj['phone_number'] as String? ?? profile['phone'] as String? ?? '—');
    final email = user.email ?? (userObj['email'] as String? ?? profile['email'] as String? ?? '—');

    final seed = user.phoneNumber?.replaceAll(RegExp(r'\D'), '') ?? (user.email?.isNotEmpty == true ? user.email : user.uid);
    final deterministicDefault = 'https://api.dicebear.com/7.x/adventurer/png?seed=$seed';

    var remoteAvatar = (userObj['avatar_url'] as String? ?? userObj['avatarUrl'] as String? ?? profile['avatar_url'] as String? ?? profile['avatarUrl'] as String? ?? profile['avatar'] as String? ?? user.photoURL ?? '').trim();
    var avatarUrl = (_cachedAvatarUrl != null && _cachedAvatarUrl!.isNotEmpty)
        ? _cachedAvatarUrl!
        : (remoteAvatar.isNotEmpty ? remoteAvatar : deterministicDefault);

    if (avatarUrl.contains('api.dicebear.com') && avatarUrl.contains('/svg')) {
      avatarUrl = avatarUrl.replaceAll('/svg', '/png');
    }

    final docRole = (userObj['role'] as String? ?? profile['role'] as String?)?.trim().toLowerCase();
    final activeRole = (cachedRole != null && cachedRole.trim().isNotEmpty)
        ? cachedRole.trim().toLowerCase()
        : ((docRole != null && docRole.isNotEmpty) ? docRole : 'customer');
    final isDriver = activeRole.contains('driver') || activeRole.contains('bike');

    final bool isVerified = (userObj['is_verified'] == true) ||
        (userObj['isVerified'] == true) ||
        (profile['is_verified'] == true) ||
        (profile['isVerified'] == true);

    // Driver details
    final nationalId = userObj['national_id'] as String? ?? userObj['nationalId'] as String? ?? profile['national_id'] as String? ?? '';
    final licenseNumber = userObj['license_number'] as String? ?? userObj['licenseNumber'] as String? ?? profile['license_number'] as String? ?? '';
    final driverSelfieUrl = userObj['driver_selfie_url'] as String? ?? userObj['driverSelfieUrl'] as String? ?? profile['driver_selfie_url'] as String? ?? '';
    final vehicleType = userObj['vehicle_type'] as String? ?? userObj['vehicleType'] as String? ?? profile['vehicle_type'] as String? ?? 'truck';
    final vehicleModel = userObj['vehicle_model'] as String? ?? userObj['vehicleModel'] as String? ?? profile['vehicle_model'] as String? ?? '';
    final licensePlate = userObj['license_plate'] as String? ?? userObj['licensePlate'] as String? ?? profile['license_plate'] as String? ?? '';

    final rawVehiclePhotos = userObj['vehicle_photos'] ?? userObj['vehiclePhotos'] ?? profile['vehicle_photos'] ?? profile['vehiclePhotos'];
    final vehiclePhotos = (rawVehiclePhotos is List) ? rawVehiclePhotos.cast<String>() : <String>[];

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------- PROFILE HEADER CARD -----------------------------------------------------------------------                                                                                                                                                                                #*eddiere
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Avatar with glowing ring frame
                          GestureDetector(
                            onTap: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.white,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                                ),
                                builder: (ctx) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(height: 12),
                                      Container(
                                        width: 36,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade300,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ListTile(
                                        leading: const Icon(Icons.fullscreen_rounded, color: Color(0xFF1565C0)),
                                        title: const Text('View Profile Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          FullScreenImageViewer.show(context, avatarUrl, title: 'Profile Photo');
                                        },
                                      ),
                                      ListTile(
                                        leading: const Icon(Icons.photo_camera_rounded, color: Color(0xFF059669)),
                                        title: const Text('Upload New Profile Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _uploadImage(
                                            purpose: 'avatar',
                                            onSuccess: (url) async {
                                              try {
                                                await ApiService.I.updateMe({'avatar_url': url});
                                              } catch (_) {}
                                            },
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ),
                                ),
                              );
                            },
                            child: Stack(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: isDriver
                                          ? [const Color(0xFF059669), const Color(0xFF10B981)]
                                          : [const Color(0xFF3D5AFE), const Color(0xFF60A5FA)],
                                    ),
                                  ),
                                  child: ClipOval(
                                    child: Container(
                                      width: 68,
                                      height: 68,
                                      color: Colors.white,
                                      child: _buildSmartImage(
                                        avatarUrl,
                                        width: 68,
                                        height: 68,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) {
                                          return Center(
                                            child: Text(
                                              title.isNotEmpty ? title[0].toUpperCase() : '?',
                                              style: const TextStyle(
                                                fontSize: 26,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF3D5AFE),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: isDriver ? const Color(0xFF059669) : const Color(0xFF3D5AFE),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                    child: const Icon(
                                      Icons.camera_alt_rounded,
                                      size: 13,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),

                          // Name & Role Pill
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isDriver
                                        ? (isVerified ? const Color(0xFFECFDF5) : const Color(0xFFFEF3C7))
                                        : const Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isDriver
                                          ? (isVerified ? const Color(0xFFA7F3D0) : const Color(0xFFFDE68A))
                                          : const Color(0xFFBFDBFE),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isDriver
                                            ? (isVerified ? Icons.verified_user_rounded : Icons.hourglass_top_rounded)
                                            : Icons.verified_rounded,
                                        size: 14,
                                        color: isDriver
                                            ? (isVerified ? const Color(0xFF059669) : const Color(0xFFD97706))
                                            : const Color(0xFF2563EB),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        isDriver
                                            ? (isVerified ? 'FLEET DRIVER • VERIFIED' : 'PENDING VERIFICATION')
                                            : 'PERSONAL ACCOUNT',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: isDriver
                                              ? (isVerified ? const Color(0xFF047857) : const Color(0xFFB45309))
                                              : const Color(0xFF1E40AF),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Contact Chips Container
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFF1F5F9)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  const Icon(Icons.phone_iphone_rounded, size: 16, color: Color(0xFF64748B)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      phone,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF334155),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (email.isNotEmpty && email != '—') ...[
                              Container(height: 16, width: 1, color: const Color(0xFFCBD5E1)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Row(
                                  children: [
                                    const Icon(Icons.mail_outline_rounded, size: 16, color: Color(0xFF64748B)),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        email,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF334155),
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Action Buttons Row
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                backgroundColor: const Color(0xFFEFF6FF),
                                foregroundColor: const Color(0xFF2563EB),
                                side: const BorderSide(color: Color(0xFFBFDBFE)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.edit_note_rounded, size: 18),
                              label: const Text(
                                'Edit Basic Info',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              onPressed: () async {
                                final initial = _EditProfileInitial(
                                  fullName: title == 'Unnamed User' ? '' : title,
                                  email: (email == '—') ? '' : email,
                                  role: activeRole,
                                );
                                final updated = await showDialog<_EditProfileResult>(
                                  context: context,
                                  builder: (_) => _EditProfileDialog(initial: initial),
                                );
                                if (updated == null) return;

                                try {
                                  if (updated.fullName.trim().isNotEmpty &&
                                      updated.fullName.trim() != (user.displayName ?? '')) {
                                    await user.updateDisplayName(updated.fullName.trim());
                                  }
                                  if (updated.email.trim().isNotEmpty &&
                                      updated.email.trim() != (user.email ?? '')) {
                                    try {
                                      await user.updateEmail(updated.email.trim());
                                    } catch (_) {}
                                  }

                                  final updateMap = <String, dynamic>{
                                    'full_name': updated.fullName.trim(),
                                    'email': updated.email.trim(),
                                    'role': updated.role,
                                  };

                                  await Prefs.I.setRole(updated.role);
                                  if (context.mounted) {
                                    context.read<RoleViewModel>().setRole(updated.role);
                                  }

                                  if (mounted) {
                                    setState(() {
                                      _apiProfile = {..._apiProfile, ...updateMap};
                                    });
                                  }

                                  try {
                                    await ApiService.I.updateMe(updateMap);
                                  } catch (_) {}

                                  if (!context.mounted) return;
                                  AppSnack.show(context, 'Profile updated successfully!');
                                } catch (e) {
                                  if (!context.mounted) return;
                                  AppSnack.show(context, 'Failed to update: $e');
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                backgroundColor: const Color(0xFFFEF2F2),
                                foregroundColor: const Color(0xFFEF4444),
                                side: const BorderSide(color: Color(0xFFFECACA)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.logout_rounded, size: 18),
                              label: const Text(
                                'Sign out',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              onPressed: () async {
                                try {
                                  await ApiService.I.logout();
                                } catch (_) {}
                                await FirebaseAuth.instance.signOut();
                                await Prefs.I.clearAll();
                                if (context.mounted) {
                                  context.read<RoleViewModel>().clearRole();
                                  Navigator.pushNamedAndRemoveUntil(
                                    context,
                                    NavRoutes.signIn,
                                    (route) => false,
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ---------- Verification Pending Banner ----------
              if (isDriver && !isVerified) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.amber.withOpacity(0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.hourglass_top_rounded, color: Color(0xFFD97706), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Account Verification Pending',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: Color(0xFF92400E),
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Your driver credentials, license, and selfie are currently under review. Your account will be fully activated once verified by our team.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFFB45309),
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ---------- Driver Documents & Vehicle Section ----------
                  if (isDriver) ...[
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Driver Verification & Vehicle',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_note, color: Colors.blue),
                          tooltip: 'Edit Credentials',
                          onPressed: () async {
                            final update = await _editDriverCredentials(
                              context,
                              user.uid,
                              nationalId,
                              licenseNumber,
                              vehicleType,
                              vehicleModel,
                              licensePlate,
                            );
                            if (update != null && mounted) {
                              setState(() {
                                _apiProfile = {..._apiProfile, ...update};
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // National ID & License Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.badge_outlined, color: Colors.blue),
                            title: const Text('National ID / Ghana Card'),
                            subtitle: Text(nationalId.isNotEmpty ? nationalId : 'Not uploaded yet'),
                            trailing: Icon(
                              nationalId.isNotEmpty ? Icons.check_circle : Icons.warning_amber_rounded,
                              color: nationalId.isNotEmpty ? Colors.green : Colors.orange,
                            ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.drive_eta_outlined, color: Colors.indigo),
                            title: const Text("Driver's License Number"),
                            subtitle: Text(licenseNumber.isNotEmpty ? licenseNumber : 'Not set'),
                            trailing: Icon(
                              licenseNumber.isNotEmpty ? Icons.check_circle : Icons.warning_amber_rounded,
                              color: licenseNumber.isNotEmpty ? Colors.green : Colors.orange,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Driver Selfie Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Driver Selfie', style: TextStyle(fontWeight: FontWeight.bold)),
                                TextButton.icon(
                                  icon: const Icon(Icons.upload_file, size: 18),
                                  label: Text(driverSelfieUrl.isNotEmpty ? 'Change Selfie' : 'Upload Selfie'),
                                  onPressed: () => _uploadImage(
                                    purpose: 'selfie',
                                    onSuccess: (url) async {
                                      try {
                                        await ApiService.I.updateMe({'driver_selfie_url': url});
                                      } catch (_) {}
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (driverSelfieUrl.isNotEmpty)
                              GestureDetector(
                                onTap: () => FullScreenImageViewer.show(
                                  context,
                                  driverSelfieUrl,
                                  title: 'Driver Selfie Preview',
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    alignment: Alignment.topRight,
                                    children: [
                                      _buildSmartImage(
                                        driverSelfieUrl,
                                        height: 160,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      ),
                                      Container(
                                        margin: const EdgeInsets.all(8),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.65),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                                            SizedBox(width: 4),
                                            Text(
                                              'Tap to Preview',
                                              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              Container(
                                height: 80,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: const Center(
                                  child: Text('No selfie uploaded', style: TextStyle(color: Colors.grey)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Vehicle Specifications Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Vehicle Info', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: _infoTile('Type', vehicleType.toUpperCase(), Icons.local_shipping),
                                ),
                                Expanded(
                                  child: _infoTile('Model', vehicleModel.isNotEmpty ? vehicleModel : '—', Icons.minor_crash),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _infoTile('License Plate', licensePlate.isNotEmpty ? licensePlate : '—', Icons.pin),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Vehicle Photos Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Vehicle Photos (2+ Required)', style: TextStyle(fontWeight: FontWeight.bold)),
                                TextButton.icon(
                                  icon: const Icon(Icons.add_a_photo, size: 18),
                                  label: const Text('Add Photo'),
                                  onPressed: () => _uploadImage(
                                    purpose: 'vehicle',
                                    onSuccess: (url) async {
                                      final updatedPhotos = List<String>.from(vehiclePhotos)..add(url);
                                      try {
                                        await ApiService.I.updateMe({'vehicle_photos': updatedPhotos});
                                      } catch (_) {}
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (vehiclePhotos.isNotEmpty)
                              SizedBox(
                                height: 100,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: vehiclePhotos.length,
                                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                                  itemBuilder: (ctx, i) => GestureDetector(
                                    onTap: () => FullScreenImageViewer.show(
                                      context,
                                      vehiclePhotos[i],
                                      title: 'Vehicle Photo ${i + 1}',
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Stack(
                                        alignment: Alignment.topRight,
                                        children: [
                                          _buildSmartImage(
                                            vehiclePhotos[i],
                                            width: 120,
                                            height: 100,
                                            fit: BoxFit.cover,
                                          ),
                                          Container(
                                            margin: const EdgeInsets.all(4),
                                            padding: const EdgeInsets.all(4),
                                            decoration: const BoxDecoration(
                                              color: Colors.black54,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.zoom_in_rounded,
                                              color: Colors.white,
                                              size: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              Container(
                                height: 80,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: const Center(
                                  child: Text('No vehicle photos uploaded', style: TextStyle(color: Colors.grey)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // ---------- Customer Saved Locations ----------
                  if (!isDriver) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Saved locations',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    _LocationsList(),
                  ],
                ],
              ),
            ),

            if (_isUploading)
              Container(
                color: Colors.black45,
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Uploading asset to server...'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
  }

  Widget _buildSmartImage(
    String url, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
  }) {
    if (url.startsWith('data:')) {
      try {
        final base64Data = url.split(',').last;
        return Image.memory(
          base64Decode(base64Data),
          width: width,
          height: height,
          fit: fit,
          errorBuilder: errorBuilder,
        );
      } catch (_) {}
    }
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: errorBuilder,
    );
  }

  Widget _infoTile(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.blue.shade700),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ],
    );
  }

  Future<Map<String, dynamic>?> _editDriverCredentials(
    BuildContext context,
    String uid,
    String currentNationalId,
    String currentLicense,
    String currentVehicleType,
    String currentModel,
    String currentPlate,
  ) async {
    final natCtl = TextEditingController(text: currentNationalId);
    final licCtl = TextEditingController(text: currentLicense);
    final modCtl = TextEditingController(text: currentModel);
    final pltCtl = TextEditingController(text: currentPlate);
    String vType = currentVehicleType.isNotEmpty ? currentVehicleType : 'truck';

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Driver & Vehicle Credentials'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: natCtl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                  LengthLimitingTextInputFormatter(20),
                  TextInputFormatter.withFunction((_, newVal) => newVal.copyWith(text: newVal.text.toUpperCase())),
                ],
                decoration: const InputDecoration(
                  labelText: 'National ID / ECOWAS Card',
                  hintText: 'e.g. GHA-727278797-5 or 12345678901',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: licCtl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                  LengthLimitingTextInputFormatter(18),
                  TextInputFormatter.withFunction((_, newVal) => newVal.copyWith(text: newVal.text.toUpperCase())),
                ],
                decoration: const InputDecoration(
                  labelText: "Driver's License Number",
                  hintText: 'DL-12345678',
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: vType,
                decoration: const InputDecoration(labelText: 'Vehicle Type'),
                items: const [
                  DropdownMenuItem(value: 'bike', child: Text('Bike / Motorcycle')),
                  DropdownMenuItem(value: 'van', child: Text('Delivery Van')),
                  DropdownMenuItem(value: 'truck', child: Text('Heavy Truck')),
                ],
                onChanged: (v) => vType = v ?? 'truck',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: modCtl,
                decoration: const InputDecoration(labelText: 'Vehicle Model (e.g. Mercedes Actros)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: pltCtl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                  LengthLimitingTextInputFormatter(12),
                  TextInputFormatter.withFunction((_, newVal) => newVal.copyWith(text: newVal.text.toUpperCase())),
                ],
                decoration: const InputDecoration(labelText: 'License Plate (e.g. GW-9821-25)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final nat = natCtl.text.trim().toUpperCase();
              final lic = licCtl.text.trim().toUpperCase();
              final plt = pltCtl.text.trim().toUpperCase();
              
              if (nat.isNotEmpty && (nat.length < 6 || nat.length > 20 || !RegExp(r'^[A-Z0-9\-]+$').hasMatch(nat))) {
                AppSnack.show(ctx, 'National ID must be 6-20 alphanumeric characters');
                return;
              }
              if (lic.isNotEmpty && (lic.length < 6 || !RegExp(r'^[A-Z0-9\-]+$').hasMatch(lic))) {
                AppSnack.show(ctx, 'License number must be 6-18 characters');
                return;
              }
              if (plt.isNotEmpty && (plt.length < 4 || !RegExp(r'^[A-Z0-9\-]+$').hasMatch(plt))) {
                AppSnack.show(ctx, 'License plate format invalid (e.g. GW-9821-25)');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Save Credentials'),
          ),
        ],
      ),
    );

    if (save == true) {
      final updateMap = {
        'national_id': natCtl.text.trim().toUpperCase(),
        'license_number': licCtl.text.trim().toUpperCase(),
        'vehicle_type': vType,
        'vehicle_model': modCtl.text.trim(),
        'license_plate': pltCtl.text.trim().toUpperCase(),
      };

      try {
        await ApiService.I.updateMe(updateMap);
        if (mounted) {
          setState(() {
            _apiProfile.addAll(updateMap);
          });
        }
      } catch (e) {
        debugPrint('[UPDATE_DRIVER_ERR] $e');
      }

      if (context.mounted) {
        AppSnack.show(context, 'Driver & vehicle details saved');
      }
      return updateMap;
    }
    return null;
  }
}

// ---- SAVED LOCATIONS LIST ------------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
class _LocationsList extends StatelessWidget {
  final _svc = LocationService();
  _LocationsList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SavedLocation>>(
      stream: _svc.streamLocations(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF2FF),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFC7D2FE), width: 1.5),
                  ),
                  child: const Icon(
                    Icons.location_off_rounded,
                    size: 30,
                    color: Color(0xFF3D5AFE),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'No saved locations yet',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Add your Home, Work, or favorite places for quicker 1-tap bookings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          separatorBuilder: (ctx2, _) => const SizedBox(height: 10),
          itemBuilder: (itemCtx, i) {
            final loc = items[i];
            return Dismissible(
              key: Key(loc.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('Delete', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
                    SizedBox(width: 8),
                    Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444)),
                  ],
                ),
              ),
              confirmDismiss: (direction) async {
                return await showDialog<bool>(
                      context: itemCtx,
                      builder: (dialogCtx) => AlertDialog(
                        title: const Text('Delete location?'),
                        content: Text('Remove "${loc.label}" from saved locations.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(dialogCtx, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
              },
              onDismissed: (direction) async {
                await _svc.deleteLocation(loc.id);
                AppSnack.show(itemCtx, 'Deleted "${loc.label}"');
              },
              child: _LocationTile(
                loc: loc,
                onSetDefault: () async {
                  await _svc.setDefault(loc);
                  if (!itemCtx.mounted) return;
                  AppSnack.show(itemCtx, '"${loc.label}" set as default');
                },
                onEdit: () async {
                  final edited = await showDialog<_LocationMeta>(
                    context: itemCtx,
                    builder: (dialogCtx) => _LocationMetaDialog(
                      initialAddress: loc.address,
                      initialLabel: loc.label,
                      initialType: loc.type,
                      editing: true,
                    ),
                  );
                  if (edited != null) {
                    await _svc.updateLocation(
                      loc,
                      label: edited.label,
                      type: edited.type,
                    );
                    if (!itemCtx.mounted) return;
                    AppSnack.show(itemCtx, 'Updated "${edited.label}"');
                  }
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _LocationTile extends StatelessWidget {
  final SavedLocation loc;
  final VoidCallback onSetDefault;
  final VoidCallback onEdit;
  const _LocationTile({
    required this.loc,
    required this.onSetDefault,
    required this.onEdit,
  });

  IconData get _icon {
    switch (loc.type) {
      case 'home':
        return Icons.home_rounded;
      case 'work':
        return Icons.work_rounded;
      default:
        return Icons.place_rounded;
    }
  }

  Color get _categoryColor {
    switch (loc.type) {
      case 'home':
        return const Color(0xFF2563EB);
      case 'work':
        return const Color(0xFF7C3AED);
      default:
        return const Color(0xFF059669);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: loc.isDefault ? const Color(0xFF3D5AFE) : const Color(0xFFE2E8F0),
          width: loc.isDefault ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _categoryColor.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(_icon, color: _categoryColor, size: 22),
        ),
        title: Row(
          children: [
            Text(
              loc.label.isNotEmpty ? loc.label : 'Saved place',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Color(0xFF0F172A),
              ),
            ),
            if (loc.isDefault) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: const Text(
                  'DEFAULT',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2563EB),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          loc.address,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF64748B)),
          onSelected: (v) {
            if (v == 'default') onSetDefault();
            if (v == 'edit') onEdit();
          },
          itemBuilder: (popupCtx) => [
            if (!loc.isDefault)
              const PopupMenuItem(
                value: 'default',
                child: Row(
                  children: [
                    Icon(Icons.star_outline_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Set as default'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Edit name/type'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationMeta {
  final String label;
  final String type;
  final bool makeDefault;
  const _LocationMeta({
    required this.label,
    required this.type,
    required this.makeDefault,
  });
}

class _LocationMetaDialog extends StatefulWidget {
  final String initialAddress;
  final String? initialLabel;
  final String? initialType;
  final bool editing;
  const _LocationMetaDialog({
    required this.initialAddress,
    this.initialLabel,
    this.initialType,
    this.editing = false,
  });

  @override
  State<_LocationMetaDialog> createState() => _LocationMetaDialogState();
}

class _LocationMetaDialogState extends State<_LocationMetaDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelCtl;
  String _type = 'other';
  bool _makeDefault = false;

  @override
  void initState() {
    super.initState();
    _labelCtl = TextEditingController(text: widget.initialLabel ?? '');
    _type = widget.initialType ?? 'other';
  }

  @override
  void dispose() {
    _labelCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.editing ? 'Edit location' : 'Save this place'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.initialAddress,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _labelCtl,
                decoration: const InputDecoration(
                  labelText: 'Label (e.g., Home, Office)',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a label' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'home', child: Text('Home')),
                  DropdownMenuItem(value: 'work', child: Text('Work')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'other'),
              ),
              if (!widget.editing) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _makeDefault,
                  onChanged: (v) => setState(() => _makeDefault = v ?? false),
                  title: const Text('Make default location'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _LocationMeta(
                label: _labelCtl.text.trim(),
                type: _type,
                makeDefault: _makeDefault,
              ),
            );
          },
          child: Text(widget.editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _EditProfileInitial {
  final String fullName;
  final String email;
  final String role;
  const _EditProfileInitial({required this.fullName, required this.email, required this.role});
}

class _EditProfileResult {
  final String fullName;
  final String email;
  final String role;
  const _EditProfileResult({required this.fullName, required this.email, required this.role});
}

class _EditProfileDialog extends StatefulWidget {
  final _EditProfileInitial initial;
  const _EditProfileDialog({required this.initial});

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtl;
  late final TextEditingController _emailCtl;
  late String _role;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.initial.fullName);
    _emailCtl = TextEditingController(text: widget.initial.email);
    _role = widget.initial.role.toLowerCase().contains('driver') ? 'driver' : 'customer';
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _emailCtl.dispose();
    super.dispose();
  }

  bool _looksLikeEmail(String s) {
    final x = s.trim();
    if (x.isEmpty) return true;
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return re.hasMatch(x);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Profile Details'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameCtl,
                decoration: const InputDecoration(labelText: 'Full name'),
                textCapitalization: TextCapitalization.words,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Please enter your name'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailCtl,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
                validator: (v) => _looksLikeEmail(v ?? '')
                    ? null
                    : 'Enter a valid email (or leave empty)',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _EditProfileResult(
                fullName: _nameCtl.text.trim(),
                email: _emailCtl.text.trim(),
                role: _role,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
