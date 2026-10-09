// apps/mobile/lib/ui/scan_page.dart
import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/l10n.dart';

/// Scans the pairing QR code shown in the desktop app's 「接收」 page.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _hint;

  /// 0 = no zoom, 1 = maximum zoom.
  double _zoom = 0;
  double _zoomAtPinchStart = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setZoom(double z) {
    final v = z.clamp(0.0, 1.0);
    setState(() => _zoom = v);
    _controller.setZoomScale(v);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final p = PairingPayload.tryDecode(b.rawValue);
      if (p != null) {
        _done = true;
        Navigator.of(context).pop(p);
        return;
      }
    }
    setState(() => _hint = tr('scan.not_ours'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('scan.title'))),
      body: Stack(
        children: [
          // Pinch to zoom, so the PC's QR code can be read from a normal distance.
          GestureDetector(
            onScaleStart: (_) => _zoomAtPinchStart = _zoom,
            onScaleUpdate: (d) => _setZoom(_zoomAtPinchStart + (d.scale - 1) * 0.5),
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              // Show why the camera is unavailable instead of a black screen.
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    tr('scan.camera_error', {'error': error.errorCode.name}),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
                    child: Row(
                      children: [
                        IconButton(
                          color: Colors.white,
                          onPressed: () => _setZoom(_zoom - 0.1),
                          icon: const Icon(Icons.zoom_out),
                        ),
                        Expanded(child: Slider(value: _zoom, onChanged: _setZoom)),
                        IconButton(
                          color: Colors.white,
                          onPressed: () => _setZoom(_zoom + 0.1),
                          icon: const Icon(Icons.zoom_in),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      _hint ?? tr('scan.hint'),
                      style: const TextStyle(color: Colors.white),
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
