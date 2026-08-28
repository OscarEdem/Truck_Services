class OtpArgs {
  final String verificationId;
  final String phone;
  final int? resendToken;
  final String? role;

  const OtpArgs({
    required this.verificationId,
    required this.phone,
    this.resendToken,
    this.role,
  });
}
