// lib/features/chat/chat_screen.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatScreen extends StatefulWidget {
  final Map<String, dynamic>
  delivery; // pass delivery map with id, sender_id, driver_id/biker_id
  const ChatScreen({super.key, required this.delivery});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  final _msgCtl = TextEditingController();
  final _listCtl = ScrollController();
  final _focusNode = FocusNode();

  late final String _deliveryId;
  late final String? _senderId;
  late final String? _driverId;
  late final String? _bikerId;

  String? _me;
  String? _peer;

  // Display names (loaded from profiles/{uid})
  String? _meName;
  String? _peerName;

  bool _sending = false;
  bool _typing = false;
  Timer? _typingDebounce;

  @override
  void initState() {
    super.initState();

    _deliveryId = (widget.delivery['id'] ?? widget.delivery['doc_id'] ?? '')
        .toString();
    _senderId = widget.delivery['sender_id']?.toString();
    _driverId = widget.delivery['driver_id']?.toString();
    _bikerId = widget.delivery['biker_id']?.toString();

    _me = _auth.currentUser?.uid;
    _peer = _computePeer();

    // Load human-readable names for header
    _loadDisplayNames();

    // mark as read on open (slight delay to allow UI mount)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markAllAsRead();
      _scrollToBottom(immediate: true);
    });

    _msgCtl.addListener(_handleTypingChanged);
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _msgCtl.removeListener(_handleTypingChanged);
    _msgCtl.dispose();
    _listCtl.dispose();
    _focusNode.dispose();
    _setTyping(false); // best-effort: not critical if it fails
    super.dispose();
  }

  String? _computePeer() {
    if (_me == null) return null;
    // participants: sender vs driver or biker (whichever exists)
    final carrier = (_driverId?.isNotEmpty ?? false) ? _driverId : _bikerId;
    if (_me == _senderId) return carrier;
    return _senderId ?? carrier;
  }

  /// Load display names for me/peer from profiles/{uid}
  Future<void> _loadDisplayNames() async {
    try {
      final me = _me;
      final peer = _peer;
      String? meName;
      String? peerName;
      if (me != null && me.isNotEmpty) {
        meName = await _fetchProfileName(me);
      }
      if (peer != null && peer.isNotEmpty) {
        peerName = await _fetchProfileName(peer);
      }
      if (!mounted) return;
      setState(() {
        _meName = meName;
        _peerName = peerName;
      });
    } catch (_) {
      // ignore; header will fall back gracefully
    }
  }

  /// Try several likely profile fields to get a nice name.
  Future<String?> _fetchProfileName(String uid) async {
    try {
      final doc = await _db.collection('profiles').doc(uid).get();
      if (!doc.exists) return null;
      final p = doc.data()!;
      // Priority order
      final candidates = <String?>[
        p['display_name'] as String?,
        p['full_name'] as String?,
        p['name'] as String?,
        // combine first/last if present
        _joinNameParts(p['first_name'], p['last_name']),
        p['username'] as String?,
        // as very last resort, phone
        p['phone'] as String? ?? p['phone_number'] as String?,
      ].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty);
      final first = candidates.isNotEmpty ? candidates.first : null;
      return first;
    } catch (_) {
      return null;
    }
  }

  String? _joinNameParts(dynamic first, dynamic last) {
    final f = (first is String) ? first.trim() : '';
    final l = (last is String) ? last.trim() : '';
    if (f.isEmpty && l.isEmpty) return null;
    return [f, l].where((s) => s.isNotEmpty).join(' ');
  }

  CollectionReference<Map<String, dynamic>> get _msgsCol =>
      _db.collection('deliveries').doc(_deliveryId).collection('messages');

  DocumentReference<Map<String, dynamic>> get _deliveryRef =>
      _db.collection('deliveries').doc(_deliveryId);

  DocumentReference<Map<String, dynamic>> get _typingRef =>
      _deliveryRef.collection('chat_meta').doc('typing');

  void _handleTypingChanged() {
    final nowTyping = _msgCtl.text.trim().isNotEmpty;
    if (nowTyping == _typing) return;
    _typing = nowTyping;

    _setTyping(_typing);

    // debounce: when user stops typing, clear typing after ~1.5s
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      _typing = false;
      _setTyping(false);
    });
  }

  Future<void> _setTyping(bool value) async {
    final uid = _me;
    if (uid == null) return;
    try {
      await _typingRef.set({
        uid: value,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _markAllAsRead() async {
    final uid = _me;
    if (uid == null) return;
    try {
      // mark last 100 recent not-mine messages as read
      final q = await _msgsCol
          .orderBy('created_at', descending: true)
          .limit(100)
          .get();
      final batch = _db.batch();
      for (final doc in q.docs) {
        final m = doc.data();
        if (m['sender_id'] == uid) continue;
        final List readBy = (m['read_by'] as List?) ?? [];
        if (!readBy.contains(uid)) {
          batch.update(doc.reference, {
            'read_by': FieldValue.arrayUnion([uid]),
          });
        }
      }
      await batch.commit();
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _send() async {
    final uid = _me;
    if (uid == null) {
      _snack('You must be signed in to send messages.');
      return;
    }
    final txt = _msgCtl.text.trim();
    if (txt.isEmpty || _deliveryId.isEmpty) return;

    setState(() => _sending = true);
    try {
      final now = FieldValue.serverTimestamp();
      final data = <String, dynamic>{
        'type': 'text',
        'body': txt,
        'sender_id': uid,
        'created_at': now,
        'read_by': [uid],
      };

      final msgRef = await _msgsCol.add(data);

      // update delivery summary
      await _deliveryRef.set({
        'last_message': txt,
        'last_message_at': now,
        'participants': _participantsArray(),
      }, SetOptions(merge: true));

      _msgCtl.clear();
      _scrollToBottom();
    } catch (e) {
      _snack('Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  List<String> _participantsArray() {
    final set = <String>{};
    if (_senderId?.isNotEmpty ?? false) set.add(_senderId!);
    if (_driverId?.isNotEmpty ?? false) set.add(_driverId!);
    if (_bikerId?.isNotEmpty ?? false) set.add(_bikerId!);
    if (_me?.isNotEmpty ?? false) set.add(_me!);
    if (_peer?.isNotEmpty ?? false) set.add(_peer!);
    return set.toList();
  }

  void _scrollToBottom({bool immediate = false}) {
    if (!_listCtl.hasClients) return;
    if (immediate) {
      _listCtl.jumpTo(_listCtl.position.maxScrollExtent);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_listCtl.hasClients) return;
        _listCtl.animateTo(
          _listCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _callPeer() async {
    final targetId = _peer;
    if (targetId == null || targetId.isEmpty) return;
    // very thin: assumes 'profiles/{uid}'.phone or .phone_number
    try {
      final pDoc = await _db.collection('profiles').doc(targetId).get();
      String? phone;
      if (pDoc.exists) {
        final data = pDoc.data()!;
        phone = (data['phone'] as String?) ?? (data['phone_number'] as String?);
      }
      phone = phone?.trim();
      if (phone == null || phone.isEmpty) {
        _snack('No phone available for this user.');
        return;
      }
      final uri = Uri(scheme: 'tel', path: phone);
      await launchUrl(uri);
    } catch (e) {
      _snack('Could not start a call: $e');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _shortUid(String? uid) {
    if (uid == null || uid.isEmpty) return 'unknown';
    return uid.length > 6 ? '…${uid.substring(uid.length - 6)}' : uid;
  }

  /// Build a friendly, name-first title.
  /// - If we have both names: "Me ↔ Peer"
  /// - If only peer: "Chat with <Peer>"
  /// - Fallback: roles + short code.
  String _titleText() {
    final code = (_deliveryId.length >= 6)
        ? _deliveryId.substring(_deliveryId.length - 6)
        : _deliveryId;

    if (_meName != null && _peerName != null) {
      return '${_meName!} ↔ ${_peerName!} • #$code';
    }
    if (_peerName != null) {
      return 'Chat with ${_peerName!} • #$code';
    }
    // Last resort: show roles or short uids
    final meIsSender = (_me != null && _me == _senderId);
    final role = meIsSender ? 'Driver/Biker' : 'Customer';
    final peerIdForFallback = _peer ?? '';
    return '$role • ${_shortUid(peerIdForFallback)} • #$code';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleText(), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Call',
            onPressed: _callPeer,
            icon: const Icon(Icons.call_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          // typing indicator
          _TypingBanner(doc: _typingRef, me: _me),
          const Divider(height: 1),

          // messages
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _msgsCol
                  .orderBy('created_at', descending: false)
                  .limit(500)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }

                final docs = snap.data?.docs ?? const [];
                // mark read when new data arrives
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _markAllAsRead(),
                );
                // scroll down on new message
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _scrollToBottom(),
                );

                if (docs.isEmpty) {
                  return const Center(child: Text('Say hello 👋'));
                }

                final items = <Widget>[];
                DateTime? lastDay;
                for (final doc in docs) {
                  final m = doc.data();
                  final ts = (m['created_at'] as Timestamp?);
                  final dt = ts?.toDate();
                  // date divider
                  if (dt != null) {
                    final dOnly = DateTime(dt.year, dt.month, dt.day);
                    if (lastDay == null || dOnly.isAfter(lastDay)) {
                      lastDay = dOnly;
                      items.add(_DayDivider(date: dOnly));
                    }
                  }
                  items.add(
                    _Bubble(
                      text: (m['body'] ?? '').toString(),
                      mine: m['sender_id'] == _me,
                      time: dt,
                      delivered: _isDeliveredRead(m),
                      color: cs,
                    ),
                  );
                }

                return ListView(
                  controller: _listCtl,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  children: items,
                );
              },
            ),
          ),

          // input
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtl,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isDeliveredRead(Map<String, dynamic> m) {
    // show small check if peer has read
    final List readBy = (m['read_by'] as List?) ?? const [];
    if (_peer == null) return false;
    return readBy.contains(_peer);
  }
}

/* --- widgets -------------------------------------------------------------- */

class _Bubble extends StatelessWidget {
  final String text;
  final bool mine;
  final DateTime? time;
  final bool delivered;
  final ColorScheme color;

  const _Bubble({
    required this.text,
    required this.mine,
    required this.time,
    required this.delivered,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bg = mine ? color.primaryContainer : color.surfaceContainerHighest;
    final fg = mine ? color.onPrimaryContainer : color.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(text, style: TextStyle(color: fg, fontSize: 15)),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _fmt(time),
                    style: TextStyle(color: fg.withOpacity(0.7), fontSize: 11),
                  ),
                  if (mine) ...[
                    const SizedBox(width: 6),
                    Icon(
                      delivered ? Icons.done_all : Icons.check,
                      size: 14,
                      color: fg.withOpacity(delivered ? 0.95 : 0.7),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime? dt) {
    if (dt == null) return '--:--';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final am = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $am';
    // For cross-day, a date divider is already used above.
  }
}

class _DayDivider extends StatelessWidget {
  final DateTime date;
  const _DayDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final txt =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(txt, style: Theme.of(context).textTheme.labelSmall),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _TypingBanner extends StatelessWidget {
  final DocumentReference<Map<String, dynamic>> doc;
  final String? me;
  const _TypingBanner({required this.doc, required this.me});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: doc.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) return const SizedBox.shrink();
        final data = snap.data!.data()!;
        final entries = data.entries.where((e) => e.key != 'updated_at');
        // show if someone else is typing
        final anyoneElseTyping = entries.any((e) {
          if (e.key == me) return false;
          final v = e.value;
          return v == true || v == 'true' || v == 1;
        });
        if (!anyoneElseTyping) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            'Typing…',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        );
      },
    );
  }
}
