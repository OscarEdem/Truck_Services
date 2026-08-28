import 'dart:convert';
import 'package:cargomate_v3/services/prefs.dart';
import 'package:cargomate_v3/viewmodel/role_view_model.dart';
import '../services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../routes/navRoutes.dart';

/// ---------- Spacing helper ----------
class Gap extends StatelessWidget {
  final double h, w;
  const Gap({super.key, this.h = 0, this.w = 0});
  const Gap.h(this.h, {super.key}) : w = 0;
  const Gap.w(this.w, {super.key}) : h = 0;

  @override
  Widget build(BuildContext context) => SizedBox(height: h, width: w);
}

/// ---------- AppBar ----------
class CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final Widget? leading;
  const CustomAppBar({super.key, required this.title, this.actions, this.leading});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: Colors.white,
        ),
      ),
      centerTitle: true,
      backgroundColor: const Color(0xFF1565C0),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      actions: actions,
      leading: leading,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

/// ---------- Buttons ----------
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

/// ---------- Tiny map preview ----------
class MiniMap extends StatelessWidget {
  final double lat;
  final double lng;
  const MiniMap({super.key, required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    final pos = LatLng(lat, lng);
    return SizedBox(
      width: 100,
      height: 80,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: pos, zoom: 14),
          markers: {Marker(markerId: const MarkerId('m'), position: pos)},
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          scrollGesturesEnabled: false,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          zoomGesturesEnabled: false,
          liteModeEnabled: true, // Android-only
        ),
      ),
    );
  }
}

/// ---------- Status chip ----------
class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip({super.key, required this.status});

  Color _bg() {
    final s = status.toLowerCase();
    if (s.contains('done') || s.contains('delivered') || s.contains('complete')) {
      return const Color(0xFFF0FDF4);
    }
    if (s.contains('route') || s.contains('enroute') || s.contains('transit') || s.contains('active')) {
      return const Color(0xFFEFF6FF);
    }
    if (s.contains('accept') || s.contains('assigned') || s.contains('pending')) {
      return const Color(0xFFEEF2FF);
    }
    if (s.contains('cancel')) return const Color(0xFFFEF2F2);
    return const Color(0xFFF8FAFC);
  }

  Color _fg() {
    final s = status.toLowerCase();
    if (s.contains('done') || s.contains('delivered') || s.contains('complete')) {
      return const Color(0xFF15803D);
    }
    if (s.contains('route') || s.contains('enroute') || s.contains('transit') || s.contains('active')) {
      return const Color(0xFF1D4ED8);
    }
    if (s.contains('accept') || s.contains('assigned') || s.contains('pending')) {
      return const Color(0xFF4338CA);
    }
    if (s.contains('cancel')) return const Color(0xFFB91C1C);
    return const Color(0xFF475569);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _bg(),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: _fg(),
          fontSize: 12,
        ),
      ),
    );
  }
}

/// ---------- Delivery list tile ----------
class DeliveryTile extends StatelessWidget {
  final Map<String, dynamic> delivery;
  final VoidCallback? onTap;
  const DeliveryTile({super.key, required this.delivery, this.onTap});

  String _fmtDate(dynamic iso) {
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} "
          "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final pickup = (delivery['pickup_address'] ?? 'Unknown').toString();
    final drop = (delivery['drop_address'] ?? 'Unknown').toString();
    final price = delivery['price']?.toString() ?? '-';
    final vehicle = (delivery['vehicle_type'] ?? 'vehicle').toString();
    final status = (delivery['status'] ?? 'pending').toString();
    final created = _fmtDate(delivery['created_at']);

    final lat = (delivery['pickup_lat'] as num?)?.toDouble();
    final lng = (delivery['pickup_lng'] as num?)?.toDouble();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        onTap: onTap,
        leading: (lat != null && lng != null)
            ? MiniMap(lat: lat, lng: lng)
            : const Icon(Icons.local_shipping),
        title: Text(
          '$vehicle — GHS $price',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('$pickup → $drop\n$created'),
        isThreeLine: true,
        trailing: StatusChip(status: status),
      ),
    );
  }
}

/// ---------- Empty / Error / Loading ----------
class EmptyPlaceholder extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? action;
  const EmptyPlaceholder({
    super.key,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withOpacity(0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.local_shipping_rounded,
                size: 40,
                color: Color(0xFF2563EB),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: -0.3,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorPlaceholder extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorPlaceholder({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const Gap.h(12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const Gap.h(12),
              SecondaryButton(label: 'Retry', onPressed: onRetry!),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadingOverlay extends StatelessWidget {
  final bool show;
  final Widget child;
  const LoadingOverlay({super.key, required this.show, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (show)
          Container(
            color: Colors.black.withOpacity(.15),
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

/// ---------- Snack / Dialog ----------
class AppSnack {
  static void show(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Confirm',
  String cancelText = 'Cancel',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelText),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ==============================
// Logout helper (Firebase Auth)
// ==============================
Future<void> _logout(BuildContext context) async {
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
}

/// ===================================================================
/// Drawer header that reads name from Firestore `profiles/{uid}`
/// (fields: full_name, email, phone_number, role)
/// Falls back to auth.displayName/email/phone when missing.
/// ===================================================================
class _ProfileHeader extends StatelessWidget {
  final String roleLabelFallback; // e.g., "Customer" or "Driver"
  const _ProfileHeader({required this.roleLabelFallback});

  String _fallbackName(User u) {
    final dn = u.displayName?.trim();
    if (dn != null && dn.isNotEmpty) return dn;
    final email = u.email?.trim();
    if (email != null && email.isNotEmpty) {
      final at = email.indexOf('@');
      return at > 0 ? email.substring(0, at) : email;
    }
    final phone = u.phoneNumber?.trim();
    if (phone != null && phone.isNotEmpty) return phone;
    return 'User';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, uSnap) {
        final u = uSnap.data;
        if (u == null) {
          return _HeaderCard(
            title: 'Guest User',
            subtitle: 'Sign in to access freight services',
            cs: cs,
          );
        }

        return FutureBuilder<String?>(
          future: Prefs.I.getAvatarUrl(),
          builder: (context, cachedSnap) {
            final cachedAvatar = cachedSnap.data ?? u.photoURL;

            return FutureBuilder<Map<String, dynamic>>(
              future: ApiService.I.getMe(),
              builder: (context, snap) {
                final data = snap.data ?? {};
                final userObj = (data['user'] is Map) ? data['user'] as Map<String, dynamic> : data;
                final name = (userObj['full_name'] as String? ?? userObj['fullName'] as String? ?? u.displayName)?.trim();
                final phone = u.phoneNumber ?? (userObj['phone'] as String? ?? userObj['phone_number'] as String? ?? '');
                final email = u.email ?? (userObj['email'] as String? ?? '');
                final remoteAvatar = (userObj['avatar_url'] as String? ?? userObj['avatarUrl'] as String? ?? userObj['photo_url'] as String? ?? u.photoURL)?.trim();

                if (remoteAvatar != null && remoteAvatar.isNotEmpty) {
                  Prefs.I.setAvatarUrl(remoteAvatar);
                }

                final avatarUrl = (remoteAvatar != null && remoteAvatar.isNotEmpty)
                    ? remoteAvatar
                    : cachedAvatar;

                final displayName = (name != null && name.isNotEmpty) ? name : _fallbackName(u);
                final subtitle = phone.isNotEmpty ? phone : (email.isNotEmpty ? email : 'Personal Account');

                return _HeaderCard(
                  title: displayName,
                  subtitle: subtitle,
                  avatarUrl: avatarUrl,
                  cs: cs,
                );
              },
            );
          },
        );
      },
    );
  }
}

class SmartAvatar extends StatelessWidget {
  final String? url;
  final String fallbackInitials;
  final double radius;

  const SmartAvatar({
    super.key,
    required this.url,
    required this.fallbackInitials,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cleanUrl = url?.trim();

    if (cleanUrl == null || cleanUrl.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.primaryContainer,
        child: Text(
          fallbackInitials,
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.bold,
            fontSize: radius * 0.65,
          ),
        ),
      );
    }

    try {
      if (cleanUrl.startsWith('data:image/')) {
        final base64Data = cleanUrl.split(',').last;
        final bytes = base64Decode(base64Data);
        return CircleAvatar(
          radius: radius,
          backgroundImage: MemoryImage(bytes),
        );
      }
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(cleanUrl),
      );
    } catch (_) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.primaryContainer,
        child: Text(
          fallbackInitials,
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.bold,
            fontSize: radius * 0.65,
          ),
        ),
      );
    }
  }
}

class _HeaderCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? avatarUrl;
  final ColorScheme cs;
  const _HeaderCard({required this.title, this.subtitle, this.avatarUrl, required this.cs});

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFEFF6FF), Color(0xFFDBEAFE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBFDBFE)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF3D5AFE), Color(0xFF2563EB)],
                ),
              ),
              child: SmartAvatar(
                url: avatarUrl,
                fallbackInitials: _initials(title),
                radius: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF2563EB)),
          ],
        ),
      ),
    );
  }
}

class _DrawerNavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool isSelected;

  const _DrawerNavTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFEFF6FF) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: Icon(
          icon,
          color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF475569),
          size: 22,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            fontSize: 14,
            color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF0F172A),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _SignOutCard extends StatelessWidget {
  const _SignOutCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFECDD3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            final confirm = await showConfirmDialog(
              context,
              title: 'Log out',
              message: 'Are you sure you want to log out of your account?',
              confirmText: 'Log out',
            );
            if (confirm && context.mounted) {
              await _logout(context);
            }
          },
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: Color(0xFFDC2626),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'SIGN OUT',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFDC2626),
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Log out of account',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF991B1B),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 14,
                  color: Color(0xFFDC2626),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ==============================
/// Customer Drawer (classic Drawer)
/// ==============================
class CustomerDrawer extends StatelessWidget {
  const CustomerDrawer({super.key});

  void _go(BuildContext context, String route) {
    Navigator.pop(context);
    if (ModalRoute.of(context)?.settings.name == route) return;
    Navigator.pushNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = ModalRoute.of(context)?.settings.name;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: () => _go(context, NavRoutes.profile),
              child: const _ProfileHeader(roleLabelFallback: 'Customer'),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _DrawerNavTile(
                    icon: Icons.home_rounded,
                    title: 'Home',
                    isSelected: currentRoute == NavRoutes.homePage,
                    onTap: () => _go(context, NavRoutes.homePage),
                  ),
                  _DrawerNavTile(
                    icon: Icons.add_location_alt_rounded,
                    title: 'New Delivery',
                    isSelected: currentRoute == NavRoutes.book,
                    onTap: () => _go(context, NavRoutes.book),
                  ),
                  _DrawerNavTile(
                    icon: Icons.event_note_rounded,
                    title: 'Scheduled Deliveries',
                    isSelected: currentRoute == NavRoutes.schedule,
                    onTap: () => _go(context, NavRoutes.schedule),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
            const _SignOutCard(),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'CargoMate v3.0 • Secure Fleet',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DriverDrawer extends StatelessWidget {
  const DriverDrawer({super.key});

  void _go(BuildContext context, String route) {
    Navigator.pop(context);
    if (ModalRoute.of(context)?.settings.name == route) return;
    Navigator.pushNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = ModalRoute.of(context)?.settings.name;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: () => _go(context, NavRoutes.profile),
              child: const _ProfileHeader(roleLabelFallback: 'Driver'),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _DrawerNavTile(
                    icon: Icons.local_shipping_rounded,
                    title: 'Driver Home',
                    isSelected: currentRoute == NavRoutes.driverHome,
                    onTap: () => _go(context, NavRoutes.driverHome),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
            const _SignOutCard(),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'CargoMate v3.0 • Driver Terminal',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DeliveriesNavIcon extends StatelessWidget {
  final bool selected;
  final bool isDriver;
  const DeliveriesNavIcon({super.key, required this.selected, this.isDriver = false});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final baseIcon = isDriver
        ? Icon(selected ? Icons.space_dashboard_rounded : Icons.space_dashboard_outlined, color: selected ? const Color(0xFF1565C0) : null)
        : Icon(selected ? Icons.access_time_filled : Icons.access_time);

    if (uid == null) {
      return baseIcon;
    }

    final query = isDriver
        ? FirebaseFirestore.instance
            .collection('deliveries')
            .where('driver_id', isEqualTo: uid)
            .snapshots()
        : FirebaseFirestore.instance
            .collection('deliveries')
            .where('sender_id', isEqualTo: uid)
            .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: query,
      builder: (context, snap) {
        if (!snap.hasData) return baseIcon;

        final docs = snap.data!.docs;
        int activeCount = 0;
        bool hasDriverMessage = false;

        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final status = (data['status'] ?? '').toString().toLowerCase();
          final isFinished = status == 'delivered' || status == 'completed' || status == 'cancelled';
          if (!isFinished) {
            activeCount++;
            final unread = data['has_unread_driver_msg'] == true ||
                data['unread_msg'] == true ||
                (data['unread_driver_count'] != null && (data['unread_driver_count'] as num) > 0);
            if (unread) {
              hasDriverMessage = true;
            }
          }
        }

        if (activeCount == 0) {
          return baseIcon;
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            baseIcon,
            Positioned(
              right: -8,
              top: -6,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDriverMessage) ...[
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.amber,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.notifications_active_rounded,
                        size: 11,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 2),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFEF4444).withOpacity(0.4),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '$activeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ==============================
// Reusable Bottom Navigation Bar
// ==============================
class MainBottomNav extends StatelessWidget {
  /// Pass the current route name so the nav can highlight the right tab.
  final String? currentRoute;

  const MainBottomNav({super.key, required this.currentRoute});

  int _indexForRoute(String? route, bool isDriver) {
    if (isDriver) {
      switch (route) {
        case NavRoutes.driverHome:
          return 0;
        case NavRoutes.profile:
          return 1;
        default:
          return 0;
      }
    } else {
      switch (route) {
        case NavRoutes.homePage:
          return 0;
        case NavRoutes.myDeliveries:
        case NavRoutes.deliveries:
          return 1;
        case NavRoutes.profile:
          return 2;
        default:
          return 0;
      }
    }
  }

  void _onTap(BuildContext context, int i, bool isDriver) {
    String target;
    if (isDriver) {
      switch (i) {
        case 0:
          target = NavRoutes.driverHome;
          break;
        case 1:
          target = NavRoutes.profile;
          break;
        default:
          target = NavRoutes.driverHome;
      }
    } else {
      switch (i) {
        case 0:
          target = NavRoutes.homePage;
          break;
        case 1:
          target = NavRoutes.myDeliveries;
          break;
        case 2:
          target = NavRoutes.profile;
          break;
        default:
          target = NavRoutes.homePage;
      }
    }

    // Avoid pushing the same route again
    final current = ModalRoute.of(context)?.settings.name;
    if (current == target) return;
    if (current == NavRoutes.homePage && target == NavRoutes.driverHome) return;
    if (current == NavRoutes.driverHome && target == NavRoutes.homePage) return;

    Navigator.pushNamed(context, target);
  }

  @override
  Widget build(BuildContext context) {
    final roleVm = context.watch<RoleViewModel?>();
    final role = (roleVm?.role ?? 'customer').toLowerCase();
    final isDriver = role.contains('driver') || role.contains('bike');
    final idx = _indexForRoute(currentRoute, isDriver);

    return NavigationBar(
      selectedIndex: idx,
      onDestinationSelected: (i) => _onTap(context, i, isDriver),
      indicatorColor: isDriver ? const Color(0xFFDBEAFE) : null,
      destinations: isDriver
          ? [
              NavigationDestination(
                icon: DeliveriesNavIcon(selected: false, isDriver: true),
                selectedIcon: DeliveriesNavIcon(selected: true, isDriver: true),
                label: 'Jobs',
              ),
              const NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded, color: Color(0xFF1565C0)),
                label: 'Account',
              ),
            ]
          : [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              const NavigationDestination(
                icon: DeliveriesNavIcon(selected: false),
                selectedIcon: DeliveriesNavIcon(selected: true),
                label: 'Deliveries',
              ),
              const NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Account',
              ),
            ],
    );
  }
}

class AppScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  // ⬇️ add these
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  const AppScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
  });

  @override
  Widget build(BuildContext context) {
    final roleVM = context.watch<RoleViewModel>();
    final drawer = roleVM.role == 'customer'
        ? const CustomerDrawer()
        : const DriverDrawer();

    return Scaffold(
      appBar: CustomAppBar(title: title, actions: actions),
      drawer: drawer,
      body: body,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
    );
  }
}

// ============================================
// Interactive Full Screen Image Viewer Modal
// ============================================
class FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;
  final String title;

  const FullScreenImageViewer({
    super.key,
    required this.imageUrl,
    this.title = 'Image Preview',
  });

  static void show(BuildContext context, String imageUrl, {String title = 'Image Preview'}) {
    if (imageUrl.trim().isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenImageViewer(imageUrl: imageUrl, title: title),
      ),
    );
  }

  Widget _buildImage() {
    final cleanUrl = imageUrl.trim();
    if (cleanUrl.startsWith('data:')) {
      try {
        final base64Data = cleanUrl.split(',').last;
        return Image.memory(
          base64Decode(base64Data),
          fit: BoxFit.contain,
        );
      } catch (_) {}
    }
    return Image.network(
      cleanUrl,
      fit: BoxFit.contain,
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: CircularProgressIndicator(color: Color(0xFF2563EB)),
        );
      },
      errorBuilder: (_, err, stack) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_rounded, color: Colors.white54, size: 48),
            SizedBox(height: 8),
            Text('Could not load image preview', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          boundaryMargin: const EdgeInsets.all(20),
          minScale: 0.8,
          maxScale: 4.0,
          child: _buildImage(),
        ),
      ),
    );
  }
}
