import 'package:flutter/material.dart';

/// Landmarks are fractions of each image, not of the surrounding UI card.
class BodyMapGeometry {
  final Size pixels;
  final double throat;
  final double chest;
  final double abdomen;
  const BodyMapGeometry(this.pixels, this.throat, this.chest, this.abdomen);

  static BodyMapGeometry forAsset(String asset) => switch (asset.split('/').last) {
    'adult_female.png' => const BodyMapGeometry(Size(234, 650), .19, .285, .405),
    'child_female.png' => const BodyMapGeometry(Size(224, 650), .225, .32, .425),
    'child_male.png' => const BodyMapGeometry(Size(230, 650), .215, .32, .44),
    _ => const BodyMapGeometry(Size(240, 646), .17, .27, .41),
  };

  // Radius is a fraction of image width, keeping the highlight on the body.
  List<(Offset, double)> markers(String location) {
    if (location.contains('Galva') || location == 'Veidas') {
      return [(Offset(.5, throat * .5), .14)];
    }
    if (location.contains('Gerkl')) return [(Offset(.5, throat), .085)];
    if (location.contains('Krūtin')) return [(Offset(.5, chest), .17)];
    if (location == 'Viršutinėje pilvo dalyje') return [(Offset(.5, abdomen - .045), .13)];
    // Anatomical right is on the viewer's left in a front-facing illustration.
    if (location == 'Dešinėje') return [(Offset(.36, abdomen), .11)];
    if (location == 'Kairėje') return [(Offset(.64, abdomen), .11)];
    if (location == 'Apatinėje dalyje') return [(Offset(.5, abdomen + .045), .13)];
    if (location == 'Pilvas' || location == 'Visą pilvą') return [(Offset(.5, abdomen), .18)];
    if (location.contains('Nugara')) return [(Offset(.5, (chest + abdomen) / 2), .17)];
    if (location.contains('Rank')) return [(Offset(.12, abdomen), .10), (Offset(.88, abdomen), .10)];
    if (location.contains('Koj')) return [(const Offset(.34, .75), .10), (const Offset(.66, .75), .10)];
    if (location.contains('Sąnariai')) {
      return [(Offset(.17, abdomen - .02), .07), (Offset(.83, abdomen - .02), .07),
        (const Offset(.34, .72), .08), (const Offset(.66, .72), .08)];
    }
    // Unknown or multiple unspecified regions must not imply one precise spot.
    return [];
  }
}

class BodyMapView extends StatelessWidget {
  final String asset;
  final String location;
  final String errorLabel;
  const BodyMapView({super.key, required this.asset, required this.location,
    required this.errorLabel});

  @override
  Widget build(BuildContext context) {
    final geometry = BodyMapGeometry.forAsset(asset);
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: geometry.pixels.width,
        height: geometry.pixels.height,
        child: Image.asset(
          asset,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.high,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame == null && !synchronous) return child;
            return CustomPaint(
              foregroundPainter: BodyMapMarkerPainter(geometry, location),
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) => Center(
            child: Text(errorLabel, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}

class BodyMapMarkerPainter extends CustomPainter {
  final BodyMapGeometry geometry;
  final String location;
  const BodyMapMarkerPainter(this.geometry, this.location);

  @override
  void paint(Canvas canvas, Size size) {
    const green = Color(0xff079b7a);
    for (final marker in geometry.markers(location)) {
      final center = Offset(marker.$1.dx * size.width, marker.$1.dy * size.height);
      final radius = marker.$2 * size.width;
      canvas.drawCircle(center, radius * 1.22, Paint()..color = green.withValues(alpha: .12));
      canvas.drawCircle(center, radius, Paint()..color = green.withValues(alpha: .22));
      canvas.drawCircle(center, radius, Paint()..color = green
        ..style = PaintingStyle.stroke..strokeWidth = size.width * .016);
      canvas.drawCircle(center, size.width * .023, Paint()..color = const Color(0xff102a43));
    }
  }

  @override
  bool shouldRepaint(covariant BodyMapMarkerPainter oldDelegate) =>
      oldDelegate.location != location || oldDelegate.geometry != geometry;
}
