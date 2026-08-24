// lib/features/driver/driver_home_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

// 🔁 Firebase
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../../widgets/widgets.dart';
import '../../../routes/navRoutes.dart';

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage>
    with WidgetsBindingObserver {
  // Firebase handles
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _online = false;
  bool _busy = false;

  StreamSubscription<Position>? _posSub;

  // Available jobs (realtime query)
  List<Map<String, dynamic>> _available = [];
  bool _loadingAvailable = true;
  StreamSubscription<QuerySnapshot>? _availableSub;

  // My active jobs (realtime query)
  List<Map<String, dynamic>> _myJobs = [];
  bool _loadingMy = true;
  StreamSubscription<QuerySnapshot>? _myJobsSub;

  // Completed jobs (delivered)
  List<Map<String, dynamic>> _completed = [];
  bool _loadingCompleted = true;
  StreamSubscription<QuerySnapshot>? _completedSub;

  // Consider these "active" (i.e., not delivered yet)
  static const List<String> _activeStatuses = [
    'pending',
    'accepted',
    'picked_up',
    'enroute',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenAvailable();
    _listenMyJobs();
    _listenCompleted();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _availableSub?.cancel();
    _myJobsSub?.cancel();
    _completedSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On resume, re-listen to queries (defensive)
    if (state == AppLifecycleState.resumed) {
      _availableSub?.cancel();
      _myJobsSub?.cancel();
      _completedSub?.cancel();
      _listenAvailable();
      _listenMyJobs();
      _listenCompleted();
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

    if (value) {
      final granted = await _ensureLocationPermission();
      if (!granted) {
        AppSnack.show(context, 'Location permission required');
        return;
      }
      setState(() => _online = true);

      _posSub?.cancel();
      _posSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen((pos) async {
            try {
              await _db.collection('driver_locations').doc(user.uid).set({
                'driver_id': user.uid,
                'lat': pos.latitude,
                'lng': pos.longitude,
                'updated_at': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            } catch (_) {
              // ignore transient errors
            }
          });
    } else {
      await _posSub?.cancel();
      _posSub = null;
      setState(() => _online = false);
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

  // ===== Data: realtime listeners =====

  void _listenAvailable() {
    setState(() => _loadingAvailable = true);

    // Deliveries that are pending and unassigned:
    _availableSub = _db
        .collection('deliveries')
        .where('status', isEqualTo: 'pending')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snap) {
            final rows = <Map<String, dynamic>>[];
            for (final d in snap.docs) {
              final data = d.data();
              final driverId = data['driver_id'];
              if (driverId == null ||
                  (driverId is String && driverId.isEmpty)) {
                rows.add({'id': d.id, ...data});
              }
            }
            if (!mounted) return;
            setState(() {
              _available = rows;
              _loadingAvailable = false;
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() => _loadingAvailable = false);
            AppSnack.show(context, 'Error loading jobs: $e');
          },
        );
  }

  void _listenMyJobs() {
    setState(() => _loadingMy = true);
    final uid = _auth.currentUser?.uid;

    if (uid == null) {
      setState(() {
        _myJobs = [];
        _loadingMy = false;
      });
      return;
    }

    _myJobsSub = _db
        .collection('deliveries')
        .where('driver_id', isEqualTo: uid)
        .where('status', whereIn: _activeStatuses)
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen(
          (snap) {
            final rows = snap.docs
                .map((d) => {'id': d.id, ...d.data()})
                .toList();
            if (!mounted) return;
            setState(() {
              _myJobs = rows;
              _loadingMy = false;
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() => _loadingMy = false);
            AppSnack.show(context, 'Error loading my jobs: $e');
          },
        );
  }

  void _listenCompleted() {
    setState(() => _loadingCompleted = true);
    final uid = _auth.currentUser?.uid;

    if (uid == null) {
      setState(() {
        _completed = [];
        _loadingCompleted = false;
      });
      return;
    }

    // Delivered jobs for me. If you get an index error in Firestore console,
    // create the suggested composite index for (driver_id, status, delivered_at).
    _completedSub = _db
        .collection('deliveries')
        .where('driver_id', isEqualTo: uid)
        .where('status', isEqualTo: 'delivered')
        .orderBy('delivered_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snap) {
            final rows = snap.docs
                .map((d) => {'id': d.id, ...d.data()})
                .toList();
            if (!mounted) return;
            setState(() {
              _completed = rows;
              _loadingCompleted = false;
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() => _loadingCompleted = false);
            AppSnack.show(context, 'Error loading completed: $e');
          },
        );
  }

  Future<void> _refreshAvailable() async {
    _availableSub?.cancel();
    _listenAvailable();
  }

  Future<void> _refreshMyJobs() async {
    _myJobsSub?.cancel();
    _listenMyJobs();
  }

  Future<void> _refreshCompleted() async {
    _completedSub?.cancel();
    _listenCompleted();
  }

  // ===== Actions: accept / picked_up / deliver + POD (race-safe via transactions) =====

  Future<void> _acceptJob(Map<String, dynamic> row) async {
    final user = _auth.currentUser;
    if (user == null) return;

    setState(() => _busy = true);
    try {
      final docRef = _db.collection('deliveries').doc(row['id'].toString());

      final result = await _db.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) return false;

        final data = snap.data() as Map<String, dynamic>;
        final status = (data['status'] as String?) ?? 'pending';
        final currentDriver = data['driver_id'];

        final unassigned =
            currentDriver == null ||
            (currentDriver is String && currentDriver.isEmpty);

        if (status == 'pending' && unassigned) {
          tx.update(docRef, {
            'driver_id': user.uid,
            'status': 'accepted',
            'accepted_at': FieldValue.serverTimestamp(),
          });
          return true;
        }
        return false;
      });

      if (!mounted) return;

      if (result == true) {
        AppSnack.show(context, 'Job accepted');
        final withDriver = {
          ...row,
          'driver_id': user.uid,
          'status': 'accepted',
        };
        Navigator.pushNamed(
          context,
          NavRoutes.deliveryDetails,
          arguments: withDriver,
        );
      } else {
        AppSnack.show(context, 'Someone else already accepted this job');
        await _refreshAvailable();
      }
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markPickedUp(Map<String, dynamic> row) async {
    final user = _auth.currentUser;
    if (user == null) return;

    setState(() => _busy = true);
    try {
      final docRef = _db.collection('deliveries').doc(row['id'].toString());
      final ok = await _db.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) return false;

        final data = snap.data() as Map<String, dynamic>;
        final status = (data['status'] as String?) ?? 'pending';
        final driverId = data['driver_id'];

        if (driverId == user.uid && status == 'accepted') {
          tx.update(docRef, {
            'status': 'picked_up',
            'picked_up_at': FieldValue.serverTimestamp(),
          });
          return true;
        }
        return false;
      });

      if (!mounted) return;

      if (ok) {
        AppSnack.show(context, 'Package picked up');
        await _refreshMyJobs();
      } else {
        AppSnack.show(context, 'Cannot mark picked up (check status)');
        await _refreshMyJobs();
      }
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deliverWithPod(Map<String, dynamic> row) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final picker = ImagePicker();
    final shot = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (shot == null) return;

    setState(() => _busy = true);
    try {
      // 1) Upload proof to Storage
      final bytes = await shot.readAsBytes();
      final storagePath =
          'pod/${row['id']}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final task = await _storage
          .ref(storagePath)
          .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final podUrl = await task.ref.getDownloadURL();

      // 2) Race-safe delivered state
      final docRef = _db.collection('deliveries').doc(row['id'].toString());
      final ok = await _db.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) return false;

        final data = snap.data() as Map<String, dynamic>;
        final status = (data['status'] as String?) ?? 'pending';
        final driverId = data['driver_id'];

        if (driverId == user.uid && status == 'picked_up') {
          tx.update(docRef, {
            'status': 'delivered',
            'pod_path': storagePath,
            'pod_url': podUrl,
            'delivered_at': FieldValue.serverTimestamp(),
          });
          return true;
        }
        return false;
      });

      if (!mounted) return;

      if (ok) {
        AppSnack.show(context, 'Delivered with proof uploaded');
        await _refreshMyJobs();
        await _refreshCompleted();
      } else {
        AppSnack.show(context, 'Cannot mark delivered (check status)');
      }
    } catch (e) {
      if (mounted) AppSnack.show(context, 'Error delivering: $e');
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
      appBar: AppBar(
        automaticallyImplyLeading: false, // no back button
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 15),
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
      ),
      endDrawer: const DriverDrawer(),

      body: LoadingOverlay(
        show: _busy,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _online
                        ? [const Color(0xFF1B5E20), const Color(0xFF2E7D32)]
                        : [const Color(0xFF37474F), const Color(0xFF455A64)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: (_online ? Colors.green : Colors.black).withOpacity(0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _online ? const Color(0xFF00E676) : Colors.grey.shade400,
                        shape: BoxShape.circle,
                        boxShadow: _online
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF00E676).withOpacity(0.8),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                )
                              ]
                            : [],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _online ? 'ONLINE & READY' : 'OFFLINE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            _online ? 'Receiving real-time freight requests' : 'Toggle switch to start accepting trips',
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
                      activeColor: const Color(0xFF00E676),
                      activeTrackColor: Colors.white.withOpacity(0.3),
                    ),
                  ],
                ),
              ),
              const Divider(),
              const TabBar(
                tabs: [
                  Tab(text: 'Available'),
                  Tab(text: 'My Jobs'),
                  Tab(text: 'Completed'),
                ],
              ),
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
  }) => JobCard._(d: d, kind: _Kind.available, onAccept: onAccept);

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
    final p = d['price'];
    if (p is num) return p.toStringAsFixed(0);
    if (p is String) return p;
    return '--';
    // (If you also store price_cents, you can add the same logic you used elsewhere.)
  }

  String get _vehicle => (d['vehicle_type'] ?? '').toString();

  String _addr(dynamic lat, dynamic lng) {
    return '${lat ?? '--'}, ${lng ?? '--'}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = (d['status'] as String?) ?? '';
    final isCompleted = status == 'delivered';

    final podUrl = (d['pod_url'] as String?) ?? '';
    final hasThumb = isCompleted && podUrl.isNotEmpty;

    return Card(
      elevation: 1.5,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: kind == _Kind.completed
            ? (onOpenPod ?? onOpenDetails)
            : onOpenDetails,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: optional thumbnail for completed (POD) / generic icon otherwise
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 64,
                  width: 64,
                  child: hasThumb
                      ? Image.network(podUrl, fit: BoxFit.cover)
                      : Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(
                            kind == _Kind.available
                                ? Icons.local_offer_outlined
                                : (kind == _Kind.active
                                      ? Icons.directions_bike_outlined
                                      : Icons.check_circle_outline),
                            color: cs.onSurfaceVariant,
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
                    Row(
                      children: [
                        Text(
                          '₵$_priceText',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _LabeledChip(
                          icon: Icons.local_shipping_outlined,
                          label: _vehicle.isEmpty ? 'vehicle' : _vehicle,
                        ),
                        const Spacer(),
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
                            'From: ${_addr(d['pickup_lat'], d['pickup_lng'])}',
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
                            'To:   ${_addr(d['drop_lat'], d['drop_lng'])}',
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
                  if (kind == _Kind.available && onAccept != null)
                    FilledButton(
                      onPressed: onAccept,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(84, 36),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Accept'),
                    ),
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
    if (ts is Timestamp) dt = ts.toDate();
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
