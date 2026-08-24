import 'package:flutter/foundation.dart';
import '../models/delivery_repository.dart';
import '../models/delivery.dart';

class DriverJobsViewModel extends ChangeNotifier {
  DriverJobsViewModel(this._repo);

  final DeliveryRepository _repo;

  // Realtime streams
  Stream<List<Delivery>> availableStream() => _repo.streamAvailable();

  Stream<List<Delivery>> myActiveStream() => _repo.streamMyDeliveries(
    statuses: const ['pending', 'accepted', 'picked_up', 'enroute'],
  );

  Future<bool> accept(String deliveryId) => _repo.acceptJob(deliveryId);

  Future<bool> updateStatus(String deliveryId, String status) =>
      _repo.updateStatus(deliveryId, status);
}
