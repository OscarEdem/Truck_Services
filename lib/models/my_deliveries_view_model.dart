import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/delivery_repository.dart';
import '../models/delivery.dart';

class MyDeliveriesViewModel extends ChangeNotifier {
  MyDeliveriesViewModel(this._repo);

  final DeliveryRepository _repo;

  final List<Delivery> _items = [];
  List<Delivery> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool get loading => _loading;

  DocumentSnapshot<Map<String, dynamic>>? _cursor; // last doc for paging
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  Future<void> refresh({List<String>? statuses}) async {
    _items.clear();
    _cursor = null;
    _hasMore = true;
    notifyListeners();
    await loadNext(statuses: statuses);
  }

  Future<void> loadNext({int pageSize = 20, List<String>? statuses}) async {
    if (_loading || !_hasMore) return;
    _loading = true;
    notifyListeners();

    try {
      final result = await _repo.fetchMyDeliveries(
        limit: pageSize,
        startAfter: _cursor,
        statuses: statuses,
      );
      _items.addAll(result);

      // move cursor: we need the underlying DocumentSnapshot; easiest: refetch with .get()
      // For simplicity here, we infer hasMore by count:
      if (result.length < pageSize) _hasMore = false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Live version if you prefer realtime instead of paging
  Stream<List<Delivery>> stream({List<String>? statuses}) {
    return _repo.streamMyDeliveries(statuses: statuses);
  }
}
