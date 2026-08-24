import 'package:flutter/material.dart';
import '../widgets/widgets.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <Map<String, String>>[
      {
        'title': 'Delivery delivered',
        'body': 'Your bike order to East Legon has been delivered.',
      },
      {
        'title': 'Price drop',
        'body': 'Evening van rates are 10% off this week.',
      },
      {
        'title': 'New feature',
        'body': 'You can now schedule repeating deliveries.',
      },
    ];

    return AppScaffold(
      title: 'Notifications',
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final it = items[i];
          return Card(
            elevation: 0,
            child: ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(it['title']!),
              subtitle: Text(it['body']!),
            ),
          );
        },
      ),
    );
  }
}
