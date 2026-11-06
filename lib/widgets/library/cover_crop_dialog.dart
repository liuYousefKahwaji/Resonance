import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/services/cover_crop_service.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';

Future<Uint8List?> showCoverCropDialog(BuildContext context, Uint8List bytes) => showResonanceDialog<Uint8List>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CoverCropDialog(bytes: bytes),
);

class CoverCropDialog extends StatefulWidget {
  const CoverCropDialog({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<CoverCropDialog> createState() => _CoverCropDialogState();
}

class _CoverCropDialogState extends State<CoverCropDialog> {
  final _transform = TransformationController();
  Size? _imageSize;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final size = await coverPreviewSize(widget.bytes);
      if (mounted) setState(() => _imageSize = size);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not read this image. Try another image.');
    }
  }

  double _zoom = 1, _side = 0, _baseWidth = 0, _baseHeight = 0;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _reset() {
    _zoom = 1;
    _transform.value = Matrix4.translationValues((_side - _baseWidth) / 2, (_side - _baseHeight) / 2, 0);
  }

  void _setZoom(double zoom) {
    final center = _transform.toScene(Offset(_side / 2, _side / 2));
    final x = (_side / 2 - center.dx * zoom).clamp(_side - _baseWidth * zoom, 0.0);
    final y = (_side / 2 - center.dy * zoom).clamp(_side - _baseHeight * zoom, 0.0);
    _transform.value = Matrix4(zoom, 0, 0, 0, 0, zoom, 0, 0, 0, 0, 1, 0, x, y, 0, 1);
    setState(() => _zoom = zoom);
  }

  Future<void> _apply() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final origin = _transform.toScene(Offset.zero);
      final zoom = _transform.value.getMaxScaleOnAxis();
      final result = await cropCover((
        bytes: widget.bytes,
        left: origin.dx / _baseWidth,
        top: origin.dy / _baseHeight,
        width: _side / zoom / _baseWidth,
        height: _side / zoom / _baseHeight,
      ));
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not crop this image. Try another image.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Size outside the dialog: AlertDialog asks its content for intrinsic sizes.
        final side = math.min(
          360.0,
          math.max(
            96.0,
            math.min(constraints.maxWidth - 112, constraints.maxHeight - MediaQuery.viewInsetsOf(context).bottom - 280),
          ),
        );
        if (_imageSize != null && (_side != side || _baseWidth == 0)) {
          _side = side;
          final scale = math.max(side / _imageSize!.width, side / _imageSize!.height);
          _baseWidth = _imageSize!.width * scale;
          _baseHeight = _imageSize!.height * scale;
          _reset();
        }
        return ResonanceDialog(
          insetPadding: const EdgeInsets.all(24),
          title: Text(context.tr('Crop cover')),
          scrollable: true,
          content: SizedBox(
            width: side,
            child: Builder(
              builder: (context) {
                if (_error != null && _imageSize == null) return Text(context.tr(_error!));
                if (_imageSize == null) {
                  return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.tr('Drag to position. Pinch or use the slider to zoom.'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SizedBox.square(
                        dimension: _side,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            children: [
                              InteractiveViewer(
                                key: const Key('cover-crop-viewport'),
                                transformationController: _transform,
                                constrained: false,
                                alignment: Alignment.topLeft,
                                minScale: 1,
                                maxScale: 4,
                                onInteractionUpdate: (_) =>
                                    setState(() => _zoom = _transform.value.getMaxScaleOnAxis().clamp(1, 4)),
                                child: SizedBox(
                                  width: _baseWidth,
                                  height: _baseHeight,
                                  child: Image.memory(widget.bytes, fit: BoxFit.fill),
                                ),
                              ),
                              const Positioned.fill(
                                child: IgnorePointer(child: CustomPaint(painter: _CropGrid())),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.zoom_out_rounded, size: 20),
                        Expanded(
                          child: Slider(
                            key: const Key('cover-crop-zoom'),
                            min: 1,
                            max: 4,
                            value: _zoom,
                            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
                            onChanged: _saving ? null : _setZoom,
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr('Reset'),
                          onPressed: _saving ? null : () => setState(_reset),
                          icon: const Icon(Icons.restart_alt_rounded, size: 20),
                        ),
                      ],
                    ),
                    if (_error != null)
                      Text(context.tr(_error!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: Text(context.tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: _saving || _imageSize == null ? null : _apply,
              child: _saving
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(context.tr('Use cover')),
            ),
          ],
        );
      },
    ),
  );
}

class _CropGrid extends CustomPainter {
  const _CropGrid();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .3)
      ..strokeWidth = 1;
    for (final fraction in [1 / 3, 2 / 3]) {
      canvas.drawLine(Offset(size.width * fraction, 0), Offset(size.width * fraction, size.height), paint);
      canvas.drawLine(Offset(0, size.height * fraction), Offset(size.width, size.height * fraction), paint);
    }
  }

  @override
  bool shouldRepaint(_CropGrid oldDelegate) => false;
}
