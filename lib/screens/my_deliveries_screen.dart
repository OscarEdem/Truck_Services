// lib/features/deliveries/my_deliveries_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../widgets/widgets.dart';
import '../routes/navRoutes.dart';

class MyDeliveriesScreen extends StatelessWidget {
  const MyDeliveriesScreen({super.key});

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

    // Normalize created_at to DateTime for stable sorting/rendering
    final created = d['created_at'];
    DateTime? createdAt;
    if (created is Timestamp) {
      createdAt = created.toDate();
    } else if (created is DateTime) {
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
    final auth = FirebaseAuth.instance;
    final db = FirebaseFirestore.instance;

    final uid = auth.currentUser?.uid;
    if (uid == null) {
      return const AppScaffold(
        title: 'My Deliveries',
        body: Center(child: Text('Not signed in')),
      );
    }

    // Avoid composite index: no orderBy; we sort client-side instead.
    final q = db
        .collection('deliveries')
        .where('sender_id', isEqualTo: uid)
        .snapshots();

    return AppScaffold(
      title: 'My Deliveries',
      body: StreamBuilder<QuerySnapshot>(
        stream: q,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorPlaceholder(
              message: 'Error: ${snap.error}',
              onRetry: () {},
            );
          }

          final docs = snap.data?.docs ?? [];
          final data = docs.map((doc) {
            final m = {'id': doc.id, ...(doc.data() as Map<String, dynamic>)};
            return _normalize(m);
          }).toList();

          // Sort DESC by created_at_dt (nulls last)
          data.sort((a, b) {
            final da = a['created_at_dt'] as DateTime?;
            final dbb = b['created_at_dt'] as DateTime?;
            if (da == null && dbb == null) return 0;
            if (da == null) return 1;
            if (dbb == null) return -1;
            return dbb.compareTo(da);
          });

          if (data.isEmpty) {
            return const EmptyPlaceholder(
              title: 'No deliveries yet',
              message: 'Book your first delivery to see it here.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {},
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
          );
        },
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

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final pickup = (delivery['pickup_address'] ?? 'Unknown').toString();
    final drop = (delivery['drop_address'] ?? 'Unknown').toString();
    final priceCents = delivery['price_cents'] as int?;
    final vehicle = (delivery['vehicle_type'] ?? 'vehicle').toString();
    final status = (delivery['status'] ?? 'pending').toString();
    final createdAt = delivery['created_at_dt'] as DateTime?;
    final when = _formatWhen(context, createdAt);

    final leadingIcon = _vehicleIcon(vehicle);
    final metaIcon = _vehicleIcon(vehicle, small: true);

    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Leading tonal icon (vehicle-specific)
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(leadingIcon, color: color.onSecondaryContainer),
              ),
              const SizedBox(width: 12),

              // Middle: content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title line: pickup → drop
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pickup,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.arrow_forward,
                          size: 18,
                          color: color.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            drop,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Meta row: time • vehicle (vehicle-specific icon)
                    Row(
                      children: [
                        Icon(Icons.schedule, size: 16, color: color.outline),
                        const SizedBox(width: 4),
                        Text(
                          when,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: color.outline),
                        ),
                        const SizedBox(width: 10),
                        Icon(metaIcon, size: 16, color: color.outline),
                        const SizedBox(width: 4),
                        Text(
                          vehicle,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: color.outline),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Status chip (uses your existing widget)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: StatusChip(status: status),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Trailing: price + chevron
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatGhs(priceCents),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Icon(Icons.chevron_right, color: color.outline),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
