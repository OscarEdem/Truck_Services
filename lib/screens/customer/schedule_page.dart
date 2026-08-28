// lib/features/schedule/schedule_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../routes/navRoutes.dart';
import '../../widgets/widgets.dart';
import '../../services/estimation_service.dart';

enum ScheduleRepeat { none, daily, weekly, monthly }

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return AppScaffold(
      title: 'Scheduled Deliveries',
      actions: [
        IconButton(
          tooltip: 'New schedule',
          onPressed: () => _openCreateSheet(context),
          icon: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
        ),
      ],
      body: uid == null
          ? const EmptyPlaceholder(
              title: 'Sign in required',
              message: 'Log in to view & create schedules.',
            )
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .collection('schedules')
                  .orderBy('start_time', descending: false)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                if (snap.hasError) {
                  return ErrorPlaceholder(message: 'Error: ${snap.error}');
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const EmptyPlaceholder(
                    title: 'No schedules yet',
                    message: 'Tap the + icon to book one.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final id = docs[i].id;
                    final dt = (d['start_time'] as Timestamp?)?.toDate();
                    final veh = _vehicleFromString(d['vehicle_type'] ?? 'bike');
                    final addr =
                        '${d['pickup_address']} → ${d['drop_address']}';
                    final freq = (d['repeat'] ?? 'none') as String;
                    final price = d['price_cents'] is int
                        ? 'GH₵ ${((d['price_cents'] as int) / 100).toStringAsFixed(2)}'
                        : (d['price']?.toString() ?? '');

                    return Card(
                      elevation: 0,
                      child: ListTile(
                        leading: Icon(_iconFor(veh)),
                        title: Text(
                          addr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_fmt(dt)}  •  ${freq.toUpperCase()}  •  $price',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            switch (v) {
                              case 'share':
                                _shareTracking(context, d['tracking_id']);
                                break;
                              case 'repeat':
                                _repeatNow(context, d);
                                break;
                              case 'cancel':
                                _cancelSchedule(uid, id);
                                break;
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'share',
                              child: Text('Share link'),
                            ),
                            const PopupMenuItem(
                              value: 'repeat',
                              child: Text('Repeat now'),
                            ),
                            const PopupMenuItem(
                              value: 'cancel',
                              child: Text('Cancel'),
                            ),
                          ],
                        ),
                        onTap: () {
                          // Jump to edit if needed later
                        },
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemCount: docs.length,
                );
              },
            ),
    );
  }

  static String _fmt(DateTime? dt) {
    if (dt == null) return '';
    final d = dt.toLocal();
    String two(n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
  }

  static VehicleType _vehicleFromString(String s) {
    switch (s) {
      case 'van':
        return VehicleType.van;
      case 'truck':
        return VehicleType.truck;
      default:
        return VehicleType.bike;
    }
  }

  static IconData _iconFor(VehicleType v) => switch (v) {
    VehicleType.bike => Icons.pedal_bike,
    VehicleType.van => Icons.local_shipping_outlined,
    VehicleType.truck => Icons.fire_truck,
  };

  Future<void> _cancelSchedule(String uid, String scheduleId) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('schedules')
        .doc(scheduleId)
        .update({
          'status': 'cancelled',
          'cancelled_at': FieldValue.serverTimestamp(),
        });
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Schedule cancelled')));
    }
  }

  Future<void> _shareTracking(BuildContext context, String? trackingId) async {
    final link = trackingId == null
        ? null
        : 'https://cargomate.page.link/track/$trackingId'; // swap to dyn links later
    if (link == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No tracking link yet')));
      return;
    }
    try {
      await Share.share(link, subject: 'Track my scheduled delivery');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard')),
        );
      }
    }
  }

  Future<void> _repeatNow(BuildContext context, Map<String, dynamic> d) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final deliveries = FirebaseFirestore.instance.collection('deliveries');
    final payload = {
      'sender_id': uid,
      'pickup_address': d['pickup_address'],
      'pickup_lat': d['pickup_lat'],
      'pickup_lng': d['pickup_lng'],
      'drop_address': d['drop_address'],
      'drop_lat': d['drop_lat'],
      'drop_lng': d['drop_lng'],
      'vehicle_type': d['vehicle_type'],
      'status': 'pending',
      'created_at': FieldValue.serverTimestamp(),
      'price_cents': d['price_cents'],
    };
    final ref = await deliveries.add(payload);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Rebooked as ${ref.id}')));
    }
    // Navigate to details if you like
    if (mounted) {
      Navigator.pushNamed(
        context,
        NavRoutes.deliveryDetails,
        arguments: {'id': ref.id, ...payload},
      );
    }
  }

  Future<void> _openCreateSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const _CreateScheduleSheet(),
    );
  }
}

class _CreateScheduleSheet extends StatefulWidget {
  const _CreateScheduleSheet();

  @override
  State<_CreateScheduleSheet> createState() => _CreateScheduleSheetState();
}

class _CreateScheduleSheetState extends State<_CreateScheduleSheet> {
  final _pickupCtrl = TextEditingController();
  final _dropCtrl = TextEditingController();
  VehicleType _vehicle = VehicleType.bike;
  ScheduleRepeat _repeat = ScheduleRepeat.none;
  DateTime? _when;

  double? _pLat, _pLng, _dLat, _dLng;
  FareQuote? _quote;
  bool _saving = false;

  @override
  void dispose() {
    _pickupCtrl.dispose();
    _dropCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick(BuildContext ctx, bool isPickup) async {
    final res = await Navigator.pushNamed(ctx, NavRoutes.mapPicker);
    if (res is Map) {
      final addr = (res['address'] ?? '').toString();
      final lat = (res['lat'] as num?)?.toDouble();
      final lng = (res['lng'] as num?)?.toDouble();
      setState(() {
        if (isPickup) {
          _pickupCtrl.text = addr;
          _pLat = lat;
          _pLng = lng;
        } else {
          _dropCtrl.text = addr;
          _dLat = lat;
          _dLng = lng;
        }
      });
    }
  }

  Future<void> _estimate() async {
    if (_pLat == null || _pLng == null || _dLat == null || _dLng == null) {
      return;
    }
    setState(() => _quote = null);
    await Future.delayed(const Duration(milliseconds: 300));
    final q = EstimationService.estimate(
      vehicle: _vehicle,
      pickupLat: _pLat!,
      pickupLng: _pLng!,
      dropLat: _dLat!,
      dropLng: _dLng!,
    );
    setState(() => _quote = q);
  }

  Future<void> _save() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_when == null || _pLat == null || _dLat == null) return;

    setState(() => _saving = true);
    final doc = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('schedules')
        .doc();

    final payload = {
      'pickup_address': _pickupCtrl.text.trim(),
      'pickup_lat': _pLat, 'pickup_lng': _pLng,
      'drop_address': _dropCtrl.text.trim(),
      'drop_lat': _dLat, 'drop_lng': _dLng,
      'vehicle_type': _vehicle.name,
      'repeat': _repeat.name, // none | daily | weekly | monthly
      'start_time': Timestamp.fromDate(_when!),
      'status': 'scheduled',
      'created_at': FieldValue.serverTimestamp(),
      if (_quote != null) 'price_cents': _quote!.priceCents,
    };

    await doc.set(payload);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).viewInsets.bottom + 20.0;
    final hasPickup = _pickupCtrl.text.trim().isNotEmpty;
    final hasDrop = _dropCtrl.text.trim().isNotEmpty;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, pad),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle Bar
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header Title
            const Text(
              'New Schedule',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 16),

            // ---------- ROUTE CARD ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2563EB),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(width: 2, height: 24, color: const Color(0xFF93C5FD)),
                      const SizedBox(height: 2),
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: const Color(0xFF4F46E5),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => _pick(context, true),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'PICKUP',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hasPickup ? _pickupCtrl.text : 'Tap to select pickup',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: hasPickup ? FontWeight.w700 : FontWeight.w500,
                                  color: hasPickup ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 12, thickness: 1, color: Color(0xFFE2E8F0)),
                        InkWell(
                          onTap: () => _pick(context, false),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'DROPOFF',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF4F46E5),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hasDrop ? _dropCtrl.text : 'Tap to select dropoff',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: hasDrop ? FontWeight.w700 : FontWeight.w500,
                                  color: hasDrop ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
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
            ),

            const SizedBox(height: 16),

            // ---------- VEHICLE SELECTION ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            _VehicleChips(
              value: _vehicle,
              onChanged: (v) => setState(() {
                _vehicle = v;
                _estimate();
              }),
            ),

            const SizedBox(height: 16),

            // ---------- DATE & TIME PICKER ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            InkWell(
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: now.add(const Duration(days: 1)),
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (d == null) return;
                if (!context.mounted) return;
                final t = await showTimePicker(
                  context: context,
                  initialTime: const TimeOfDay(hour: 9, minute: 0),
                );
                if (t == null) return;
                setState(
                  () => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute),
                );
              },
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_available_rounded, color: Color(0xFF2563EB), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _when == null ? 'Select Date & Time' : _pretty(_when!),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _when != null ? FontWeight.w700 : FontWeight.w500,
                          color: _when != null ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF94A3B8)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ---------- REPEAT FREQUENCY SEGMENTED PILLS ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            const Text(
              'Repeat Frequency',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ScheduleRepeat.values.map((r) {
                  final isSelected = _repeat == r;
                  return GestureDetector(
                    onTap: () => setState(() => _repeat = r),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        r.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: isSelected ? Colors.white : const Color(0xFF64748B),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            if (_quote != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Estimated Fare',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E40AF),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _quote!.formatGHS(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ---------- SAVE CTA BUTTON ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
            Container(
              height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(25),
                gradient: const LinearGradient(
                  colors: [Color(0xFF3D5AFE), Color(0xFF2563EB)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                label: Text(
                  _saving ? 'SAVING...' : 'SAVE SCHEDULE',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _pretty(DateTime dt) {
    String two(n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _VehicleChips extends StatelessWidget {
  final VehicleType value;
  final ValueChanged<VehicleType> onChanged;
  const _VehicleChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final opts = <(VehicleType, String, IconData)>[
      (VehicleType.bike, 'Bike', Icons.two_wheeler_rounded),
      (VehicleType.van, 'Van', Icons.local_shipping_rounded),
      (VehicleType.truck, 'Truck', Icons.fire_truck_rounded),
    ];
    return Row(
      children: opts.map((opt) {
        final type = opt.$1;
        final name = opt.$2;
        final icon = opt.$3;
        final isSelected = value == type;

        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(type),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: isSelected ? Colors.white : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: isSelected ? Colors.white : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
