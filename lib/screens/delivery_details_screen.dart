// lib/features/deliveries/delivery_details_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:cargomate_v3/screens/signature_screen.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

// 🔁 Firebase
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:cargomate_v3/services/directions_service.dart';
import '../widgets/widgets.dart';
import 'package:cargomate_v3/features/chat/chat_screen.dart';

// 🗺️ OSM via flutter_map
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart';

class DeliveryDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> delivery;
  const DeliveryDetailsScreen({super.key, required this.delivery});

  @override
  State<DeliveryDetailsScreen> createState() => _DeliveryDetailsScreenState();
}

class _DeliveryDetailsScreenState extends State<DeliveryDetailsScreen> {
  final fm.MapController _mapCtl = fm.MapController();
  final List<fm.Polyline> _polylines = [];

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;

  late Map<String, dynamic> d;
  bool _routingBusy = false;
  bool get _canChat {
    final st = (d['status']?.toString() ?? '').toLowerCase();
    return st == 'accepted' ||
        st == 'enroute'; // allow chat when accepted or enroute
  }

  // ---- helpers --------------------------------------------------------------

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  LatLng? _toLatLng(dynamic lat, dynamic lng) {
    final la = _toDouble(lat);
    final ln = _toDouble(lng);
    if (la == null || ln == null) return null;
    if (la.isNaN || ln.isNaN) return null;
    return LatLng(la, ln);
  }

  bool _getBool(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == 'true' || s == '1' || s == 'yes') return true;
        if (s == 'false' || s == '0' || s == 'no') return false;
      }
    }
    return false;
  }

  LatLng? get _pickup => _toLatLng(d['pickup_lat'], d['pickup_lng']);
  LatLng? get _drop => _toLatLng(d['drop_lat'], d['drop_lng']);

  @override
  void initState() {
    super.initState();
    d = Map<String, dynamic>.from(widget.delivery);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // If we only got an id, fetch full doc.
      if ((_pickup == null || _drop == null) && d['id'] != null) {
        try {
          final full = await _fetchDeliveryById(d['id'].toString());
          if (full != null && mounted) setState(() => d = full);
        } catch (_) {
          /* ignore */
        }
      }
      await _loadRoute();
      await _checkAutoComplete(); // in case both signatures already exist
    });
  }

  Future<Map<String, dynamic>?> _fetchDeliveryById(String id) async {
    final doc = await _db.collection('deliveries').doc(id).get();
    if (doc.exists) return {'id': doc.id, ...doc.data()!};

    final q = await _db
        .collection('deliveries')
        .where('id', isEqualTo: id)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      final first = q.docs.first;
      return {'id': first.id, ...first.data()};
    }
    return null;
  }

  Future<void> _reloadDelivery() async {
    final id = d['id']?.toString();
    if (id == null) return;
    final doc = await _db.collection('deliveries').doc(id).get();
    if (doc.exists && mounted) {
      setState(() {
        d = {'id': doc.id, ...doc.data()!};
      });
    }
  }

  Future<void> _loadRoute() async {
    if (_pickup == null || _drop == null) {
      await _fitBoundsFlutterMap();
      return;
    }

    setState(() => _routingBusy = true);
    try {
      // 🧭 Try to get a real routed polyline from your DirectionsService
      final res = await DirectionsService.routePolyline(
        origin: _pickup!,
        destination: _drop!,
      );

      final List<LatLng> pts = res.points;
      if (pts.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _polylines
            ..clear()
            ..add(
              fm.Polyline(
                points: pts, // Already List<LatLng> (latlong2)
                strokeWidth: 5.0,
                color: Colors.blue,
              ),
            );
        });
      } else {
        // Fallback: straight line if route service returned empty
        _addFallbackStraightLine();
      }
    } catch (_) {
      // Fallback: straight line if routing failed
      _addFallbackStraightLine();
    } finally {
      if (!mounted) return;
      setState(() => _routingBusy = false);
      await _fitBoundsFlutterMap();
    }
  }

  void _addFallbackStraightLine() {
    if (_pickup == null || _drop == null) return;
    _polylines
      ..clear()
      ..add(
        fm.Polyline(
          points: [_pickup!, _drop!],
          strokeWidth: 3.0,
          color: Colors.blue,
        ),
      );
  }

  String _addr(dynamic txt, dynamic lat, dynamic lng) {
    final s = (txt as String?)?.trim();
    if (s != null && s.isNotEmpty) return s;
    final la = _toDouble(lat), ln = _toDouble(lng);
    if (la != null && ln != null) return '$la, $ln';
    return 'Unknown';
  }

  String _priceText(Map<String, dynamic> d) {
    final num? price = d['price'] as num?;
    final int? priceCents = d['price_cents'] as int?;
    final num? gh = price ?? (priceCents != null ? priceCents / 100.0 : null);
    return gh != null ? gh.toStringAsFixed(0) : '—';
  }

  Future<void> _fitBoundsFlutterMap() async {
    // Build a robust points list
    final pts = <LatLng>[
      if (_pickup != null) _pickup!,
      if (_drop != null) _drop!,
      for (final pl in _polylines) ...pl.points,
    ];

    if (pts.isEmpty) return;

    // If we have only 1 point, create a tiny bounds to avoid issues
    fm.LatLngBounds bounds;
    if (pts.length == 1) {
      final p = pts.first;
      const eps = 0.0005; // ~55m
      bounds = fm.LatLngBounds.fromPoints([
        LatLng(p.latitude - eps, p.longitude - eps),
        LatLng(p.latitude + eps, p.longitude + eps),
      ]);
    } else {
      bounds = fm.LatLngBounds.fromPoints(pts);
    }

    _mapCtl.fitCamera(
      fm.CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
    );
  }

  Future<void> _setStatus(String next, {Map<String, dynamic>? extra}) async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final docId = d['id']?.toString();
      if (docId == null) {
        AppSnack.show(context, 'Missing delivery id');
        return;
      }
      final ref = _db.collection('deliveries').doc(docId);
      await ref.update({'status': next, ...?extra});
      if (!mounted) return;
      setState(() => d['status'] = next);
      AppSnack.show(context, 'Status: $next');
    } catch (e) {
      AppSnack.show(context, 'Could not change status: $e');
    }
  }

  Future<void> _startEnroute() async {
    final st = (d['status'] as String?) ?? 'pending';
    if (st != 'accepted' && st != 'pending') {
      AppSnack.show(context, 'You can start only after accepting the job.');
      return;
    }
    await _setStatus('enroute');
  }

  /// Driver/biker completes with Proof-of-Delivery (photo) — now with preview.
  Future<void> _completeWithPod() async {
    final st = (d['status'] as String?) ?? 'pending';
    if (st != 'picked_up' && st != 'enroute') {
      AppSnack.show(context, 'Mark package as picked up first.');
      return;
    }

    final picker = ImagePicker();

    XFile? shot;
    while (mounted) {
      // Take picture
      shot = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (shot == null) return; // user cancelled camera

      // Show preview dialog
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return AlertDialog(
            title: const Text('Proof of Delivery'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 320,
                  height: 420,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(shot!.path), fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Use this photo as proof?'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Retake'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Upload & Complete'),
              ),
            ],
          );
        },
      );

      if (confirmed == true) break; // proceed to upload
      // else loop to retake
    }

    if (shot == null) return;

    try {
      final bytes = await shot.readAsBytes();
      final path =
          'pod/${d['id']}/${DateTime.now().millisecondsSinceEpoch}.jpg';

      final task = await _storage
          .ref(path)
          .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));

      final url = await task.ref.getDownloadURL();

      await _setStatus(
        'delivered',
        extra: {
          'pod_path': path,
          'pod_url': url,
          'delivered_at': FieldValue.serverTimestamp(),
        },
      );
      if (!mounted) return;
      setState(() => d['pod_path'] = path);
    } catch (e) {
      AppSnack.show(context, 'Error uploading proof: $e');
    }
  }

  void _openChat() {
    if (!_canChat) {
      AppSnack.show(
        context,
        'Chat is available only after the delivery is accepted.',
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ChatScreen(delivery: d)));
  }

  /// Fetches both current user's phone and counterpart's phone,
  /// shows a confirm dialog, then launches the dialer.
  Future<void> _callCounterpart() async {
    final String? driverId = d['driver_id']?.toString();
    final String? senderId = d['sender_id']?.toString();
    final me = _auth.currentUser?.uid;

    final String? counterpart = (me != null && me == driverId)
        ? senderId
        : driverId;
    if (counterpart == null || counterpart.isEmpty) {
      AppSnack.show(context, 'Could not find who to call.');
      return;
    }

    // Load my phone
    final myPhone = await _fetchUserPhone(me);

    // Load counterpart phone
    final theirPhone = await _fetchUserPhone(counterpart);

    if (theirPhone == null || theirPhone.isEmpty) {
      AppSnack.show(context, 'Counterpart phone number not available.');
      return;
    }

    // Confirm sheet
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Call confirmation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (myPhone != null && myPhone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('Your phone: $myPhone'),
              ),
            Text('You will call: $theirPhone'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Call'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final uri = Uri(scheme: 'tel', path: theirPhone);
    final launched = await launchUrl(uri);
    if (!launched) {
      AppSnack.show(context, 'Could not open dialer.');
    }
  }

  Future<String?> _fetchUserPhone(String? userId) async {
    if (userId == null || userId.isEmpty) return null;

    // Primary: profiles/{uid}
    final profDoc = await _db.collection('profiles').doc(userId).get();
    if (profDoc.exists) {
      final data = profDoc.data()!;
      final phone =
          (data['phone'] as String?) ?? (data['phone_number'] as String?);
      if (phone != null && phone.trim().isNotEmpty) return phone.trim();
    }

    // Fallback: where user_id == uid
    final q = await _db
        .collection('profiles')
        .where('user_id', isEqualTo: userId)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      final data = q.docs.first.data();
      final phone =
          (data['phone'] as String?) ?? (data['phone_number'] as String?);
      if (phone != null && phone.trim().isNotEmpty) return phone.trim();
    }

    return null;
  }

  /// Opens Signature screen then re-checks completion rule.
  Future<void> _openSignature() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SignatureScreen(delivery: d)));

    // On return, reload the delivery (SignatureScreen likely updated flags)
    await _reloadDelivery();
    await _checkAutoComplete();
  }

  /// Auto-complete rule:
  /// If is_customer_signed == true AND (is_driver_signed == true OR is_biker_signed == true)
  /// then mark delivered (if not yet).
  Future<void> _checkAutoComplete() async {
    final alreadyDelivered = (d['status']?.toString() ?? '') == 'delivered';

    final customerSigned = _getBool(d, [
      'is_customer_signed',
      'iscustomersigned',
      'customer_signed',
    ]);

    final driverSigned = _getBool(d, [
      'is_driver_signed',
      'driver_signed',
      'isdriversigned',
    ]);

    final bikerSigned = _getBool(d, [
      'is_biker_signed',
      'biker_signed',
      'isbikersigned',
    ]);

    if (!alreadyDelivered && customerSigned && (driverSigned || bikerSigned)) {
      await _setStatus(
        'delivered',
        extra: {'delivered_at': FieldValue.serverTimestamp()},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    final pickupAddr = _addr(
      d['pickup_address'],
      d['pickup_lat'],
      d['pickup_lng'],
    );
    final dropAddr = _addr(d['drop_address'], d['drop_lat'], d['drop_lng']);
    final priceText = _priceText(d);
    final vehicle = (d['vehicle_type'] ?? 'vehicle').toString();
    final status = (d['status'] ?? 'pending').toString();

    String created;
    final c = d['created_at'];
    if (c is Timestamp) {
      created = c.toDate().toLocal().toString();
    } else {
      created = (c ?? '').toString();
    }

    final bool isDriverForThis =
        d['driver_id'] != null && user != null && d['driver_id'] == user.uid;

    final markers = <fm.Marker>[
      if (_pickup != null)
        fm.Marker(
          point: _pickup!,
          width: 40,
          height: 40,
          child: const Icon(
            Icons.radio_button_checked,
            color: Colors.green,
            size: 28,
          ),
        ),
      if (_drop != null)
        fm.Marker(
          point: _drop!,
          width: 44,
          height: 44,
          child: const Icon(Icons.place, color: Colors.red, size: 32),
        ),
    ];

    return Scaffold(
      appBar: const CustomAppBar(title: 'Delivery Details'),
      body: LoadingOverlay(
        show: false,
        child: Column(
          children: [
            // Quick actions
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: _canChat
                          ? 'Open chat'
                          : 'Chat is enabled only after acceptance',
                      child: PrimaryButton(
                        label: 'Chat',
                        onPressed: _canChat
                            ? _openChat
                            : null, // null disables the button
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Call',
                      onPressed: _callCounterpart,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Signature',
                      onPressed: _openSignature,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Map (flutter_map)
            SizedBox(
              height: 280,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    fm.FlutterMap(
                      mapController: _mapCtl,
                      options: fm.MapOptions(
                        initialCenter:
                            _pickup ?? _drop ?? const LatLng(5.6037, -0.1870),
                        initialZoom: 12,
                        onMapReady: () async {
                          await Future.delayed(
                            const Duration(milliseconds: 250),
                          );
                          await _fitBoundsFlutterMap();
                        },
                      ),
                      children: [
                        fm.TileLayer(
                          urlTemplate:
                              'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                          subdomains: const ['a', 'b', 'c'],
                          userAgentPackageName: 'com.example.cargomate',
                          maxZoom: 19,
                        ),
                        fm.PolylineLayer(polylines: _polylines),
                        fm.MarkerLayer(markers: markers),
                        const fm.RichAttributionWidget(
                          attributions: [
                            fm.TextSourceAttribution(
                              '© OpenStreetMap contributors',
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Routing busy overlay
                    if (_routingBusy)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black26,
                          child: const Center(
                            child: SizedBox(
                              height: 36,
                              width: 36,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          ),
                        ),
                      ),

                    // Zoom controls (guard against null camera)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Column(
                        children: [
                          _zoomBtn(Icons.zoom_in, () {
                            final cam = _mapCtl.camera;
                            _mapCtl.move(cam.center, cam.zoom + 1);
                          }),
                          const SizedBox(height: 8),
                          _zoomBtn(Icons.zoom_out, () {
                            final cam = _mapCtl.camera;
                            _mapCtl.move(cam.center, cam.zoom - 1);
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Gap.h(12),

            // Info card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'GHS $priceText',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          StatusChip(status: status),
                        ],
                      ),
                      const Gap.h(8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.place, size: 18),
                          const Gap.w(6),
                          Expanded(child: Text('Pickup: $pickupAddr')),
                        ],
                      ),
                      const Gap.h(6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.flag, size: 18),
                          const Gap.w(6),
                          Expanded(child: Text('Drop:   $dropAddr')),
                        ],
                      ),
                      const Divider(height: 20),
                      Row(
                        children: [
                          const Icon(Icons.local_shipping_outlined, size: 18),
                          const Gap.w(6),
                          Text('Vehicle: $vehicle'),
                        ],
                      ),
                      const Gap.h(6),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 18),
                          const Gap.w(6),
                          Text('Created: $created'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const Spacer(),

            // Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  if (isDriverForThis) ...[
                    Expanded(
                      child: SecondaryButton(
                        label: 'Start (Enroute)',
                        onPressed: _startEnroute,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: 'Complete',
                        onPressed: _completeWithPod,
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: SecondaryButton(
                        label: 'Close',
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _zoomBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }
}
