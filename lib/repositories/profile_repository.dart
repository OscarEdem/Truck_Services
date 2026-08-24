// ====================================================================================================================                                                                                                                                                            me            #*eddiere
// CargoMate Mobile App - Pure REST API Profile Repository (Features/Repositories)
// ====================================================================================================================

import '../services/api_service.dart';

class ProfileRepository {
  ProfileRepository();

  Future<Map<String, dynamic>?> fetchMyProfile() async {
    try {
      return await ApiService.I.getMe();
    } catch (_) {
      return null;
    }
  }

  Future<void> updateMyProfile(Map<String, dynamic> patch) async {
    await ApiService.I.updateMe(patch);
  }
}
