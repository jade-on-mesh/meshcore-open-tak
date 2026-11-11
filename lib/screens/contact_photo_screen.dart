import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../services/contact_photos.dart';
import '../helpers/snack_bar_builder.dart';

/// "Set photo": picks a picture, lets the person place it in a circle, and
/// saves it as [contact]'s photo ([ContactPhotos]).
Future<void> pickContactPhoto(BuildContext context, Contact contact) async {
  final XFile? picked;
  try {
    picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  } catch (e) {
    if (context.mounted) {
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.contactPhoto_failed('$e')),
      );
    }
    return;
  }
  if (picked == null || !context.mounted) return;
  final bytes = await picked.readAsBytes();
  if (!context.mounted) return;
  final png = await Navigator.push<Uint8List>(
    context,
    MaterialPageRoute(
      builder: (_) => ContactPhotoCropScreen(source: bytes, name: contact.name),
    ),
  );
  if (png == null) return;
  await ContactPhotos.instance.set(contact.publicKeyHex, png);
}

/// "Set photo" and, once one is set, "Remove photo", for a contact's menu.
List<Widget> contactPhotoTiles(
  BuildContext context,
  Contact contact, {
  required VoidCallback close,
}) {
  final photos = ContactPhotos.instance;
  if (!photos.supported) return const [];
  final l10n = context.l10n;
  final has = photos.has(contact.publicKeyHex);
  return [
    ListTile(
      leading: const Icon(Icons.account_circle_outlined),
      title: Text(has ? l10n.contactPhoto_change : l10n.contactPhoto_set),
      onTap: () {
        close();
        pickContactPhoto(context, contact);
      },
    ),
    if (has)
      ListTile(
        leading: const Icon(Icons.no_photography_outlined),
        title: Text(l10n.contactPhoto_remove),
        onTap: () {
          close();
          photos.remove(contact.publicKeyHex);
        },
      ),
  ];
}

/// Drag and pinch the picture inside the circle; "Use" saves what the circle
/// shows, as a square PNG drawn in a circle wherever the contact appears.
class ContactPhotoCropScreen extends StatefulWidget {
  final Uint8List source;
  final String name;

  const ContactPhotoCropScreen({
    super.key,
    required this.source,
    required this.name,
  });

  /// The saved photo's width and height, in pixels.
  static const int outputSize = 320;

  @override
  State<ContactPhotoCropScreen> createState() => _ContactPhotoCropScreenState();
}

class _ContactPhotoCropScreenState extends State<ContactPhotoCropScreen> {
  final _boundary = GlobalKey();
  final _transform = TransformationController();
  Size? _imageSize;
  double? _placedFor;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _decodeSize();
  }

  Future<void> _decodeSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.source);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(
        () => _imageSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        ),
      );
      frame.image.dispose();
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _use() async {
    final box =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (box == null) return;
    setState(() => _saving = true);
    try {
      final side = box.size.width;
      final image = await box.toImage(
        pixelRatio: ContactPhotoCropScreen.outputSize / side,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || data == null) return;
      Navigator.pop(context, data.buffer.asUint8List());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final size = _imageSize;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(l10n.contactPhoto_title(widget.name)),
        actions: [
          TextButton(
            onPressed: size == null || _saving ? null : _use,
            child: Text(l10n.contactPhoto_use),
          ),
        ],
      ),
      body: size == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final side =
                    (constraints.biggest.shortestSide - 32).clamp(120.0, 600.0);
                // The picture's shorter side fills the circle; the rest can
                // be dragged into it.
                final fit = side / size.shortestSide;
                final w = size.width * fit, h = size.height * fit;
                if (_placedFor != side) {
                  _placedFor = side;
                  _transform.value = Matrix4.translationValues(
                    -(w - side) / 2,
                    -(h - side) / 2,
                    0,
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SizedBox.square(
                          dimension: side,
                          child: Stack(
                            children: [
                              RepaintBoundary(
                                key: _boundary,
                                child: ClipRect(
                                  child: InteractiveViewer(
                                    transformationController: _transform,
                                    constrained: false,
                                    minScale: 1,
                                    maxScale: 8,
                                    boundaryMargin: EdgeInsets.zero,
                                    child: Image.memory(
                                      widget.source,
                                      width: w,
                                      height: h,
                                      fit: BoxFit.fill,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                child: CustomPaint(
                                  size: Size.square(side),
                                  painter: _CircleMask(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Text(
                        l10n.contactPhoto_hint,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// Darkens outside the circle and outlines it.
class _CircleMask extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(1));
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      circle,
    );
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_CircleMask old) => false;
}
