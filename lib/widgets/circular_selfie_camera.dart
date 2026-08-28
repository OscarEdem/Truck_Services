// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter Mobile Application - In-App Circular Selfie Camera Modal
// ====================================================================================================================

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CircularSelfieCamera extends StatefulWidget {
  final String title;
  final String hintText;

  const CircularSelfieCamera({
    super.key,
    this.title = 'Live Driver Facial Selfie',
    this.hintText = 'Center your face inside the circle',
  });

  /// Helper to present the circular camera modal directly
  static Future<File?> show(
    BuildContext context, {
    String title = 'Live Driver Facial Selfie',
    String hintText = 'Center your face inside the circle',
  }) {
    return showModalBottomSheet<File>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false,
      builder: (_) => CircularSelfieCamera(title: title, hintText: hintText),
    );
  }

  @override
  State<CircularSelfieCamera> createState() => _CircularSelfieCameraState();
}

class _CircularSelfieCameraState extends State<CircularSelfieCamera>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _initializing = true;
  bool _hasError = false;
  String? _errorMessage;

  XFile? _capturedFile;
  bool _isTakingPicture = false;

  late AnimationController _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() {
      _initializing = true;
      _hasError = false;
      _errorMessage = null;
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _hasError = true;
          _errorMessage = 'No camera hardware found on this device.';
        });
        return;
      }

      // Default to FRONT camera for selfies
      CameraDescription selfieCam = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        selfieCam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();

      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _hasError = true;
          _errorMessage = 'Could not access camera: $e';
        });
      }
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized || _isTakingPicture) {
      return;
    }

    setState(() => _isTakingPicture = true);
    try {
      final file = await _controller!.takePicture();
      if (mounted) {
        setState(() {
          _capturedFile = file;
          _isTakingPicture = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTakingPicture = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to take selfie: $e')),
        );
      }
    }
  }

  void _retake() {
    setState(() {
      _capturedFile = null;
    });
  }

  void _confirmSelfie() {
    if (_capturedFile != null) {
      Navigator.pop(context, File(_capturedFile!.path));
    }
  }

  double _getPreviewAspectRatio() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return 1.0;
    }
    double aspect = _controller!.value.aspectRatio;
    if (aspect > 1.0) {
      aspect = 1.0 / aspect;
    }
    return aspect;
  }

  @override
  void dispose() {
    _pulseAnim.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;

    return Container(
      height: size.height * 0.88,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // --- Drag Handle & Header ----------------------------------------                                                                                                                                                                                #*eddiere
            const SizedBox(height: 12),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.face_retouching_natural_rounded, color: Color(0xFF0D47A1), size: 24),
                  const SizedBox(width: 10),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFFE2E8F0), height: 1),

            // --- Camera Preview Area -----------------------------------------                                                                                                                                                                                #*eddiere
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_initializing)
                    const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF0D47A1)),
                        SizedBox(height: 16),
                        Text(
                          'Starting Camera...',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                        ),
                      ],
                    )
                  else if (_hasError)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.camera_enhance_outlined, color: Colors.amber, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            _errorMessage ?? 'Camera error occurred.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0D47A1),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _initCamera,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Retry Camera'),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    // --- Circular Camera / Photo Frame Viewfinder ------------                                                                                                                                                                                #*eddiere
                    Center(
                      child: AnimatedBuilder(
                        animation: _pulseAnim,
                        builder: (context, child) {
                          final double borderWidth = 3 + (_pulseAnim.value * 2);
                          return Container(
                            width: 270,
                            height: 270,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _capturedFile != null
                                    ? const Color(0xFF10B981)
                                    : Color.lerp(
                                        const Color(0xFF0D47A1),
                                        const Color(0xFF2563EB),
                                        _pulseAnim.value,
                                      )!,
                                width: borderWidth,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (_capturedFile != null
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFF0D47A1))
                                      .withOpacity(0.2 + (_pulseAnim.value * 0.15)),
                                  blurRadius: 18,
                                  spreadRadius: 3,
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: SizedBox(
                                width: 270,
                                height: 270,
                                child: _capturedFile != null
                                    ? Image.file(
                                        File(_capturedFile!.path),
                                        fit: BoxFit.cover,
                                        width: 270,
                                        height: 270,
                                      )
                                    : FittedBox(
                                        fit: BoxFit.cover,
                                        child: SizedBox(
                                          width: 270,
                                          height: 270 / _getPreviewAspectRatio(),
                                          child: CameraPreview(_controller!),
                                        ),
                                      ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    // --- Guidance Text Overlay ------------------------------                                                                                                                                                                                #*eddiere
                    Positioned(
                      top: size.height * 0.04,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A).withOpacity(0.85),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          _capturedFile != null
                              ? 'Selfie Preview'
                              : widget.hintText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // --- Bottom Action Area -----------------------------------------                                                                                                                                                                                #*eddiere
            Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              color: Colors.white,
              child: _capturedFile != null
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF334155),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: _retake,
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                            label: const Text('Retake'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF0D47A1),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0D47A1).withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _confirmSelfie,
                              icon: const Icon(Icons.check_circle_rounded, size: 20),
                              label: const Text(
                                'Use Selfie',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: GestureDetector(
                        onTap: _isTakingPicture ? null : _takePicture,
                        child: Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.transparent,
                            border: Border.all(color: const Color(0xFF0D47A1), width: 4),
                          ),
                          child: Center(
                            child: Container(
                              width: 60,
                              height: 60,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF0D47A1),
                              ),
                              child: _isTakingPicture
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

