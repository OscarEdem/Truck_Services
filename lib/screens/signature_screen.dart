// lib/screens/signature_screen.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

/// Usage:
/// final Uint8List? pngBytes = await Navigator.push(
///   context,
///   MaterialPageRoute(builder: (_) => const SignatureScreen()),
/// );
/// if (pngBytes != null) { /* upload or save */ }
class SignatureScreen extends StatefulWidget {
  final String title;
  final Color penColor;
  final double penStrokeWidth;
  final Color backgroundColor;

  const SignatureScreen({
    super.key,
    this.title = 'Capture Signature',
    this.penColor = Colors.black,
    this.penStrokeWidth = 3.0,
    this.backgroundColor = Colors.white,
    required Map<String, dynamic> delivery,
  });

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  late final SignatureController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SignatureController(
      penStrokeWidth: widget.penStrokeWidth,
      penColor: widget.penColor,
      exportBackgroundColor: widget.backgroundColor,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    if (_controller.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please draw a signature first.')),
      );
      return;
    }

    // Increase pixelRatio if you want a higher-res image (e.g., 3.0)
    final Uint8List? pngBytes = await _controller.toPngBytes();

    if (!mounted) return;

    if (pngBytes == null || pngBytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not export signature.')),
      );
      return;
    }

    Navigator.pop(context, pngBytes);
  }

  void _onClear() => _controller.clear();
  void _onUndo() => _controller.undo();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _onUndo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: _onClear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          // Signature canvas
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.backgroundColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 10,
                      spreadRadius: 1,
                      color: Colors.black.withOpacity(0.05),
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Signature(
                    controller: _controller,
                    backgroundColor: widget.backgroundColor,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Buttons
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _onSave,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
