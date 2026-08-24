// import 'dart:typed_data';
// import 'package:flutter/material.dart';
// import 'package:signature/signature.dart';
// import 'package:supabase_flutter/supabase_flutter.dart';

// class SignatureScreen extends StatefulWidget {
//   final Map<String, dynamic> delivery;
//   const SignatureScreen({super.key, required this.delivery});

//   @override
//   State<SignatureScreen> createState() => _SignatureScreenState();
// }

// class _SignatureScreenState extends State<SignatureScreen> {
//   final SignatureController _controller = SignatureController(penStrokeWidth: 3);
//   bool _saving = false;

//   Future<void> _save() async {
//     setState(() => _saving = true);
//     try {
//       final bytes = await _controller.toPngBytes();
//       if (bytes == null) throw 'No signature';
//       final supa = Supabase.instance.client;
//       final id = widget.delivery['id'].toString();
//       final name = 'signatures/$id/${DateTime.now().millisecondsSinceEpoch}.png';
//       await supa.storage.from('signatures').uploadBinary(name, bytes as Uint8List, fileOptions: const FileOptions(contentType: 'image/png'));
//       await supa.from('deliveries').update({'signature_path': name}).eq('id', id);
//       if (mounted) Navigator.pop(context);
//     } catch (e) {
//       // ignore for now; ideally show a SnackBar
//     } finally {
//       if (mounted) setState(() => _saving = false);
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('Recipient Signature')),
//       body: Column(
//         children: [
//           Expanded(
//             child: Container(
//               margin: const EdgeInsets.all(16),
//               decoration: BoxDecoration(
//                 border: Border.all(color: Colors.grey.shade400),
//                 borderRadius: BorderRadius.circular(8),
//               ),
//               child: Signature(
//                 controller: _controller,
//                 backgroundColor: Colors.white,
//               ),
//             ),
//           ),
//           SafeArea(
//             child: Padding(
//               padding: const EdgeInsets.all(16.0),
//               child: Row(
//                 children: [
//                   Expanded(
//                     child: OutlinedButton(
//                       onPressed: () => _controller.clear(),
//                       child: const Text('Clear'),
//                     ),
//                   ),
//                   const SizedBox(width: 12),
//                   Expanded(
//                     child: ElevatedButton(
//                       onPressed: _saving ? null : _save,
//                       child: Text(_saving ? 'Saving…' : 'Save'),
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
