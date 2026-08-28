// lib/features/deliveries/my_deliveries_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../widgets/widgets.dart';
import '../routes/navRoutes.dart';

import '../services/api_service.dart';

class MyDeliveriesScreen extends StatefulWidget {
  const MyDeliveriesScreen({super.key});

  @override
  State<MyDeliveriesScreen> createState() => _MyDeliveriesScreenState();
}

class _MyDeliveriesScreenState extends State<MyDeliveriesScreen> {
  List<Map<String, dynamic>> _apiDeliveries = [];
  bool _loadingApi = true;

  @override
  void initState() {
    super.initState();
    _fetchApiDeliveries();
  }

  Future<void> _fetchApiDeliveries() async {
    if (mounted) setState(() => _loadingApi = true);
    try {
      final list = await ApiService.I.listDeliveries(role: 'customer');
      if (mounted) {
        setState(() {
          _apiDeliveries = list.map((item) => (item as Map).cast<String, dynamic>()).toList();
          _loadingApi = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingApi = false);
      }
    }
  }

  Map<String, dynamic> _normalize(Map<String, dynamic> d) {
    final num? price = d['price'] as num?;
    final int? priceCents = d['price_cents'] as int?;
    final int? computedCents = (priceCents == null && price != null)
        ? (price * 100).round()
        : priceCents;

    String? pickup = (d['pickup_address'] as String?)?.trim();
    String? drop = (d['drop_address'] as String?)?.trim();

    if ((pickup == null || pickup.isEmpty) &&
        d['pickup_lat'] != null &&
        d['pickup_lng'] != null) {
      pickup = '${d['pickup_lat']}, ${d['pickup_lng']}';
    }
    if ((drop == null || drop.isEmpty) &&
        d['drop_lat'] != null &&
        d['drop_lng'] != null) {
      drop = '${d['drop_lat']}, ${d['drop_lng']}';
    }

    final created = d['created_at'];
    DateTime? createdAt;
    if (created is DateTime) {
      createdAt = created;
    } else if (created is String) {
      createdAt = DateTime.tryParse(created);
    }

    return {
      ...d,
      if (computedCents != null) 'price_cents': computedCents,
      'pickup_address': pickup ?? 'Unknown',
      'drop_address': drop ?? 'Unknown',
      'created_at_dt': createdAt,
    };
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const AppScaffold(
        title: 'My Deliveries',
        body: Center(child: Text('Not signed in')),
      );
    }

    if (_loadingApi) {
      return const AppScaffold(
        title: 'My Deliveries',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final mapById = <String, Map<String, dynamic>>{};
    for (final item in _apiDeliveries) {
      final norm = _normalize(item);
      final id = (norm['id'] ?? norm['delivery_id'] ?? '').toString();
      if (id.isNotEmpty) {
        mapById[id] = norm;
      }
    }

    final data = mapById.values.toList();
    data.sort((a, b) {
      final da = a['created_at_dt'] as DateTime?;
      final db = b['created_at_dt'] as DateTime?;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });

    return AppScaffold(
      title: 'My Deliveries',
      body: data.isEmpty
          ? RefreshIndicator(
              onRefresh: _fetchApiDeliveries,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Container(
                  constraints: BoxConstraints(
                    minHeight: MediaQuery.of(context).size.height * 0.7,
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const EmptyPlaceholder(
                        title: 'No deliveries found',
                        message: 'You have not placed any delivery bookings yet.',
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pushNamed(context, NavRoutes.homePage),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          elevation: 0,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        ),
                        icon: const Icon(Icons.add_rounded, color: Colors.white),
                        label: const Text(
                          'Book a Delivery',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchApiDeliveries,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: data.length,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final d = data[i];
                  return _DeliveryCard(
                    delivery: d,
                    onTap: () {
                      Navigator.pushNamed(
                        context,
                        NavRoutes.deliveryDetails,
                        arguments: d,
                      );
                    },
                  );
                },
              ),
            ),
      bottomNavigationBar: MainBottomNav(
        currentRoute: ModalRoute.of(context)?.settings.name,
      ),
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> delivery;
  final VoidCallback onTap;
  const _DeliveryCard({required this.delivery, required this.onTap});

  String _formatGhs(int? cents) {
    if (cents == null) return '—';
    final major = cents / 100.0;
    return 'GH₵ ${major.toStringAsFixed(2)}';
  }

  String _formatWhen(BuildContext context, DateTime? dt) {
    if (dt == null) return '';
    // lightweight friendly timestamp without intl dependency
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    // fallback short date
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  IconData _vehicleIcon(String vehicle, {bool small = false}) {
    // small parameter is here if you want to pick different variants;
    // for now we use the same family to keep visuals consistent.
    switch (vehicle.toLowerCase()) {
      case 'bike':
        return Icons.pedal_bike; // bike
      case 'van':
        return small ? Icons.local_shipping_outlined : Icons.local_shipping;
      case 'truck':
        // Requires Material 3 icons; both exist in recent Flutter versions.
        return small ? Icons.fire_truck_outlined : Icons.fire_truck;
      default:
        return small ? Icons.local_shipping_outlined : Icons.local_shipping;
    }
  }

  // ---- DELIVERY CARD COMPONENT --------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  @override
  Widget build(BuildContext context) {
    final pickup = (delivery['pickup_address'] ?? 'Unknown').toString();
    final drop = (delivery['drop_address'] ?? 'Unknown').toString();
    final priceCents = delivery['price_cents'] as int?;
    final vehicle = (delivery['vehicle_type'] ?? 'vehicle').toString();
    final status = (delivery['status'] ?? 'pending').toString();
    final createdAt = delivery['created_at_dt'] as DateTime?;
    final when = _formatWhen(context, createdAt);

    final leadingIcon = _vehicleIcon(vehicle);
    final metaIcon = _vehicleIcon(vehicle, small: true);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
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
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Vehicle Icon Container
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFDBEAFE)),
                ),
                child: Icon(leadingIcon, color: const Color(0xFF2563EB), size: 22),
              ),
              const SizedBox(width: 12),

              // Content Area
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Pickup -> Dropoff route
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pickup,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: Color(0xFF94A3B8),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            drop,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Metadata row
                    Row(
                      children: [
                        const Icon(Icons.schedule_rounded, size: 14, color: Color(0xFF64748B)),
                        const SizedBox(width: 4),
                        Text(
                          when,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(width: 10),
                        Icon(metaIcon, size: 14, color: const Color(0xFF64748B)),
                        const SizedBox(width: 4),
                        Text(
                          vehicle,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Status Chip
                    Align(
                      alignment: Alignment.centerLeft,
                      child: StatusChip(status: status),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // Price & Arrow
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatGhs(priceCents),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF059669),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.chevron_right_rounded, color: Color(0xFF94A3B8)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
