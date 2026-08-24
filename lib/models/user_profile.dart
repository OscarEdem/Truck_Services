// lib/models/user_profile.dart
class UserProfile {
  final String id;
  final String? fullName;
  final String? role;         // 'customer'|'driver'|'admin'
  final String? phone;
  final String? fcmToken;
  final String? avatarUrl;
  final bool? isOnline;

  UserProfile({
    required this.id,
    this.fullName,
    this.role,
    this.phone,
    this.fcmToken,
    this.avatarUrl,
    this.isOnline,
  });

  factory UserProfile.fromMap(String id, Map<String, dynamic> data) {
    return UserProfile(
      id: id,
      fullName: data['full_name'] as String?,
      role: data['role'] as String?,
      phone: data['phone'] as String?,
      fcmToken: data['fcm_token'] as String?,
      avatarUrl: data['avatar_url'] as String?,
      isOnline: data['is_online'] as bool?,
    );
  }

  Map<String, dynamic> toMap() => {
        'full_name': fullName,
        'role': role,
        'phone': phone,
        'fcm_token': fcmToken,
        'avatar_url': avatarUrl,
        'is_online': isOnline,
      };
}
