import 'dart:convert';
import 'package:cargomate_v3/services/prefs.dart';
import 'package:cargomate_v3/viewmodel/role_view_model.dart';
import '../services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
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
  const CustomAppBar({super.key, required this.title, this.actions});

  @override
  Widget build(BuildContext context) {
    return AppBar(title: Text(title), centerTitle: true, actions: actions);
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
    if (s.contains('done') || s.contains('delivered')) {
      return Colors.green.withOpacity(.15);
    }
    if (s.contains('route') || s.contains('enroute')) {
      return Colors.blue.withOpacity(.15);
    }
    if (s.contains('accept') || s.contains('assigned')) {
      return Colors.orange.withOpacity(.15);
    }
    if (s.contains('cancel')) return Colors.red.withOpacity(.15);
    return Colors.grey.withOpacity(.15);
  }

  Color _fg() {
    final s = status.toLowerCase();
    if (s.contains('done') || s.contains('delivered')) {
      return Colors.green.shade800;
    }
    if (s.contains('route') || s.contains('enroute')) {
      return Colors.blue.shade800;
    }
    if (s.contains('accept') || s.contains('assigned')) {
      return Colors.orange.shade800;
    }
    if (s.contains('cancel')) return Colors.red.shade800;
    return Colors.grey.shade800;
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 48),
            const Gap.h(12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (message != null) ...[
              const Gap.h(6),
              Text(message!, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const Gap.h(12), action!],
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
  await FirebaseAuth.instance.signOut();
  await Prefs.I.clearAll();
  final roleVM = context.read<RoleViewModel>();
  roleVM.clearRole();
  if (!context.mounted) return;
  Navigator.pushNamedAndRemoveUntil(
    context,
    NavRoutes.signIn,
    (route) => false,
  );
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
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Card(
        color: cs.secondaryContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SmartAvatar(
                url: avatarUrl,
                fallbackInitials: _initials(title),
                radius: 24,
              ),
              const Gap.w(12),
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
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSecondaryContainer.withOpacity(.8),
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            InkWell(
              onTap: () => _go(context, NavRoutes.profile),
              child: const _ProfileHeader(roleLabelFallback: 'Customer'),
            ),
            const Divider(height: 8),
            ListTile(
              leading: Icon(Icons.home_outlined, color: cs.onSurfaceVariant),
              title: const Text('Home'),
              onTap: () => _go(context, NavRoutes.homePage),
            ),
            ListTile(
              leading: Icon(
                Icons.add_location_alt_outlined,
                color: cs.onSurfaceVariant,
              ),
              title: const Text('New Delivery'),
              onTap: () => _go(context, NavRoutes.book),
            ),
            ListTile(
              leading: Icon(
                Icons.list_alt_outlined,
                color: cs.onSurfaceVariant,
              ),
              title: const Text('My Deliveries'),
              onTap: () => _go(context, NavRoutes.myDeliveries),
            ),
            const Divider(height: 16),
            ListTile(
              leading: Icon(Icons.logout, color: cs.error),
              title: const Text('Logout'),
              onTap: () async {
                final confirm = await showConfirmDialog(
                  context,
                  title: 'Logout',
                  message: 'Are you sure you want to log out?',
                );
                if (confirm) {
                  await _logout(context);
                }
              },
            ),
            const Gap.h(8),
          ],
        ),
      ),
    );
  }
}

/// ==============================
/// Driver Drawer (classic Drawer)
/// ==============================
class DriverDrawer extends StatelessWidget {
  const DriverDrawer({super.key});

  void _go(BuildContext context, String route) {
    Navigator.pop(context);
    if (ModalRoute.of(context)?.settings.name == route) return;
    Navigator.pushNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            InkWell(
              onTap: () => _go(context, NavRoutes.profile),
              child: const _ProfileHeader(roleLabelFallback: 'Driver'),
            ),
            const Divider(height: 8),
            ListTile(
              leading: Icon(Icons.home_outlined, color: cs.onSurfaceVariant),
              title: const Text('Driver Home'),
              onTap: () => _go(context, NavRoutes.driverHome),
            ),
            const Divider(height: 16),
            ListTile(
              leading: Icon(Icons.logout, color: cs.error),
              title: const Text('Logout'),
              onTap: () async {
                final confirm = await showConfirmDialog(
                  context,
                  title: 'Logout',
                  message: 'Are you sure you want to log out?',
                );
                if (confirm) {
                  await _logout(context);
                }
              },
            ),
            const Gap.h(8),
          ],
        ),
      ),
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

  int _indexForRoute(String? route) {
    switch (route) {
      case NavRoutes.homePage:
        return 0;
      case NavRoutes.myDeliveries: // ← use your actual deliveries route
        return 1;
      case NavRoutes.profile:
        return 2;
      default:
        return 0;
    }
  }

  void _onTap(BuildContext context, int i) {
    String target;
    switch (i) {
      case 0:
        target = NavRoutes.homePage;
        break;
      case 1:
        target = NavRoutes.myDeliveries; // ← make sure this matches your router
        break;
      case 2:
        target = NavRoutes.profile;
        break;
      default:
        target = NavRoutes.homePage;
    }

    // Avoid pushing the same route again
    if (ModalRoute.of(context)?.settings.name == target) return;
    Navigator.pushNamed(context, target);
  }

  @override
  Widget build(BuildContext context) {
    final idx = _indexForRoute(currentRoute);
    return NavigationBar(
      selectedIndex: idx,
      onDestinationSelected: (i) => _onTap(context, i),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.access_time),
          selectedIcon: Icon(Icons.access_time_filled),
          label: 'Deliveries',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
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
