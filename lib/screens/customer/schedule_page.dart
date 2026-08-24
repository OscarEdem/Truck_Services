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
      title: 'Scheduled deliveries',
      actions: [
        IconButton(
          tooltip: 'New schedule',
          onPressed: () => _openCreateSheet(context),
          icon: const Icon(Icons.add_circle_outline),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
    final pad = MediaQuery.of(context).viewInsets.bottom + 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('New schedule', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _pickupCtrl,
            decoration: InputDecoration(
              labelText: 'Pickup',
              prefixIcon: const Icon(Icons.my_location),
              suffixIcon: IconButton(
                icon: const Icon(Icons.map_outlined),
                onPressed: () => _pick(context, true),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _dropCtrl,
            decoration: InputDecoration(
              labelText: 'Dropoff',
              prefixIcon: const Icon(Icons.location_on_outlined),
              suffixIcon: IconButton(
                icon: const Icon(Icons.map_outlined),
                onPressed: () => _pick(context, false),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _VehicleChips(
                  value: _vehicle,
                  onChanged: (v) => setState(() => _vehicle = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.access_time),
                  label: Text(
                    _when == null ? 'Pick date & time' : _pretty(_when!),
                  ),
                  onPressed: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                      context: context,
                      initialDate: now.add(const Duration(days: 1)),
                      firstDate: now,
                      lastDate: now.add(const Duration(days: 365)),
                    );
                    if (d == null) return;
                    final t = await showTimePicker(
                      context: context,
                      initialTime: const TimeOfDay(hour: 9, minute: 0),
                    );
                    if (t == null) return;
                    setState(
                      () => _when = DateTime(
                        d.year,
                        d.month,
                        d.day,
                        t.hour,
                        t.minute,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<ScheduleRepeat>(
                value: _repeat,
                onChanged: (v) => setState(() => _repeat = v!),
                items: ScheduleRepeat.values
                    .map(
                      (r) => DropdownMenuItem(
                        value: r,
                        child: Text(r.name.toUpperCase()),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.attach_money),
                  label: const Text('Estimate'),
                  onPressed: _estimate,
                ),
              ),
              const SizedBox(width: 8),
              if (_quote != null)
                Text(
                  _quote!.formatGHS(),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_saving ? 'Saving…' : 'Save schedule'),
              ),
            ),
          ),
        ],
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
      (VehicleType.bike, 'Bike', Icons.pedal_bike),
      (VehicleType.van, 'Van', Icons.local_shipping_outlined),
      (VehicleType.truck, 'Truck', Icons.fire_truck),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: opts.map((o) {
        final (v, label, icon) = o;
        return ChoiceChip.elevated(
          selected: v == value,
          onSelected: (_) => onChanged(v),
          avatar: Icon(icon, size: 18),
          label: Text(label),
        );
      }).toList(),
    );
  }
}
