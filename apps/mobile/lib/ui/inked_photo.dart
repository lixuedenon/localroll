// apps/mobile/lib/ui/inked_photo.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localroll_ink/localroll_ink.dart';

import '../l10n/l10n.dart';
import '../services/phone_notes.dart';
import 'ink_editor_page.dart';

/// A photo in a full-screen viewer, with what was drawn on it, and a pen
/// button that opens the drawing page. Pinch to zoom as before.
class InkedPhoto extends StatefulWidget {
  const InkedPhoto({super.key, required this.image, this.inkKey});

  final ImageProvider image;

  /// Where its drawings are kept (null: no drawing here).
  final String? inkKey;

  @override
  State<InkedPhoto> createState() => _InkedPhotoState();
}

class _InkedPhotoState extends State<InkedPhoto> {
  /// Width / height, once the picture is decoded.
  double? _aspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(InkedPhoto old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final s = widget.image.resolve(createLocalImageConfiguration(context));
    if (s.key == _stream?.key) return;
    _stop();
    _listener = ImageStreamListener((info, _) {
      final w = info.image.width, h = info.image.height;
      if (mounted && h > 0) setState(() => _aspect = w / h);
      _stop();
    }, onError: (_, _) => _stop());
    _stream = s;
    s.addListener(_listener!);
  }

  void _stop() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ar = _aspect;
    final key = widget.inkKey;
    Widget pic = Image(image: widget.image, fit: BoxFit.contain, gaplessPlayback: true);
    if (ar != null) {
      pic = AspectRatio(
        aspectRatio: ar,
        child: Stack(fit: StackFit.expand, children: [
          Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true),
          if (key != null)
            ListenableBuilder(
              listenable: PhoneNotes.instance,
              builder: (_, _) => IgnorePointer(
                child: CustomPaint(painter: InkPainter(notes: PhoneNotes.instance.of(key), video: false)),
              ),
            ),
        ]),
      );
    }
    return Stack(children: [
      Positioned.fill(child: InteractiveViewer(maxScale: 6, child: Center(child: pic))),
      if (key != null && ar != null)
        Positioned(
          right: 16,
          bottom: 16,
          child: InkPenButton(
            onPressed: () => unawaited(openInkEditor(
              context,
              inkKey: key,
              aspect: ar,
              background: Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true),
            )),
          ),
        ),
    ]);
  }
}

/// The round "draw on it" button over photos and videos.
class InkPenButton extends StatelessWidget {
  const InkPenButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tr('ink.draw'),
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.draw_rounded, color: Colors.white, size: 24),
            ),
          ),
        ),
      );
}
