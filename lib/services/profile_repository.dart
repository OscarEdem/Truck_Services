// ====================================================================================================================                                                                                                                                                            me            #*eddiere
// CargoMate Mobile App - Pure REST API Profile Repository
// ====================================================================================================================

import 'api_service.dart';

class ProfileRepository {
  ProfileRepository();

  /// Fetch the current user's profile info from Go REST API gateway
  Future<Map<String, dynamic>?> fetchMyProfile() async {
    try {
      return await ApiService.I.getMe();
    } catch (_) {
      return null;
    }
  }

  /// Update current user's profile with a partial patch via Go REST API gateway
  Future<void> updateMyProfile(Map<String, dynamic> patch) async {
    await ApiService.I.updateMe(patch);
  }
}
