class OtpArgs {
  final String verificationId;
  final String phone;
  final int? resendToken;
  const OtpArgs({
    required this.verificationId,
    required this.phone,
    this.resendToken,
  });
}
