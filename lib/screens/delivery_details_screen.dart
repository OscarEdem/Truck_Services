// lib/features/deliveries/delivery_details_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:cargomate_v3/screens/signature_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

// 🔁 Firebase
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:cargomate_v3/services/directions_service.dart';
import 'package:cargomate_v3/services/api_service.dart';
import '../widgets/widgets.dart';
import 'package:cargomate_v3/features/chat/chat_screen.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as geo;

class DeliveryDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> delivery;
  const DeliveryDetailsScreen({super.key, required this.delivery});

  @override
  State<DeliveryDetailsScreen> createState() => _DeliveryDetailsScreenState();
}

class _DeliveryDetailsScreenState extends State<DeliveryDetailsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;

  late Map<String, dynamic> d;
  gmaps.GoogleMapController? _gmapCtl;
  bool _routingBusy = false;
  List<LatLng> _routePoints = [];

  // Live Driver Telemetry & Geofenced Arrival State
  StreamSubscription<Map<String, dynamic>>? _locationSub;
  Timer? _pollTimer;
  gmaps.LatLng? _driverPos;
  double _driverHeading = 0.0;
  double _driverSpeed = 0.0;
  String _driverEtaText = '';
  bool _isArriving = false;

  @override
  void dispose() {
    _locationSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _canChat {
    final st = (d['status']?.toString() ?? '').toLowerCase();
    return st == 'accepted' || st == 'in_transit' || st == 'enroute' || st == 'picked_up';
  }

  // ---- helpers --------------------------------------------------------------

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
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

  LatLng? _getLatLng(List<String> latKeys, List<String> lngKeys) {
    double? lat;
    double? lng;
    for (final k in latKeys) {
      final v = _toDouble(d[k]);
      if (v != null && !v.isNaN && v != 0.0) {
        lat = v;
        break;
      }
    }
    for (final k in lngKeys) {
      final v = _toDouble(d[k]);
      if (v != null && !v.isNaN && v != 0.0) {
        lng = v;
        break;
      }
    }
    if (lat != null && lng != null) return LatLng(lat, lng);
    return null;
  }

  LatLng? get _pickup => _getLatLng(
        ['pickup_lat', 'pickup_latitude', 'pickupLat', 'pickuplatitude', 'p_lat', 'pLat', 'latitude', 'lat'],
        ['pickup_lng', 'pickup_longitude', 'pickupLng', 'pickuplongitude', 'p_lng', 'pLng', 'longitude', 'lng'],
      );
  LatLng? get _drop => _getLatLng(
        ['drop_lat', 'drop_latitude', 'dropLat', 'droplatitude', 'd_lat', 'dLat', 'destination_lat', 'destination_latitude'],
        ['drop_lng', 'drop_longitude', 'dropLng', 'droplongitude', 'd_lng', 'dLng', 'destination_longitude', 'destination_lng'],
      );

  @override
  void initState() {
    super.initState();
    d = Map<String, dynamic>.from(widget.delivery);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 1. If we only got an id, fetch full doc from Go REST API gateway.
      final idStr = (d['id'] ?? d['delivery_id'])?.toString();
      if ((_pickup == null || _drop == null || d['pickup_address'] == null) && idStr != null && idStr.isNotEmpty) {
        try {
          final full = await _fetchDeliveryById(idStr);
          if (full != null && mounted) {
            setState(() => d = Map<String, dynamic>.from(d)..addAll(full));
            await _fitBoundsFlutterMap();
          }
        } catch (_) {}
      }

      // 2. Geocoding fallback if coordinates are missing from backend delivery dict
      String cleanAddr(String raw) {
        return raw.replaceAll(RegExp(r'^[A-Z0-9]{4,8}\+[A-Z0-9]{2,8}\s*,?\s*'), '').trim();
      }

      final pAddr = cleanAddr(_addr(
        d['pickup_address'] ?? d['pickupAddress'] ?? d['pickup_location'] ?? d['pickup'],
        d['pickup_lat'] ?? d['pickup_latitude'] ?? d['pickupLat'],
        d['pickup_lng'] ?? d['pickup_longitude'] ?? d['pickupLng'],
      ));
      final dAddr = cleanAddr(_addr(
        d['drop_address'] ?? d['dropAddress'] ?? d['dropoff_address'] ?? d['dropoffAddress'] ?? d['drop_location'] ?? d['drop'],
        d['drop_lat'] ?? d['drop_latitude'] ?? d['dropLat'],
        d['drop_lng'] ?? d['drop_longitude'] ?? d['dropLng'],
      ));

      if (_pickup == null && pAddr.isNotEmpty && pAddr != 'Unknown') {
        try {
          final query = pAddr.toLowerCase().contains('ghana') ? pAddr : '$pAddr, Ghana';
          final locs = await geo.locationFromAddress(query);
          if (locs.isNotEmpty && mounted) {
            setState(() {
              d['pickup_lat'] = locs.first.latitude;
              d['pickup_lng'] = locs.first.longitude;
            });
            await _fitBoundsFlutterMap();
          }
        } catch (e) {
          debugPrint('[MAP_DEBUG] pickup geocoding failed: $e');
        }
      }

      if (_drop == null && dAddr.isNotEmpty && dAddr != 'Unknown') {
        try {
          final query = dAddr.toLowerCase().contains('ghana') ? dAddr : '$dAddr, Ghana';
          final locs = await geo.locationFromAddress(query);
          if (locs.isNotEmpty && mounted) {
            setState(() {
              d['drop_lat'] = locs.first.latitude;
              d['drop_lng'] = locs.first.longitude;
            });
            await _fitBoundsFlutterMap();
          }
        } catch (e) {
          debugPrint('[MAP_DEBUG] drop geocoding failed: $e');
        }
      }

      await _loadRoute();
      await _checkAutoComplete(); // in case both signatures already exist
      _startLiveTracking();
    });
  }

  void _startLiveTracking() {
    final deliveryId = (d['id'] ?? d['delivery_id'])?.toString();
    final driverId = (d['driver_id'] ?? d['driverId'])?.toString();
    if (deliveryId == null || deliveryId.isEmpty) return;

    // 1. Subscribe to real-time WebSocket location stream
    _locationSub?.cancel();
    _locationSub = ApiService.I.subscribeDeliveryLocationStream(deliveryId).listen((data) {
      _processDriverTelemetry(data);
    });

    // 2. Fallback polling every 4 seconds if driver ID is known
    _pollTimer?.cancel();
    if (driverId != null && driverId.isNotEmpty) {
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        try {
          final loc = await ApiService.I.getDriverLocation(driverId);
          if (loc != null) {
            _processDriverTelemetry(loc);
          }
        } catch (_) {}
      });
    }
  }

  void _processDriverTelemetry(Map<String, dynamic> data) {
    final lat = double.tryParse((data['latitude'] ?? data['lat'] ?? '').toString());
    final lng = double.tryParse((data['longitude'] ?? data['lng'] ?? '').toString());
    final heading = double.tryParse((data['heading'] ?? '0').toString()) ?? 0.0;
    final speed = double.tryParse((data['speed'] ?? '0').toString()) ?? 0.0;

    if (lat == null || lng == null || lat == 0.0 || lng == 0.0) return;

    final newPos = gmaps.LatLng(lat, lng);
    final st = (d['status'] as String?)?.toLowerCase() ?? '';
    final bool isPickupPhase = (st == 'accepted' || st == 'pending');
    final targetPoint = isPickupPhase ? _pickup : _drop;

    String etaStr = '';
    bool arriving = false;

    if (targetPoint != null) {
      final distMeters = Geolocator.distanceBetween(
        lat, lng, targetPoint.latitude, targetPoint.longitude,
      );

      if (distMeters <= 250) {
        arriving = true;
        final phaseName = isPickupPhase ? 'PICKUP LOCATION' : 'DROP-OFF LOCATION';
        etaStr = 'DRIVER IS ARRIVING AT $phaseName! (${distMeters.round()}m away)';
      } else {
        final speedMps = speed > 0 ? speed : (35.0 * 1000 / 3600);
        final etaSecs = (distMeters / speedMps).round();
        final etaMins = (etaSecs / 60).ceil();
        final distKm = (distMeters / 1000).toStringAsFixed(1);
        final phasePrefix = isPickupPhase ? 'Driver heading to Pickup' : 'Enroute to Drop-off';
        etaStr = '$phasePrefix • ETA ~$etaMins min ($distKm km away)';
      }
    }

    if (mounted) {
      setState(() {
        _driverPos = newPos;
        _driverHeading = heading;
        _driverSpeed = speed;
        _driverEtaText = etaStr;
        _isArriving = arriving;
      });
    }
  }

  Future<Map<String, dynamic>?> _fetchDeliveryById(String id) async {
    // 1. Try Go REST API Gateway
    final apiDoc = await ApiService.I.getDeliveryById(id);
    if (apiDoc != null && apiDoc.isNotEmpty) return apiDoc;

    // 2. Firestore fallback
    try {
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
    } catch (_) {}
    return null;
  }

  Future<void> _reloadDelivery() async {
    final id = (d['id'] ?? d['delivery_id'])?.toString();
    if (id == null || id.isEmpty) return;
    final doc = await _fetchDeliveryById(id);
    if (doc != null && mounted) {
      setState(() => d = Map<String, dynamic>.from(d)..addAll(doc));
    }
  }

  Future<void> _loadRoute() async {
    if (_pickup == null || _drop == null) {
      await _fitBoundsFlutterMap();
      return;
    }

    setState(() => _routingBusy = true);
    try {
      final res = await DirectionsService.routePolyline(
        origin: _pickup!,
        destination: _drop!,
      );
      if (res.points.isNotEmpty && mounted) {
        setState(() {
          _routePoints = res.points;
        });
        await _fitBoundsFlutterMap();
      }
    } catch (_) {
      // fallback
    } finally {
      if (mounted) {
        setState(() => _routingBusy = false);
        await _fitBoundsFlutterMap();
      }
    }
  }

  String _addr(dynamic txt, dynamic lat, dynamic lng) {
    final s = (txt as String?)?.trim();
    if (s != null && s.isNotEmpty && s != '0, 0' && s != '0') return s;
    final la = _toDouble(lat), ln = _toDouble(lng);
    if (la != null && ln != null && la != 0.0 && ln != 0.0) return '$la, $ln';
    return 'Unknown';
  }

  String _priceText(Map<String, dynamic> d) {
    final p = d['price'] ?? d['price_cents'] ?? d['amount'] ?? d['fare'] ?? d['estimated_price'] ?? d['cost'] ?? d['total_price'];
    if (p is num) {
      if (d['price'] == null && d['price_cents'] != null) {
        return (p / 100.0).toStringAsFixed(2);
      }
      return p.toStringAsFixed(0);
    }
    if (p is String && p.trim().isNotEmpty && p.trim() != '—') return p.trim();
    return '—';
  }

  Future<void> _fitBoundsFlutterMap() async {
    if (_gmapCtl == null) return;
    final p = _pickup;
    final dr = _drop;

    final pts = <gmaps.LatLng>[
      if (_routePoints.isNotEmpty)
        ..._routePoints.map((pt) => gmaps.LatLng(pt.latitude, pt.longitude))
      else ...[
        if (p != null) gmaps.LatLng(p.latitude, p.longitude),
        if (dr != null) gmaps.LatLng(dr.latitude, dr.longitude),
      ],
    ];

    if (pts.isEmpty) return;

    if (pts.length == 1) {
      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(pts.first, 14),
      );
      return;
    }

    double minLat = pts.first.latitude;
    double maxLat = pts.first.latitude;
    double minLng = pts.first.longitude;
    double maxLng = pts.first.longitude;

    for (final pt in pts) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }

    if ((maxLat - minLat).abs() < 0.0001 && (maxLng - minLng).abs() < 0.0001) {
      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(minLat, minLng), 14),
      );
      return;
    }

    try {
      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngBounds(
          gmaps.LatLngBounds(
            southwest: gmaps.LatLng(minLat, minLng),
            northeast: gmaps.LatLng(maxLat, maxLng),
          ),
          50,
        ),
      );
    } catch (_) {
      final centerLat = (minLat + maxLat) / 2;
      final centerLng = (minLng + maxLng) / 2;
      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(centerLat, centerLng), 12),
      );
    }
  }

  Future<void> _setStatus(String next, {Map<String, dynamic>? extra}) async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final docId = (d['id'] ?? d['delivery_id'])?.toString();
      if (docId == null) {
        AppSnack.show(context, 'Missing delivery id');
        return;
      }
      try {
        await ApiService.I.updateDeliveryStatus(deliveryId: docId, status: next);
      } catch (_) {}
      try {
        final ref = _db.collection('deliveries').doc(docId);
        await ref.update({'status': next, ...?extra});
      } catch (_) {}
      if (!mounted) return;
      setState(() => d['status'] = next);
      AppSnack.show(context, 'Status: $next');
    } catch (e) {
      AppSnack.show(context, 'Could not change status: $e');
    }
  }

  Future<void> _launchDriveNavigation() async {
    final st = (d['status'] as String?)?.toLowerCase() ?? '';
    final bool isPickupPhase = (st == 'accepted' || st == 'pending');

    final lat = double.tryParse((isPickupPhase
        ? (d['pickup_lat'] ?? d['pickup_latitude'] ?? d['pickupLat'])
        : (d['drop_lat'] ?? d['drop_latitude'] ?? d['dropLat']))?.toString() ?? '');
    final lng = double.tryParse((isPickupPhase
        ? (d['pickup_lng'] ?? d['pickup_longitude'] ?? d['pickupLng'])
        : (d['drop_lng'] ?? d['drop_longitude'] ?? d['dropLng']))?.toString() ?? '');
    final name = (isPickupPhase
        ? (d['pickup_address'] ?? d['pickupAddress'] ?? 'Pickup Location')
        : (d['drop_address'] ?? d['dropAddress'] ?? 'Dropoff Location')).toString();

    if (lat != null && lng != null && lat != 0.0 && lng != 0.0) {
      await ApiService.I.launchGoogleMapsNavigation(
        destinationLat: lat,
        destinationLng: lng,
        destinationName: name,
      );
    } else {
      AppSnack.show(context, 'Coordinates unavailable for Google Maps turn-by-turn navigation.');
    }
  }

  Future<void> _startEnroute() async {
    final st = (d['status'] as String?)?.toLowerCase() ?? 'pending';
    if (st != 'accepted' && st != 'pending' && st != 'picked_up') {
      AppSnack.show(context, 'You can start route only after accepting the job.');
      return;
    }
    await _setStatus('enroute');
    await _launchDriveNavigation();
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

  String _formatDateTime(dynamic input) {
    if (input == null) return 'N/A';
    DateTime? dt;
    if (input is Timestamp) {
      dt = input.toDate().toLocal();
    } else if (input is DateTime) {
      dt = input.toLocal();
    } else if (input is String) {
      dt = DateTime.tryParse(input)?.toLocal();
    }
    if (dt == null) return input.toString();

    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final month = months[dt.month - 1];
    final day = dt.day;
    final year = dt.year;
    final hourNum = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final hourStr = hourNum.toString().padLeft(2, '0');
    final minStr = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';

    return '$month $day, $year at $hourStr:$minStr $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    final pickupAddr = _addr(
      d['pickup_address'] ?? d['pickupAddress'] ?? d['pickup_location'] ?? d['pickup'],
      d['pickup_lat'] ?? d['pickup_latitude'] ?? d['pickupLat'],
      d['pickup_lng'] ?? d['pickup_longitude'] ?? d['pickupLng'],
    );
    final dropAddr = _addr(
      d['drop_address'] ?? d['dropAddress'] ?? d['dropoff_address'] ?? d['dropoffAddress'] ?? d['drop_location'] ?? d['drop'],
      d['drop_lat'] ?? d['drop_latitude'] ?? d['dropLat'],
      d['drop_lng'] ?? d['drop_longitude'] ?? d['dropLng'],
    );
    final priceText = _priceText(d);
    final vehicle = (d['vehicle_type'] ?? d['vehicleType'] ?? d['vehicle'] ?? 'vehicle').toString();
    final status = (d['status'] ?? 'pending').toString();
    final bool isDriverForThis =
        (d['driver_id'] ?? d['driverId']) != null &&
        user != null &&
        ((d['driver_id'] ?? d['driverId']).toString() == user.uid);
    final createdFormatted = _formatDateTime(d['created_at'] ?? d['createdAt'] ?? d['created_time']);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          'Delivery Details',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: LoadingOverlay(
        show: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 14, bottom: 16),
                child: Column(
                  children: [
                    // Map (Google Maps)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        height: 240,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Stack(
                            children: [
                              gmaps.GoogleMap(
                                gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                                  Factory<OneSequenceGestureRecognizer>(
                                    () => EagerGestureRecognizer(),
                                  ),
                                },
                                initialCameraPosition: gmaps.CameraPosition(
                                  target: _pickup != null
                                      ? gmaps.LatLng(_pickup!.latitude, _pickup!.longitude)
                                      : (_drop != null
                                          ? gmaps.LatLng(_drop!.latitude, _drop!.longitude)
                                          : const gmaps.LatLng(5.6037, -0.1870)),
                                  zoom: 12,
                                ),
                                myLocationEnabled: false,
                                myLocationButtonEnabled: false,
                                zoomControlsEnabled: false,
                                onMapCreated: (controller) async {
                                  _gmapCtl = controller;
                                  await Future.delayed(
                                    const Duration(milliseconds: 250),
                                  );
                                  await _fitBoundsFlutterMap();
                                },
                                polylines: {
                                  if (_pickup != null && _drop != null)
                                    gmaps.Polyline(
                                      polylineId: const gmaps.PolylineId('route_line'),
                                      color: const Color(0xFF2563EB),
                                      width: 5,
                                      points: _routePoints.isNotEmpty
                                          ? _routePoints
                                              .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                                              .toList()
                                          : [
                                              gmaps.LatLng(_pickup!.latitude, _pickup!.longitude),
                                              gmaps.LatLng(_drop!.latitude, _drop!.longitude),
                                            ],
                                    ),
                                },
                                markers: {
                                  if (_pickup != null)
                                    gmaps.Marker(
                                      markerId: const gmaps.MarkerId('pickup_pin'),
                                      position: gmaps.LatLng(_pickup!.latitude, _pickup!.longitude),
                                      icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                                        gmaps.BitmapDescriptor.hueAzure,
                                      ),
                                      infoWindow: const gmaps.InfoWindow(title: 'Pickup Location'),
                                    ),
                                  if (_drop != null)
                                    gmaps.Marker(
                                      markerId: const gmaps.MarkerId('drop_pin'),
                                      position: gmaps.LatLng(_drop!.latitude, _drop!.longitude),
                                      icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                                        gmaps.BitmapDescriptor.hueRed,
                                      ),
                                      infoWindow: const gmaps.InfoWindow(title: 'Dropoff Location'),
                                    ),
                                  if (_driverPos != null)
                                    gmaps.Marker(
                                      markerId: const gmaps.MarkerId('driver_vehicle_pin'),
                                      position: _driverPos!,
                                      rotation: _driverHeading,
                                      icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                                        gmaps.BitmapDescriptor.hueGreen,
                                      ),
                                      infoWindow: gmaps.InfoWindow(
                                        title: 'Driver Vehicle',
                                        snippet: _driverEtaText.isNotEmpty
                                            ? '$_driverEtaText (${(_driverSpeed * 3.6).round()} km/h)'
                                            : 'Live Telemetry',
                                      ),
                                    ),
                                },
                              ),

                              // Live Driver Telemetry & ETA Top Banner Overlay
                              if (_driverEtaText.isNotEmpty || _isArriving)
                                Positioned(
                                  top: 10,
                                  left: 10,
                                  right: 10,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: _isArriving ? const Color(0xFF059669) : const Color(0xFF0F172A).withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _isArriving ? Icons.notifications_active_rounded : Icons.radar_rounded,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _driverEtaText.isNotEmpty ? _driverEtaText : 'Live Tracking Active',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Info card
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'GH₵ $priceText',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const Spacer(),
                                StatusChip(status: status),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.location_on_rounded, size: 20, color: Color(0xFF2563EB)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'PICKUP LOCATION',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF64748B),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        pickupAddr,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1E293B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.flag_rounded, size: 20, color: Color(0xFF16A34A)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'DROPOFF LOCATION',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF64748B),
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        dropAddr,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1E293B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 24, color: Color(0xFFE2E8F0)),
                            Row(
                              children: [
                                const Icon(Icons.local_shipping_outlined, size: 18, color: Color(0xFF64748B)),
                                const SizedBox(width: 8),
                                Text(
                                  'Vehicle: ${vehicle.toUpperCase()}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.schedule_rounded, size: 18, color: Color(0xFF64748B)),
                                const SizedBox(width: 8),
                                Text(
                                  'Created: $createdFormatted',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                              ],
                            ),

                            if ((d['pod_url'] as String? ?? d['podUrl'] as String? ?? '').trim().isNotEmpty) ...[
                              const Divider(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Proof of Delivery (POD)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  TextButton.icon(
                                    onPressed: () => FullScreenImageViewer.show(
                                      context,
                                      (d['pod_url'] as String? ?? d['podUrl'] as String?).toString(),
                                      title: 'Proof of Delivery Preview',
                                    ),
                                    icon: const Icon(Icons.fullscreen_rounded, size: 16),
                                    label: const Text('View Full Screen', style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              GestureDetector(
                                onTap: () => FullScreenImageViewer.show(
                                  context,
                                  (d['pod_url'] as String? ?? d['podUrl'] as String?).toString(),
                                  title: 'Proof of Delivery Preview',
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Stack(
                                    alignment: Alignment.topRight,
                                    children: [
                                      Image.network(
                                        (d['pod_url'] as String? ?? d['podUrl'] as String?).toString(),
                                        height: 130,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, err, stack) => Container(
                                          height: 80,
                                          color: Colors.grey.shade100,
                                          child: const Center(child: Text('Proof image unavailable')),
                                        ),
                                      ),
                                      Container(
                                        margin: const EdgeInsets.all(6),
                                        padding: const EdgeInsets.all(5),
                                        decoration: const BoxDecoration(
                                          color: Colors.black54,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom Actions Bar
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 10,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Communication & Signature Actions Row
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: _canChat
                              ? 'Open chat'
                              : 'Chat is enabled only after acceptance',
                          child: ElevatedButton.icon(
                            onPressed: _canChat ? _openChat : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEFF6FF),
                              disabledBackgroundColor: const Color(0xFFF1F5F9),
                              foregroundColor: const Color(0xFF2563EB),
                              disabledForegroundColor: const Color(0xFF94A3B8),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                            label: const Text('Chat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _callCounterpart,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEFF6FF),
                            foregroundColor: const Color(0xFF2563EB),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.phone_enabled_rounded, size: 16),
                          label: const Text('Call', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _openSignature,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEFF6FF),
                            foregroundColor: const Color(0xFF2563EB),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.gesture_rounded, size: 16),
                          label: const Text('Signature', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Primary Operation Row
                  Row(
                    children: [
                      if (isDriverForThis) ...[
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _launchDriveNavigation,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF059669),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: const Icon(Icons.navigation_rounded, size: 18),
                            label: const Text('Drive (Maps)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SecondaryButton(
                            label: 'Enroute',
                            onPressed: _startEnroute,
                          ),
                        ),
                        const SizedBox(width: 8),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
