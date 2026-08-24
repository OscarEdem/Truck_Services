import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/saved_location.dart';
import '../../services/location_service.dart';
import '../../services/api_service.dart';
import '../../services/prefs.dart';
import '../../routes/navRoutes.dart';
import '../../widgets/widgets.dart';
import '../../viewmodel/role_view_model.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final roleVm = context.watch<RoleViewModel?>();
    final role = roleVm?.role;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile & Credentials'), centerTitle: true),
      body: user == null
          ? const Center(child: Text('Not signed in'))
          : const _ProfileBody(),
      floatingActionButton: (user != null && role == 'customer')
          ? FloatingActionButton.extended(
              onPressed: () => _onAddLocation(context),
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Add location'),
            )
          : null,
      bottomNavigationBar: (role == 'customer')
          ? MainBottomNav(currentRoute: ModalRoute.of(context)?.settings.name)
          : null,
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
  bool _isUploading = false;
  Map<String, dynamic> _apiProfile = {};

  @override
  void initState() {
    super.initState();
    _fetchBackendProfile();
  }

  Future<void> _fetchBackendProfile() async {
    try {
      final me = await ApiService.I.getMe();
      if (mounted) {
        setState(() {
          _apiProfile = me;
        });
      }
    } catch (_) {}
  }

  Future<void> _uploadImage({
    required String purpose, // "avatar", "selfie", "vehicle"
    required Function(String url) onSuccess,
  }) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1200,
    );
    if (image == null) return;

    setState(() => _isUploading = true);
    try {
      final bytes = await image.readAsBytes();
      final url = await ApiService.I.uploadAssetFile(bytes, image.name, purpose);
      final ext = image.name.split('.').last.toLowerCase();
      final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';
      final dataUri = 'data:$mime;base64,${base64Encode(bytes)}';

      final finalUrl = url.isNotEmpty ? url : dataUri;

      if (finalUrl.isNotEmpty) {
        if (mounted) {
          setState(() {
            if (purpose == 'avatar') {
              _apiProfile['avatar_url'] = finalUrl;
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
    final user = FirebaseAuth.instance.currentUser!;
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
    var avatarUrl = userObj['avatar_url'] as String? ?? userObj['avatarUrl'] as String? ?? profile['avatar_url'] as String? ?? profile['avatarUrl'] as String? ?? profile['avatar'] as String? ?? '';

    if (avatarUrl.contains('api.dicebear.com') && avatarUrl.contains('/svg')) {
      avatarUrl = avatarUrl.replaceAll('/svg', '/png');
    }
    if (avatarUrl.isNotEmpty) {
      debugPrint('[AVATAR_IMAGE_URL] $avatarUrl');
    }

    final docRole = (userObj['role'] as String? ?? profile['role'] as String?)?.trim().toLowerCase();
    final role = (docRole != null && docRole.isNotEmpty)
        ? docRole
        : (cachedRole?.trim().toLowerCase() ?? 'customer');
    final isDriver = role == 'driver' || role == 'bikerider';

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
              // ---------- Profile Header Card ----------
              Card(
                elevation: 2,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Avatar with Upload Overlay
                          GestureDetector(
                            onTap: () => _uploadImage(
                              purpose: 'avatar',
                              onSuccess: (url) async {
                                try {
                                  await ApiService.I.updateMe({'avatar_url': url});
                                } catch (_) {}
                              },
                            ),
                                child: Stack(
                                  children: [
                                    ClipOval(
                                      child: Container(
                                        width: 72,
                                        height: 72,
                                        color: Theme.of(context).primaryColor.withOpacity(0.15),
                                        child: avatarUrl.isNotEmpty
                                            ? _buildSmartImage(
                                                avatarUrl,
                                                width: 72,
                                                height: 72,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) {
                                                  debugPrint('[AVATAR_LOAD_ERROR] Failed to render image ($avatarUrl): $error');
                                                  return Center(
                                                    child: Text(
                                                      title.isNotEmpty ? title[0].toUpperCase() : '?',
                                                      style: TextStyle(
                                                        fontSize: 28,
                                                        fontWeight: FontWeight.bold,
                                                        color: Theme.of(context).primaryColor,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              )
                                            : Center(
                                                child: Text(
                                                  title.isNotEmpty ? title[0].toUpperCase() : '?',
                                                  style: TextStyle(
                                                    fontSize: 28,
                                                    fontWeight: FontWeight.bold,
                                                    color: Theme.of(context).primaryColor,
                                                  ),
                                                ),
                                              ),
                                      ),
                                    ),
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).primaryColor,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.camera_alt,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            title,
                                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                        ),
                                        Container(
                                           padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                           decoration: BoxDecoration(
                                             gradient: LinearGradient(
                                               colors: isDriver
                                                   ? [const Color(0xFF059669), const Color(0xFF10B981)]
                                                   : [const Color(0xFF2563EB), const Color(0xFF3B82F6)],
                                             ),
                                             borderRadius: BorderRadius.circular(20),
                                             boxShadow: [
                                               BoxShadow(
                                                 color: (isDriver ? const Color(0xFF10B981) : Colors.blue).withOpacity(0.25),
                                                 blurRadius: 6,
                                                 offset: const Offset(0, 2),
                                               ),
                                             ],
                                           ),
                                           child: Row(
                                             mainAxisSize: MainAxisSize.min,
                                             children: [
                                               Icon(
                                                 isDriver ? Icons.verified_user_rounded : Icons.verified_rounded,
                                                 size: 14,
                                                 color: Colors.white,
                                               ),
                                               const SizedBox(width: 4),
                                               Text(
                                                 isDriver ? 'FLEET DRIVER' : 'PERSONAL ACCOUNT',
                                                 style: const TextStyle(
                                                   fontSize: 10,
                                                   fontWeight: FontWeight.w800,
                                                   color: Colors.white,
                                                   letterSpacing: 0.5,
                                                 ),
                                               ),
                                             ],
                                           ),
                                         ),
                                       ],
                                     ),
                                     const SizedBox(height: 6),
                                     Row(
                                       children: [
                                         const Icon(Icons.phone_iphone_rounded, size: 14, color: Colors.grey),
                                         const SizedBox(width: 4),
                                         Text(phone, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                                       ],
                                     ),
                                     if (email.isNotEmpty && email != '—') ...[
                                       const SizedBox(height: 2),
                                       Row(
                                         children: [
                                           const Icon(Icons.mail_outline_rounded, size: 14, color: Colors.grey),
                                           const SizedBox(width: 4),
                                           Text(email, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                                         ],
                                       ),
                                     ],
                                   ],
                                 ),
                               ),
                           ],
                         ),
                          const Divider(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('Edit Basic Info'),
                                onPressed: () async {
                                  final initial = _EditProfileInitial(
                                    fullName: title == 'Unnamed User' ? '' : title,
                                    email: (email == '—') ? '' : email,
                                    role: role,
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
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                                icon: const Icon(Icons.logout, size: 18),
                                label: const Text('Sign out'),
                                onPressed: () async {
                                  await FirebaseAuth.instance.signOut();
                                  if (!context.mounted) return;
                                  Navigator.pushNamedAndRemoveUntil(
                                    context,
                                    NavRoutes.signIn,
                                    (route) => false,
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

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
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _buildSmartImage(
                                  driverSelfieUrl,
                                  height: 140,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
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
                                  itemBuilder: (ctx, i) => ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: _buildSmartImage(
                                      vehiclePhotos[i],
                                      width: 120,
                                      height: 100,
                                      fit: BoxFit.cover,
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
                decoration: const InputDecoration(labelText: 'National ID / Ghana Card'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: licCtl,
                decoration: const InputDecoration(labelText: "Driver's License Number"),
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
                decoration: const InputDecoration(labelText: 'License Plate (e.g. GW-9821-25)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save Credentials')),
        ],
      ),
    );

    if (save == true) {
      final updateMap = {
        'national_id': natCtl.text.trim(),
        'license_number': licCtl.text.trim(),
        'vehicle_type': vType,
        'vehicle_model': modCtl.text.trim(),
        'license_plate': pltCtl.text.trim(),
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
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                const Icon(Icons.location_off_outlined, size: 40),
                const SizedBox(height: 8),
                Text(
                  'No saved locations yet',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Add your Home, Work, or favorite places for quicker bookings.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          separatorBuilder: (ctx2, _) => const SizedBox(height: 8),
          itemBuilder: (itemCtx, i) {
            final loc = items[i];
            return Dismissible(
              key: Key(loc.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.delete, color: Colors.red),
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

  @override
  Widget build(BuildContext context) {
    final chipColor = loc.isDefault
        ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: CircleAvatar(backgroundColor: chipColor, child: Icon(_icon)),
        title: Text(loc.label.isNotEmpty ? loc.label : 'Saved place'),
        subtitle: Text(
          loc.address,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'default') onSetDefault();
            if (v == 'edit') onEdit();
          },
          itemBuilder: (popupCtx) => [
            if (!loc.isDefault)
              const PopupMenuItem(
                value: 'default',
                child: Text('Set as default'),
              ),
            const PopupMenuItem(value: 'edit', child: Text('Edit name/type')),
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
      title: const Text('Edit Profile & Account Type'),
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
              const SizedBox(height: 16),
              const Text(
                'Account Role',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'customer',
                    label: Text('Customer'),
                    icon: Icon(Icons.person_rounded),
                  ),
                  ButtonSegment(
                    value: 'driver',
                    label: Text('Driver'),
                    icon: Icon(Icons.local_shipping_rounded),
                  ),
                ],
                selected: {_role},
                onSelectionChanged: (set) {
                  setState(() => _role = set.first);
                },
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
