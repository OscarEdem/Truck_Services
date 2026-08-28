// lib/features/driver/driver_home_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import 'package:firebase_auth/firebase_auth.dart';

import '../../../widgets/widgets.dart';
import '../../../routes/navRoutes.dart';
import '../../services/api_service.dart';
import '../../services/prefs.dart';

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage>
    with WidgetsBindingObserver {
  final _auth = FirebaseAuth.instance;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _online = false;
  bool _busy = false;

  StreamSubscription<Position>? _posSub;

  // Available jobs
  List<Map<String, dynamic>> _available = [];
  bool _loadingAvailable = true;

  // My active jobs
  List<Map<String, dynamic>> _myJobs = [];
  bool _loadingMy = true;

  // Completed jobs
  List<Map<String, dynamic>> _completed = [];
  bool _loadingCompleted = true;

  bool _isVerified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkVerificationStatus();
    _restoreOnlineState();
    _loadAvailable();
    _loadMyJobs();
    _loadCompleted();
  }

  Future<void> _restoreOnlineState() async {
    final user = _auth.currentUser;
    if (user == null) return;

    bool isOnline = await Prefs.I.getOnlineForUser(user.uid);

    try {
      final me = await ApiService.I.getMe();
      final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
      if (userObj.containsKey('is_online')) {
        isOnline = userObj['is_online'] == true;
      }
    } catch (_) {}

    if (mounted && isOnline) {
      setState(() => _online = true);
      await _startLocationTracking(user.uid);
    }
  }

  Future<void> _startLocationTracking(String uid) async {
    final granted = await _ensureLocationPermission();
    if (!granted) return;

    // Connect WebSocket stream for real-time customer map tracking
    ApiService.I.startLocationWebSocket(uid);

    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((pos) async {
      try {
        await ApiService.I.updateDriverGPS(
          latitude: pos.latitude,
          longitude: pos.longitude,
          heading: pos.heading,
          speed: pos.speed,
        );
      } catch (_) {}
    });
  }

  Future<void> _checkVerificationStatus() async {
    try {
      final me = await ApiService.I.getMe();
      final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
      final verified = (userObj['is_verified'] == true) ||
          (userObj['isVerified'] == true) ||
          (me['is_verified'] == true) ||
          (me['isVerified'] == true);
      if (mounted) {
        setState(() => _isVerified = verified);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    ApiService.I.stopLocationWebSocket();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAvailable();
      _loadMyJobs();
      _loadCompleted();
    }
    super.didChangeAppLifecycleState(state);
  }

  // ===== Online / Offline & GPS =====

  Future<void> _toggleOnline(bool value) async {
    final user = _auth.currentUser;
    if (user == null) {
      AppSnack.show(context, 'Not signed in');
      return;
    }

    setState(() => _online = value);
    await Prefs.I.setOnlineForUser(user.uid, value);

    try {
      await ApiService.I.updateMe({'is_online': value});
    } catch (e) {
      debugPrint('[DRIVER_HOME] Update online status error: $e');
    }

    if (value) {
      final granted = await _ensureLocationPermission();
      if (!granted) {
        AppSnack.show(context, 'Location permission required');
        setState(() => _online = false);
        await Prefs.I.setOnlineForUser(user.uid, false);
        return;
      }
      await _startLocationTracking(user.uid);
      if (mounted) AppSnack.show(context, 'You are now ONLINE & active');
    } else {
      await _posSub?.cancel();
      _posSub = null;
      ApiService.I.stopLocationWebSocket();
      if (mounted) AppSnack.show(context, 'You are now OFFLINE');
    }
  }

  Future<bool> _ensureLocationPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  // ===== Data: Pure REST API Gateway Callers =====

  Future<void> _loadAvailable() async {
    if (mounted) setState(() => _loadingAvailable = true);
    try {
      final list = await ApiService.I.listDeliveries(role: 'driver', filterStatus: 'pending');
      final rows = list
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((d) {
            final driverId = (d['driver_id'] ?? d['driverId'])?.toString();
            final status = (d['status'] as String?) ?? 'pending';
            final unassigned = driverId == null || driverId.isEmpty;
            return status == 'pending' && unassigned;
          })
          .toList();

      rows.sort((a, b) {
        final ca = (a['created_at'] ?? a['createdAt'])?.toString() ?? '';
        final cb = (b['created_at'] ?? b['createdAt'])?.toString() ?? '';
        return cb.compareTo(ca);
      });

      if (mounted) {
        setState(() {
          _available = rows;
          _loadingAvailable = false;
        });
      }
    } catch (e) {
      debugPrint('[DRIVER_HOME] _loadAvailable error: $e');
      if (mounted) setState(() => _loadingAvailable = false);
    }
  }

  Future<void> _loadMyJobs() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) setState(() { _myJobs = []; _loadingMy = false; });
      return;
    }

    if (mounted) setState(() => _loadingMy = true);
    try {
      final firebaseUid = user.uid;
      String dbUserId = '';
      try {
        final me = await ApiService.I.getMe();
        final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
        dbUserId = (userObj['id'] ?? userObj['user_id'] ?? userObj['uid'] ?? '').toString();
      } catch (_) {}

      final list = await ApiService.I.listDeliveries(role: 'driver', filterStatus: 'active');
      final rows = list
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((d) {
            final driverId = (d['driver_id'] ?? d['driverId'] ?? d['driver_user_id'])?.toString();
            final status = ((d['status'] as String?) ?? '').toLowerCase();
            final isMine = (driverId == null || driverId.isEmpty || driverId == '0') ||
                (driverId == firebaseUid) ||
                (dbUserId.isNotEmpty && driverId == dbUserId);
            final isActive = (status == 'accepted' || status == 'picked_up' || status == 'enroute' || status == 'in_transit' || status == 'active');
            return isMine && isActive;
          })
          .toList();

      rows.sort((a, b) {
        final ca = (a['created_at'] ?? a['createdAt'])?.toString() ?? '';
        final cb = (b['created_at'] ?? b['createdAt'])?.toString() ?? '';
        return cb.compareTo(ca);
      });

      if (mounted) {
        setState(() {
          _myJobs = rows;
          _loadingMy = false;
        });
      }
    } catch (e) {
      debugPrint('[DRIVER_HOME] _loadMyJobs error: $e');
      if (mounted) setState(() => _loadingMy = false);
    }
  }

  Future<void> _loadCompleted() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) setState(() { _completed = []; _loadingCompleted = false; });
      return;
    }

    if (mounted) setState(() => _loadingCompleted = true);
    try {
      final firebaseUid = user.uid;
      String dbUserId = '';
      try {
        final me = await ApiService.I.getMe();
        final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
        dbUserId = (userObj['id'] ?? userObj['user_id'] ?? userObj['uid'] ?? '').toString();
      } catch (_) {}

      final list = await ApiService.I.listDeliveries(role: 'driver', filterStatus: 'completed');
      final rows = list
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((d) {
            final driverId = (d['driver_id'] ?? d['driverId'] ?? d['driver_user_id'])?.toString();
            final status = ((d['status'] as String?) ?? '').toLowerCase();
            final isMine = (driverId == null || driverId.isEmpty || driverId == '0') ||
                (driverId == firebaseUid) ||
                (dbUserId.isNotEmpty && driverId == dbUserId);
            final isDelivered = (status == 'delivered' || status == 'completed');
            return isMine && isDelivered;
          })
          .toList();

      rows.sort((a, b) {
        final ca = (a['delivered_at'] ?? a['created_at'])?.toString() ?? '';
        final cb = (b['delivered_at'] ?? b['created_at'])?.toString() ?? '';
        return cb.compareTo(ca);
      });

      if (mounted) {
        setState(() {
          _completed = rows;
          _loadingCompleted = false;
        });
      }
    } catch (e) {
      debugPrint('[DRIVER_HOME] _loadCompleted error: $e');
      if (mounted) setState(() => _loadingCompleted = false);
    }
  }

  Future<void> _refreshAvailable() async => _loadAvailable();
  Future<void> _refreshMyJobs() async => _loadMyJobs();
  Future<void> _refreshCompleted() async => _loadCompleted();

  // ===== Actions: accept / picked_up / deliver via Go REST API Gateway =====

  Future<void> _acceptJob(Map<String, dynamic> row) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final id = (row['id'] ?? row['delivery_id'])?.toString();
    if (id == null || id.isEmpty) {
      AppSnack.show(context, 'Invalid delivery order ID');
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await ApiService.I.acceptJob(id);
      if (!mounted) return;
      AppSnack.show(context, 'Job accepted!');
      final acceptedData = Map<String, dynamic>.from(row)..addAll(res);
      acceptedData['driver_id'] = user.uid;
      acceptedData['status'] = 'accepted';

      setState(() {
        _available.removeWhere((item) => (item['id'] ?? item['delivery_id'])?.toString() == id);
        _myJobs.removeWhere((item) => (item['id'] ?? item['delivery_id'])?.toString() == id);
        _myJobs.insert(0, acceptedData);
      });

      Navigator.pushNamed(
        context,
        NavRoutes.deliveryDetails,
        arguments: acceptedData,
      );
      _loadAvailable();
      _loadMyJobs();
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Could not accept job: $e');
      await _loadAvailable();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markPickedUp(Map<String, dynamic> row) async {
    final id = (row['id'] ?? row['delivery_id'])?.toString();
    if (id == null || id.isEmpty) return;

    setState(() => _busy = true);
    try {
      await ApiService.I.updateDeliveryStatus(deliveryId: id, status: 'enroute');
      if (!mounted) return;
      AppSnack.show(context, 'Package picked up! Launching Google Maps navigation...');

      final dropLat = double.tryParse((row['drop_lat'] ?? row['drop_latitude'] ?? row['dropLat'] ?? '').toString());
      final dropLng = double.tryParse((row['drop_lng'] ?? row['drop_longitude'] ?? row['dropLng'] ?? '').toString());
      final dropAddr = (row['drop_address'] ?? row['dropAddress'] ?? row['dropoff_address'] ?? 'Destination').toString();

      if (dropLat != null && dropLng != null && dropLat != 0.0 && dropLng != 0.0) {
        await ApiService.I.launchGoogleMapsNavigation(
          destinationLat: dropLat,
          destinationLng: dropLng,
          destinationName: dropAddr,
        );
      }
      _loadMyJobs();
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Status update error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deliverWithPod(Map<String, dynamic> row) async {
    final id = (row['id'] ?? row['delivery_id'])?.toString();
    if (id == null || id.isEmpty) return;

    final picker = ImagePicker();
    final shot = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (shot == null) return;

    setState(() => _busy = true);
    try {
      final bytes = await shot.readAsBytes();
      final podUrl = await ApiService.I.uploadAssetFile(bytes, shot.name, 'vehicle');
      await ApiService.I.updateDeliveryStatus(
        deliveryId: id,
        status: 'delivered',
        podProofURL: podUrl,
      );
      if (!mounted) return;
      AppSnack.show(context, 'Job completed & delivered successfully!');
      _loadMyJobs();
      _loadCompleted();
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Delivery completion error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      // ---- DRIVER HOME SCREEN ---------------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset(
              'assets/icons/cargomatewhitelogo.png',
              height: 26,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            const Text(
              'cargomate',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 20,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Menu',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            icon: const Icon(Icons.menu_rounded, color: Colors.white),
          ),
          const SizedBox(width: 8),
        ],
      ),
      endDrawer: const DriverDrawer(),

      body: LoadingOverlay(
        show: _busy,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              if (!_isVerified)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFFFFBEB),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.hourglass_top_rounded, color: Color(0xFFD97706), size: 18),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Account Verification Pending — Your driver credentials and selfie are currently under review by our team.',
                          style: TextStyle(
                            color: Color(0xFF92400E),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // ---- HERO ONLINE / OFFLINE TOGGLE BANNER ------------------------------------------------------------                                                                                                                                                                                #*eddiere
              Container(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _online
                        ? [const Color(0xFF065F46), const Color(0xFF059669)]
                        : [const Color(0xFF1E293B), const Color(0xFF334155)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: (_online ? const Color(0xFF059669) : Colors.black).withOpacity(0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _online ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                        shape: BoxShape.circle,
                        boxShadow: _online
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF34D399).withOpacity(0.8),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                )
                              ]
                            : [],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _online ? 'ONLINE & ACTIVE' : 'OFFLINE MODE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _online
                                ? 'Receiving live freight & delivery requests'
                                : 'Toggle switch to start receiving delivery jobs',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch.adaptive(
                      value: _online,
                      onChanged: _toggleOnline,
                      activeColor: const Color(0xFF34D399),
                      activeTrackColor: Colors.white.withOpacity(0.25),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),

              // ---- STYLED TAB BAR ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: TabBar(
                    indicator: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    labelColor: const Color(0xFF0F172A),
                    unselectedLabelColor: const Color(0xFF64748B),
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: 'Available'),
                      Tab(text: 'My Jobs'),
                      Tab(text: 'Completed'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    // Available tab
                    _loadingAvailable
                        ? const Center(child: CircularProgressIndicator())
                        : _available.isEmpty
                        ? const _EmptyInfo(
                            title: 'No available jobs',
                            message:
                                'When customers book new deliveries, they will appear here.',
                          )
                        : RefreshIndicator(
                            onRefresh: _refreshAvailable,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                24,
                              ),
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: _available.length,
                              itemBuilder: (_, i) => JobCard.available(
                                d: _available[i],
                                onAccept: () => _acceptJob(_available[i]),
                                onOpenDetails: () {
                                  Navigator.pushNamed(
                                    context,
                                    NavRoutes.deliveryDetails,
                                    arguments: _available[i],
                                  );
                                },
                              ),
                            ),
                          ),

                    // My Jobs tab
                    _loadingMy
                        ? const Center(child: CircularProgressIndicator())
                        : _myJobs.isEmpty
                        ? const _EmptyInfo(
                            title: 'No active jobs',
                            message:
                                'Accepted jobs will appear here until delivered.',
                          )
                        : RefreshIndicator(
                            onRefresh: _refreshMyJobs,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                24,
                              ),
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: _myJobs.length,
                              itemBuilder: (_, i) => JobCard.active(
                                d: _myJobs[i],
                                onPickedUp: () => _markPickedUp(_myJobs[i]),
                                onDeliver: () => _deliverWithPod(_myJobs[i]),
                                onOpenDetails: () {
                                  Navigator.pushNamed(
                                    context,
                                    NavRoutes.deliveryDetails,
                                    arguments: _myJobs[i],
                                  );
                                },
                              ),
                            ),
                          ),

                    // Completed tab
                    _loadingCompleted
                        ? const Center(child: CircularProgressIndicator())
                        : _completed.isEmpty
                        ? const _EmptyInfo(
                            title: 'No completed jobs',
                            message:
                                'Delivered jobs (with proof) will appear here.',
                          )
                        : RefreshIndicator(
                            onRefresh: _refreshCompleted,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                24,
                              ),
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: _completed.length,
                              itemBuilder: (_, i) => JobCard.completed(
                                d: _completed[i],
                                onOpenDetails: () {
                                  Navigator.pushNamed(
                                    context,
                                    NavRoutes.deliveryDetails,
                                    arguments: _completed[i],
                                  );
                                },
                                onOpenPod: () => _openPodViewer(_completed[i]),
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const MainBottomNav(currentRoute: NavRoutes.driverHome),
    );
  }

  Future<void> _openPodViewer(Map<String, dynamic> d) async {
    final podUrl = (d['pod_url'] as String?) ?? '';
    if (podUrl.isEmpty) {
      AppSnack.show(context, 'No proof image found for this job.');
      return;
    }
    await showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _FullScreenImageDialog(
        imageUrl: podUrl,
        title: 'Proof of Delivery',
        onDetails: () {
          Navigator.pop(ctx);
          Navigator.pushNamed(context, NavRoutes.deliveryDetails, arguments: d);
        },
      ),
    );
  }
}

// ===== Modern Card Widgets =====

class JobCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final VoidCallback? onAccept;
  final VoidCallback? onPickedUp;
  final VoidCallback? onDeliver;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onOpenPod;
  // ignore: library_private_types_in_public_api
  final _Kind kind;

  const JobCard._({
    required this.d,
    required this.kind,
    this.onAccept,
    this.onPickedUp,
    this.onDeliver,
    this.onOpenDetails,
    this.onOpenPod,
  });

  factory JobCard.available({
    required Map<String, dynamic> d,
    required VoidCallback onAccept,
    required VoidCallback onOpenDetails,
  }) => JobCard._(
    d: d,
    kind: _Kind.available,
    onAccept: onAccept,
    onOpenDetails: onOpenDetails,
  );

  factory JobCard.active({
    required Map<String, dynamic> d,
    required VoidCallback onPickedUp,
    required VoidCallback onDeliver,
    required VoidCallback onOpenDetails,
  }) => JobCard._(
    d: d,
    kind: _Kind.active,
    onPickedUp: onPickedUp,
    onDeliver: onDeliver,
    onOpenDetails: onOpenDetails,
  );

  factory JobCard.completed({
    required Map<String, dynamic> d,
    required VoidCallback onOpenPod,
    required VoidCallback onOpenDetails,
  }) => JobCard._(
    d: d,
    kind: _Kind.completed,
    onOpenPod: onOpenPod,
    onOpenDetails: onOpenDetails,
  );

  String get _priceText {
    final p = d['price'] ?? d['price_cents'] ?? d['amount'] ?? d['fare'] ?? d['estimated_price'] ?? d['cost'] ?? d['total_price'];
    if (p is num) {
      if (d['price'] == null && d['price_cents'] != null) {
        return (p / 100).toStringAsFixed(2);
      }
      return p.toStringAsFixed(0);
    }
    if (p is String && p.trim().isNotEmpty) return p.trim();
    return '--';
  }

  String get _vehicle => (d['vehicle_type'] ?? d['vehicleType'] ?? '').toString();

  String _getAddr(dynamic addr, dynamic lat, dynamic lng) {
    if (addr != null && addr.toString().trim().isNotEmpty && addr.toString().trim() != '0, 0' && addr.toString().trim() != '0') {
      return addr.toString().trim();
    }
    if (lat != null && lng != null && lat.toString() != '0' && lng.toString() != '0' && lat.toString() != '0.0') {
      return '$lat, $lng';
    }
    return 'Location not specified';
  }

  @override
  Widget build(BuildContext context) {
    final status = (d['status'] as String?) ?? '';
    final isCompleted = status == 'delivered';

    final podUrl = (d['pod_url'] as String?) ?? '';
    final hasThumb = isCompleted && podUrl.isNotEmpty;

    final pickupAddrText = _getAddr(
      d['pickup_address'] ?? d['pickupAddress'] ?? d['pickup_location'] ?? d['pickup'],
      d['pickup_lat'] ?? d['pickup_latitude'] ?? d['pickupLat'],
      d['pickup_lng'] ?? d['pickup_longitude'] ?? d['pickupLng'],
    );
    final dropAddrText = _getAddr(
      d['drop_address'] ?? d['dropAddress'] ?? d['dropoff_address'] ?? d['dropoffAddress'] ?? d['drop_location'] ?? d['drop'],
      d['drop_lat'] ?? d['drop_latitude'] ?? d['dropLat'],
      d['drop_lng'] ?? d['drop_longitude'] ?? d['dropLng'],
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: kind == _Kind.completed
            ? (onOpenPod ?? onOpenDetails)
            : onOpenDetails,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: POD thumbnail or category icon
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 64,
                  width: 64,
                  child: hasThumb
                      ? Image.network(podUrl, fit: BoxFit.cover)
                      : Container(
                          color: const Color(0xFFF1F5F9),
                          child: Icon(
                            kind == _Kind.available
                                ? Icons.local_offer_outlined
                                : (kind == _Kind.active
                                      ? Icons.local_shipping_outlined
                                      : Icons.check_circle_outline_rounded),
                            color: const Color(0xFF059669),
                            size: 28,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),

              // Middle: texts
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row: price + vehicle chip + status chip
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '₵$_priceText',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        _LabeledChip(
                          icon: Icons.local_shipping_outlined,
                          label: _vehicle.isEmpty ? 'vehicle' : _vehicle,
                        ),
                        _StatusPill(status: status),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Addresses
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.place, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'From: $pickupAddrText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.flag, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'To:   $dropAddrText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),

                    // Time meta for completed
                    if (kind == _Kind.completed) ...[
                      const SizedBox(height: 6),
                      _MetaLine(
                        icon: Icons.schedule_outlined,
                        label: 'Delivered',
                        value: _fmtTimestamp(d['delivered_at']),
                      ),
                    ],
                  ],
                ),
              ),

              // Right: actions column
              const SizedBox(width: 8),
              Column(
                children: [
                  if (kind == _Kind.available) ...[
                    if (onAccept != null)
                      FilledButton(
                        onPressed: onAccept,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF059669),
                          minimumSize: const Size(84, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Accept'),
                      ),
                    const SizedBox(height: 6),
                    if (onOpenDetails != null)
                      OutlinedButton(
                        onPressed: onOpenDetails,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(84, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Details', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                  if (kind == _Kind.active) ...[
                    if ((d['status'] as String?) == 'accepted' &&
                        onPickedUp != null)
                      OutlinedButton(
                        onPressed: onPickedUp,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(96, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Picked Up'),
                      ),
                    if ((d['status'] as String?) == 'picked_up' &&
                        onDeliver != null)
                      FilledButton(
                        onPressed: onDeliver,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(96, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Deliver'),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onOpenDetails,
                      child: const Text('Details'),
                    ),
                  ],
                  if (kind == _Kind.completed) ...[
                    if (onOpenPod != null)
                      FilledButton.tonalIcon(
                        onPressed: onOpenPod,
                        icon: const Icon(Icons.photo),
                        label: const Text('POD'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(84, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onOpenDetails,
                      child: const Text('Details'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtTimestamp(dynamic ts) {
    if (ts == null) return '—';
    DateTime? dt;
    if (ts is DateTime) dt = ts;
    if (ts is String) dt = DateTime.tryParse(ts);
    if (dt == null) return '—';
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

enum _Kind { available, active, completed }

class _LabeledChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _LabeledChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = status.toLowerCase();
    final cs = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    IconData ic;
    switch (s) {
      case 'pending':
        bg = cs.surfaceContainerHighest;
        fg = cs.onSurfaceVariant;
        ic = Icons.hourglass_empty_outlined;
        break;
      case 'accepted':
        bg = Colors.orange.shade50;
        fg = Colors.orange.shade800;
        ic = Icons.handshake_outlined;
        break;
      case 'picked_up':
        bg = Colors.blue.shade50;
        fg = Colors.blue.shade800;
        ic = Icons.local_shipping_outlined;
        break;
      case 'enroute':
        bg = Colors.indigo.shade50;
        fg = Colors.indigo.shade800;
        ic = Icons.timeline_outlined;
        break;
      case 'delivered':
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        ic = Icons.verified_outlined;
        break;
      default:
        bg = cs.surfaceContainerHighest;
        fg = cs.onSurfaceVariant;
        ic = Icons.info_outline;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 12, color: fg),
          const SizedBox(width: 6),
          Text(
            s,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MetaLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen image viewer dialog with action to open Delivery Details.
class _FullScreenImageDialog extends StatelessWidget {
  final String imageUrl;
  final String title;
  final VoidCallback onDetails;

  const _FullScreenImageDialog({
    required this.imageUrl,
    required this.title,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.6,
              maxScale: 4,
              child: Image.network(imageUrl, fit: BoxFit.contain),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: onDetails,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('View Details'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 16,
            left: 16,
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Empty state =====

class _EmptyInfo extends StatelessWidget {
  final String title;
  final String message;
  const _EmptyInfo({required this.title, required this.message});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
