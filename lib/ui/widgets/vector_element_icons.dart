import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../simulation/element_registry.dart';

/// Clean vector icons for each element type, drawn with Canvas paths.
///
/// These replace the old 8x8 pixel-art approach. Each icon is a recognizable
/// shape drawn at full resolution with gradients and smooth curves.
/// A 5-year-old can tell what "water" or "fire" is at a glance.
class VectorElementIcon extends CustomPainter {
  VectorElementIcon(this.elId, this.baseColor, this.phase, {this.size = 48});

  final int elId;
  final Color baseColor;
  final double phase;
  final double size;

  Color _light([double amount = 0.3]) =>
      Color.lerp(baseColor, Colors.white, amount)!;
  Color _dark([double amount = 0.3]) =>
      Color.lerp(baseColor, Colors.black, amount)!;

  double _wave(double speed, [double offset = 0.0]) =>
      math.sin((phase * speed + offset) * math.pi * 2);
  double _pulse(double speed, [double offset = 0.0]) =>
      (_wave(speed, offset) + 1.0) * 0.5;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final h = s.height;
    final cx = w / 2;
    final cy = h / 2;

    switch (elId) {
      case El.water:
        _drawWater(canvas, w, h, cx, cy);
      case El.fire:
        _drawFire(canvas, w, h, cx, cy);
      case El.sand:
        _drawSand(canvas, w, h, cx, cy);
      case El.stone:
        _drawStone(canvas, w, h, cx, cy);
      case El.metal:
        _drawMetal(canvas, w, h, cx, cy);
      case El.copper:
        _drawCopper(canvas, w, h, cx, cy);
      case El.lightning:
        _drawLightning(canvas, w, h, cx, cy);
      case El.plant:
        _drawPlant(canvas, w, h, cx, cy);
      case El.ice:
        _drawIce(canvas, w, h, cx, cy);
      case El.lava:
        _drawLava(canvas, w, h, cx, cy);
      case El.acid:
        _drawAcid(canvas, w, h, cx, cy);
      case El.oil:
        _drawOil(canvas, w, h, cx, cy);
      case El.wood:
        _drawWood(canvas, w, h, cx, cy);
      case El.dirt:
        _drawDirt(canvas, w, h, cx, cy);
      case El.mud:
        _drawMud(canvas, w, h, cx, cy);
      case El.glass:
        _drawGlass(canvas, w, h, cx, cy);
      case El.snow:
        _drawSnow(canvas, w, h, cx, cy);
      case El.steam:
        _drawSteam(canvas, w, h, cx, cy);
      case El.smoke:
        _drawSmoke(canvas, w, h, cx, cy);
      case El.tnt:
        _drawTnt(canvas, w, h, cx, cy);
      case El.rainbow:
        _drawRainbow(canvas, w, h, cx, cy);
      case El.seed:
        _drawSeed(canvas, w, h, cx, cy);
      case El.bubble:
        _drawBubble(canvas, w, h, cx, cy);
      case El.ash:
        _drawAsh(canvas, w, h, cx, cy);
      case El.ant:
        _drawAnt(canvas, w, h, cx, cy);
      case El.honey:
        _drawHoney(canvas, w, h, cx, cy);
      case El.fungus:
        _drawFungus(canvas, w, h, cx, cy);
      case El.oxygen:
      case El.co2:
      case El.hydrogen:
      case El.methane:
        _drawGas(canvas, w, h, cx, cy);
      case El.spore:
        _drawSpore(canvas, w, h, cx, cy);
      case El.algae:
        _drawAlgae(canvas, w, h, cx, cy);
      case El.web:
        _drawWeb(canvas, w, h, cx, cy);
      case El.salt:
        _drawSalt(canvas, w, h, cx, cy);
      case El.sulfur:
        _drawSulfur(canvas, w, h, cx, cy);
      case El.clay:
        _drawClay(canvas, w, h, cx, cy);
      case El.charcoal:
        _drawCharcoal(canvas, w, h, cx, cy);
      case El.compost:
        _drawCompost(canvas, w, h, cx, cy);
      case El.rust:
        _drawRust(canvas, w, h, cx, cy);
      case El.eraser:
        _drawEraser(canvas, w, h, cx, cy);
      // Neural plants
      case El.seaweed:
        _drawSeaweed(canvas, w, h, cx, cy);
      case El.moss:
        _drawMoss(canvas, w, h, cx, cy);
      case El.vine:
        _drawVine(canvas, w, h, cx, cy);
      case El.flower:
        _drawFlower(canvas, w, h, cx, cy);
      case El.root:
        _drawRoot(canvas, w, h, cx, cy);
      case El.thorn:
        _drawThorn(canvas, w, h, cx, cy);
      // Explosives & radioactives
      case El.c4:
        _drawC4(canvas, w, h, cx, cy);
      case El.uranium:
        _drawUranium(canvas, w, h, cx, cy);
      case El.lead:
        _drawLeadElement(canvas, w, h, cx, cy);
      // Atmospherics
      case El.vapor:
        _drawVapor(canvas, w, h, cx, cy);
      case El.cloud:
        _drawCloud(canvas, w, h, cx, cy);
      // Notable metals
      case El.gold:
        _drawGoldElement(canvas, w, h, cx, cy);
      case El.silver:
        _drawSilverElement(canvas, w, h, cx, cy);
      case El.platinum:
        _drawPlatinumElement(canvas, w, h, cx, cy);
      case El.mercury:
        _drawMercury(canvas, w, h, cx, cy);
      case El.titanium:
        _drawTitanium(canvas, w, h, cx, cy);
      case El.aluminum:
        _drawAluminum(canvas, w, h, cx, cy);
      case El.silicon:
        _drawSilicon(canvas, w, h, cx, cy);
      case El.carbon:
        _drawDiamond(canvas, w, h, cx, cy);
      default:
        // Family-based icons for periodic table elements
        final family = elementFamily[elId];
        switch (family) {
          case ElFamily.nobleGas:
            _drawNobleGas(canvas, w, h, cx, cy);
          case ElFamily.alkaliMetal:
            _drawAlkaliMetal(canvas, w, h, cx, cy);
          case ElFamily.alkalineEarth:
            _drawAlkalineEarth(canvas, w, h, cx, cy);
          case ElFamily.transitionMetal:
            _drawTransitionMetal(canvas, w, h, cx, cy);
          case ElFamily.postTransition:
            _drawPostTransition(canvas, w, h, cx, cy);
          case ElFamily.metalloid:
            _drawMetalloid(canvas, w, h, cx, cy);
          case ElFamily.nonmetal:
            _drawNonmetal(canvas, w, h, cx, cy);
          case ElFamily.halogen:
            _drawHalogen(canvas, w, h, cx, cy);
          case ElFamily.lanthanide:
            _drawLanthanide(canvas, w, h, cx, cy);
          case ElFamily.actinide:
            _drawActinide(canvas, w, h, cx, cy);
          case ElFamily.superheavy:
            _drawSuperheavy(canvas, w, h, cx, cy);
          default:
            _drawGeneric(canvas, w, h, cx, cy);
        }
    }
  }

  // -- WATER: Smooth teardrop with gradient fill --
  void _drawWater(Canvas c, double w, double h, double cx, double cy) {
    final wobble = _wave(1.0) * 1.5;
    final path = Path();
    // Teardrop: pointed top, round bottom
    final topY = h * 0.15 + wobble;
    path.moveTo(cx, topY);
    path.cubicTo(cx + w * 0.35, cy * 0.6, cx + w * 0.38, cy + h * 0.15,
        cx, h * 0.82);
    path.cubicTo(cx - w * 0.38, cy + h * 0.15, cx - w * 0.35, cy * 0.6,
        cx, topY);

    final gradient = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_light(0.4), baseColor, _dark(0.2)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    c.drawPath(path, gradient);

    // Inner highlight
    final highlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.3 + _pulse(1.5) * 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.08, cy - h * 0.05),
          width: w * 0.2,
          height: h * 0.25),
      highlight,
    );
  }

  // -- FIRE: Flowing flame shape with inner glow --
  void _drawFire(Canvas c, double w, double h, double cx, double cy) {
    final flicker = _wave(2.0) * 2;
    final path = Path();
    // Flame: wide at base, dancing tip
    path.moveTo(cx, h * 0.08 + flicker);
    path.cubicTo(cx + w * 0.12 + flicker, h * 0.25, cx + w * 0.38, h * 0.4,
        cx + w * 0.32, h * 0.65);
    path.cubicTo(cx + w * 0.28, h * 0.8, cx + w * 0.1, h * 0.88, cx, h * 0.88);
    path.cubicTo(cx - w * 0.1, h * 0.88, cx - w * 0.28, h * 0.8,
        cx - w * 0.32, h * 0.65);
    path.cubicTo(cx - w * 0.38, h * 0.4, cx - w * 0.12 + flicker, h * 0.25,
        cx, h * 0.08 + flicker);

    final gradient = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFFFF8E0),
          const Color(0xFFFFCC00),
          baseColor,
          const Color(0xFFCC2200),
        ],
        stops: const [0.0, 0.25, 0.55, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    c.drawPath(path, gradient);

    // Inner core glow
    final core = Paint()
      ..color = const Color(0xAAFFFFDD)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx, cy * 0.75),
          width: w * 0.2,
          height: h * 0.3),
      core,
    );
  }

  // -- SAND: Small pile of smooth circles --
  void _drawSand(Canvas c, double w, double h, double cx, double cy) {
    final colors = [
      baseColor,
      _light(0.15),
      _dark(0.1),
      _light(0.25),
      _dark(0.05),
    ];
    // Pile of overlapping grains
    final grains = [
      Offset(cx - w * 0.2, h * 0.72),
      Offset(cx + w * 0.18, h * 0.74),
      Offset(cx, h * 0.68),
      Offset(cx - w * 0.08, h * 0.58),
      Offset(cx + w * 0.1, h * 0.6),
      Offset(cx, h * 0.5 - _pulse(0.5) * 3),
      // Falling grain
      Offset(cx + w * 0.05, h * 0.2 + _pulse(0.8) * h * 0.2),
    ];
    final sizes = [w * 0.16, w * 0.14, w * 0.15, w * 0.12, w * 0.13, w * 0.11, w * 0.08];

    for (var i = 0; i < grains.length; i++) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [colors[i % colors.length], _dark(0.15)],
        ).createShader(
            Rect.fromCircle(center: grains[i], radius: sizes[i]));
      c.drawCircle(grains[i], sizes[i], paint);
    }
  }

  // -- STONE: Angular rock with facets --
  void _drawStone(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(cx - w * 0.05, h * 0.18);
    path.lineTo(cx + w * 0.3, h * 0.22);
    path.lineTo(cx + w * 0.38, h * 0.5);
    path.lineTo(cx + w * 0.25, h * 0.78);
    path.lineTo(cx - w * 0.15, h * 0.82);
    path.lineTo(cx - w * 0.35, h * 0.6);
    path.lineTo(cx - w * 0.3, h * 0.3);
    path.close();

    final gradient = Paint()
      ..shader = LinearGradient(
        begin: const Alignment(-0.5, -1),
        end: const Alignment(0.5, 1),
        colors: [_light(0.25), baseColor, _dark(0.2)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    c.drawPath(path, gradient);

    // Facet highlight line
    final facet = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    c.drawLine(Offset(cx - w * 0.05, h * 0.18),
        Offset(cx + w * 0.25, h * 0.78), facet);
  }

  // -- METAL: Smooth rectangle with metallic gradient and reflection --
  void _drawMetal(Canvas c, double w, double h, double cx, double cy) {
    final sheenPos = _pulse(0.5);
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 0.65, height: h * 0.7),
      const Radius.circular(4),
    );
    final gradient = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_light(0.35), baseColor, _dark(0.15), baseColor, _light(0.2)],
        stops: [0.0, 0.3, 0.5, 0.7, 1.0],
      ).createShader(rr.outerRect);
    c.drawRRect(rr, gradient);

    // Sweeping reflection line
    final reflectY = h * 0.15 + sheenPos * h * 0.7;
    final reflect = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 2.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    c.drawLine(Offset(w * 0.2, reflectY), Offset(w * 0.8, reflectY), reflect);
  }

  // -- COPPER: Same as metal but warm copper gradient --
  void _drawCopper(Canvas c, double w, double h, double cx, double cy) {
    final sheenPos = _pulse(0.4);
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 0.65, height: h * 0.7),
      const Radius.circular(4),
    );
    final gradient = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          _light(0.35),
          baseColor,
          _dark(0.15),
          baseColor,
          _light(0.2),
        ],
        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
      ).createShader(rr.outerRect);
    c.drawRRect(rr, gradient);

    // Green patina streak at top
    final patina = Paint()
      ..color = const Color(0x4050A070)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.1, h * 0.22),
          width: w * 0.35,
          height: h * 0.12),
      patina,
    );

    // Reflection
    final reflectY = h * 0.2 + sheenPos * h * 0.6;
    final reflect = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1.8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    c.drawLine(Offset(w * 0.2, reflectY), Offset(w * 0.8, reflectY), reflect);
  }

  // -- LIGHTNING: Clean vector bolt --
  void _drawLightning(Canvas c, double w, double h, double cx, double cy) {
    final flicker = _pulse(3.0);
    final alpha = 0.6 + flicker * 0.4;

    final bolt = Path();
    bolt.moveTo(cx + w * 0.12, h * 0.08);
    bolt.lineTo(cx - w * 0.08, h * 0.42);
    bolt.lineTo(cx + w * 0.08, h * 0.42);
    bolt.lineTo(cx - w * 0.12, h * 0.92);
    bolt.lineTo(cx + w * 0.05, h * 0.55);
    bolt.lineTo(cx - w * 0.08, h * 0.55);
    bolt.close();

    // Outer glow
    final glow = Paint()
      ..color = baseColor.withValues(alpha: alpha * 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    c.drawPath(bolt, glow);

    // Bolt fill
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, baseColor, _dark(0.1)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    c.drawPath(bolt, fill);
  }

  // -- PLANT: Simple leaf/sprout --
  void _drawPlant(Canvas c, double w, double h, double cx, double cy) {
    final sway = _wave(0.7) * 2;

    // Stem
    final stem = Paint()
      ..color = _dark(0.2)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final stemPath = Path();
    stemPath.moveTo(cx, h * 0.88);
    stemPath.cubicTo(cx, h * 0.6, cx + sway, h * 0.4, cx + sway * 0.5, h * 0.2);
    c.drawPath(stemPath, stem);

    // Left leaf
    final leafL = Path();
    leafL.moveTo(cx - 1 + sway * 0.3, h * 0.45);
    leafL.cubicTo(cx - w * 0.35, h * 0.25, cx - w * 0.3, h * 0.55,
        cx - 1 + sway * 0.3, h * 0.45);
    c.drawPath(
        leafL,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.3),
            colors: [_light(0.2), baseColor],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Right leaf (larger)
    final leafR = Path();
    leafR.moveTo(cx + 1 + sway * 0.3, h * 0.35);
    leafR.cubicTo(cx + w * 0.4, h * 0.12, cx + w * 0.35, h * 0.52,
        cx + 1 + sway * 0.3, h * 0.35);
    c.drawPath(
        leafR,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0.3, -0.3),
            colors: [_light(0.25), baseColor, _dark(0.1)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));
  }

  // -- ICE: Crystal / faceted gem --
  void _drawIce(Canvas c, double w, double h, double cx, double cy) {
    // Hexagonal crystal
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = (i * 60 - 90) * math.pi / 180;
      final r = w * 0.36;
      final x = cx + math.cos(angle) * r;
      final y = cy + math.sin(angle) * r;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    final gradient = Paint()
      ..shader = LinearGradient(
        begin: const Alignment(-1, -1),
        end: const Alignment(1, 1),
        colors: [Colors.white, _light(0.4), baseColor, _dark(0.1)],
        stops: const [0.0, 0.3, 0.6, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    c.drawPath(path, gradient);

    // Sparkle
    final sparkle = Paint()
      ..color = Colors.white.withValues(alpha: 0.4 + _pulse(1.5) * 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    c.drawCircle(Offset(cx - w * 0.1, cy - h * 0.1), 2.5, sparkle);
  }

  // -- LAVA: Glowing molten blob with crust cracks --
  void _drawLava(Canvas c, double w, double h, double cx, double cy) {
    // Blob shape
    final blobR = w * 0.35;
    c.drawCircle(
        Offset(cx, cy),
        blobR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFFDD60),
              baseColor,
              _dark(0.3),
              const Color(0xFF331100),
            ],
            stops: const [0.0, 0.3, 0.65, 1.0],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: blobR)));

    // Crust cracks
    final crackPaint = Paint()
      ..color = const Color(0xFF222200)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    c.drawLine(Offset(cx - w * 0.15, cy - h * 0.1),
        Offset(cx + w * 0.2, cy + h * 0.05), crackPaint);
    c.drawLine(Offset(cx + w * 0.05, cy - h * 0.2),
        Offset(cx - w * 0.1, cy + h * 0.15), crackPaint);

    // Outer glow
    c.drawCircle(
        Offset(cx, cy),
        blobR + 3,
        Paint()
          ..color = baseColor.withValues(alpha: 0.2 + _pulse(0.8) * 0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
  }

  // -- ACID: Bubbling droplet in green --
  void _drawAcid(Canvas c, double w, double h, double cx, double cy) {
    // Main droplet
    final path = Path();
    path.moveTo(cx, h * 0.2);
    path.cubicTo(cx + w * 0.3, cy * 0.7, cx + w * 0.35, cy + h * 0.1,
        cx, h * 0.78);
    path.cubicTo(cx - w * 0.35, cy + h * 0.1, cx - w * 0.3, cy * 0.7,
        cx, h * 0.2);

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.3),
            colors: [_light(0.3), baseColor, _dark(0.2)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Bubbles
    final bubbleY = h * 0.3 + _pulse(1.2) * h * 0.2;
    c.drawCircle(
        Offset(cx + w * 0.08, bubbleY),
        3,
        Paint()..color = _light(0.4).withValues(alpha: 0.7));
    c.drawCircle(
        Offset(cx - w * 0.12, bubbleY + 8),
        2,
        Paint()..color = _light(0.3).withValues(alpha: 0.5));

    // Toxic glow
    c.drawCircle(
        Offset(cx, cy),
        w * 0.3,
        Paint()
          ..color = baseColor.withValues(alpha: 0.15 + _pulse(1.0) * 0.1)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
  }

  // -- OIL: Dark droplet with iridescent sheen --
  void _drawOil(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(cx, h * 0.18);
    path.cubicTo(cx + w * 0.32, cy * 0.65, cx + w * 0.36, cy + h * 0.12,
        cx, h * 0.8);
    path.cubicTo(cx - w * 0.36, cy + h * 0.12, cx - w * 0.32, cy * 0.65,
        cx, h * 0.18);

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.2, -0.3),
            colors: [_light(0.15), baseColor, _dark(0.3)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Iridescent highlight
    final iriPhase = _pulse(0.8);
    final iriColor = HSVColor.fromAHSV(0.25, iriPhase * 360, 0.5, 0.8).toColor();
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.05, cy - h * 0.08),
          width: w * 0.25,
          height: h * 0.15),
      Paint()
        ..color = iriColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  // -- WOOD: Log cross-section with rings --
  void _drawWood(Canvas c, double w, double h, double cx, double cy) {
    // Rounded rectangle trunk section
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 0.65, height: h * 0.7),
      const Radius.circular(6),
    );
    c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_light(0.15), baseColor, _dark(0.15)],
          ).createShader(rr.outerRect));

    // Growth rings
    final ringPaint = Paint()
      ..color = _dark(0.2).withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var r = 4.0; r < w * 0.28; r += 4.0) {
      c.drawCircle(Offset(cx, cy), r, ringPaint);
    }
  }

  // -- DIRT: Rounded mound with speckles --
  void _drawDirt(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(w * 0.1, h * 0.75);
    path.cubicTo(w * 0.15, h * 0.35, w * 0.45, h * 0.2, cx, h * 0.22);
    path.cubicTo(w * 0.55, h * 0.2, w * 0.85, h * 0.35, w * 0.9, h * 0.75);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_light(0.1), baseColor, _dark(0.15)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Small pebble specks
    final speckPaint = Paint()..color = _light(0.2).withValues(alpha: 0.5);
    c.drawCircle(Offset(cx - w * 0.12, h * 0.55), 1.5, speckPaint);
    c.drawCircle(Offset(cx + w * 0.15, h * 0.5), 1.2, speckPaint);
    c.drawCircle(Offset(cx + w * 0.05, h * 0.65), 1.0, speckPaint);
  }

  // -- MUD: Glossy dark blob --
  void _drawMud(Canvas c, double w, double h, double cx, double cy) {
    // Amorphous blob
    final path = Path();
    path.moveTo(cx - w * 0.3, h * 0.7);
    path.cubicTo(cx - w * 0.35, h * 0.4, cx - w * 0.1, h * 0.25, cx, h * 0.22);
    path.cubicTo(cx + w * 0.1, h * 0.25, cx + w * 0.35, h * 0.4, cx + w * 0.3, h * 0.7);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.2, -0.4),
            colors: [_light(0.15), baseColor, _dark(0.2)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Glossy highlight
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.06, h * 0.35),
          width: w * 0.2,
          height: h * 0.08),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  // -- GLASS: Transparent diamond with refraction --
  void _drawGlass(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(cx, h * 0.12);
    path.lineTo(cx + w * 0.35, cy);
    path.lineTo(cx, h * 0.88);
    path.lineTo(cx - w * 0.35, cy);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: const Alignment(-1, -1),
            end: const Alignment(1, 1),
            colors: [
              Colors.white.withValues(alpha: 0.4),
              baseColor.withValues(alpha: 0.25),
              Colors.white.withValues(alpha: 0.15),
            ],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Edge outline
    c.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0);

    // Sparkle
    c.drawCircle(
        Offset(cx + w * 0.08, cy - h * 0.12),
        2.0,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5 + _pulse(2.0) * 0.3));
  }

  // -- SNOW: Stylized snowflake --
  void _drawSnow(Canvas c, double w, double h, double cx, double cy) {
    final paint = Paint()
      ..color = baseColor
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 6 arms
    final r = w * 0.32;
    for (var i = 0; i < 6; i++) {
      final angle = (i * 60 - 90) * math.pi / 180;
      final ex = cx + math.cos(angle) * r;
      final ey = cy + math.sin(angle) * r;
      c.drawLine(Offset(cx, cy), Offset(ex, ey), paint);

      // Small branches
      final mr = r * 0.5;
      final mx = cx + math.cos(angle) * mr;
      final my = cy + math.sin(angle) * mr;
      final branchAngle1 = angle + 0.5;
      final branchAngle2 = angle - 0.5;
      final br = r * 0.25;
      c.drawLine(Offset(mx, my),
          Offset(mx + math.cos(branchAngle1) * br, my + math.sin(branchAngle1) * br),
          paint..strokeWidth = 1.2);
      c.drawLine(Offset(mx, my),
          Offset(mx + math.cos(branchAngle2) * br, my + math.sin(branchAngle2) * br),
          paint..strokeWidth = 1.2);
    }

    // Center dot
    c.drawCircle(Offset(cx, cy), 2, Paint()..color = Colors.white);
  }

  // -- STEAM: Rising wispy cloud --
  void _drawSteam(Canvas c, double w, double h, double cx, double cy) {
    final rise = _pulse(0.6) * 4;
    final alpha = 0.3 + _pulse(0.8) * 0.15;
    final paint = Paint()
      ..color = baseColor.withValues(alpha: alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    c.drawCircle(Offset(cx - w * 0.1, h * 0.6 - rise), w * 0.15, paint);
    c.drawCircle(Offset(cx + w * 0.08, h * 0.45 - rise), w * 0.18, paint);
    c.drawCircle(Offset(cx - w * 0.05, h * 0.32 - rise), w * 0.14, paint);
    c.drawCircle(Offset(cx + w * 0.12, h * 0.22 - rise), w * 0.1, paint);
  }

  // -- SMOKE: Dark wisps --
  void _drawSmoke(Canvas c, double w, double h, double cx, double cy) {
    final rise = _pulse(0.5) * 3;
    final alpha = 0.35 + _pulse(0.6) * 0.15;
    final paint = Paint()
      ..color = baseColor.withValues(alpha: alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    c.drawCircle(Offset(cx, h * 0.65 - rise), w * 0.16, paint);
    c.drawCircle(Offset(cx - w * 0.1, h * 0.48 - rise), w * 0.14, paint);
    c.drawCircle(Offset(cx + w * 0.08, h * 0.35 - rise), w * 0.12, paint);
    c.drawCircle(Offset(cx, h * 0.22 - rise), w * 0.09, paint);
  }

  // -- TNT: Red stick with fuse --
  void _drawTnt(Canvas c, double w, double h, double cx, double cy) {
    // Red cylinder
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + h * 0.05), width: w * 0.5, height: h * 0.55),
      const Radius.circular(4),
    );
    c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_light(0.2), baseColor, _dark(0.2)],
          ).createShader(rr.outerRect));

    // Dark bands
    final band = Paint()
      ..color = _dark(0.4).withValues(alpha: 0.6)
      ..strokeWidth = 2.0;
    c.drawLine(Offset(w * 0.25, cy - h * 0.05), Offset(w * 0.75, cy - h * 0.05), band);
    c.drawLine(Offset(w * 0.25, cy + h * 0.1), Offset(w * 0.75, cy + h * 0.1), band);

    // Fuse
    final fuse = Paint()
      ..color = const Color(0xFF887755)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(cx, cy - h * 0.22), Offset(cx + w * 0.1, h * 0.12), fuse);

    // Spark
    if (_pulse(2.5) > 0.4) {
      c.drawCircle(
          Offset(cx + w * 0.1, h * 0.1),
          3,
          Paint()
            ..color = const Color(0xFFFFFF88)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    }
  }

  // -- RAINBOW: Gradient arc --
  void _drawRainbow(Canvas c, double w, double h, double cx, double cy) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;

    final colors = [
      const Color(0xFFFF0000),
      const Color(0xFFFF8800),
      const Color(0xFFFFFF00),
      const Color(0xFF00CC00),
      const Color(0xFF0088FF),
      const Color(0xFF8800FF),
    ];

    for (var i = 0; i < colors.length; i++) {
      final r = w * 0.38 - i * 2.5;
      paint.color = colors[(i + (phase * 6).floor()) % colors.length];
      c.drawArc(
        Rect.fromCircle(center: Offset(cx, h * 0.7), radius: r),
        math.pi, math.pi, false, paint,
      );
    }
  }

  // -- SEED: Small oval on soil --
  void _drawSeed(Canvas c, double w, double h, double cx, double cy) {
    // Soil base
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, h * 0.72), width: w * 0.6, height: h * 0.2),
      Paint()..color = const Color(0xFF3A2818),
    );

    // Seed body
    final breathe = _pulse(0.4) * 2;
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx, cy - breathe),
          width: w * 0.3,
          height: h * 0.4),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [_light(0.2), baseColor, _dark(0.2)],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // Tiny sprout hint
    if (_pulse(0.3) > 0.3) {
      final sprout = Paint()
        ..color = const Color(0xFF40A040)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      c.drawLine(Offset(cx, cy - h * 0.15 - breathe),
          Offset(cx + 2, cy - h * 0.25 - breathe), sprout);
    }
  }

  // -- BUBBLE: Iridescent sphere --
  void _drawBubble(Canvas c, double w, double h, double cx, double cy) {
    final r = w * 0.34;
    // Transparent fill
    c.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = baseColor.withValues(alpha: 0.15));

    // Edge ring
    c.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = baseColor.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // Highlight
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.1, cy - h * 0.1),
          width: w * 0.15,
          height: h * 0.1),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // Rainbow sheen
    final iri = HSVColor.fromAHSV(0.2, _pulse(0.6) * 360, 0.5, 0.9).toColor();
    c.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r - 1),
      -0.5, 1.5, false,
      Paint()
        ..color = iri
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  // -- ASH: Floating light flakes --
  void _drawAsh(Canvas c, double w, double h, double cx, double cy) {
    final drift = _wave(0.4) * 3;
    final paint = Paint()..color = baseColor.withValues(alpha: 0.6);

    final flakes = [
      Offset(cx - w * 0.15, h * 0.3 + drift),
      Offset(cx + w * 0.1, h * 0.45 - drift * 0.5),
      Offset(cx, h * 0.55 + drift * 0.3),
      Offset(cx + w * 0.2, h * 0.25 + drift * 0.7),
      Offset(cx - w * 0.08, h * 0.65 - drift * 0.2),
    ];
    for (final f in flakes) {
      c.drawCircle(f, 2.0, paint);
    }
  }

  // -- ANT: Simple side-view ant --
  void _drawAnt(Canvas c, double w, double h, double cx, double cy) {
    final bodyPaint = Paint()..color = const Color(0xFF2A2218);

    // Abdomen
    c.drawOval(
      Rect.fromCenter(center: Offset(cx - w * 0.12, cy), width: w * 0.28, height: h * 0.3),
      bodyPaint,
    );
    // Thorax
    c.drawOval(
      Rect.fromCenter(center: Offset(cx + w * 0.08, cy), width: w * 0.18, height: h * 0.2),
      bodyPaint,
    );
    // Head
    c.drawCircle(Offset(cx + w * 0.25, cy - h * 0.02), w * 0.1, bodyPaint);

    // Eye
    c.drawCircle(Offset(cx + w * 0.28, cy - h * 0.04), 1.2, Paint()..color = Colors.white);

    // Legs
    final legPaint = Paint()
      ..color = const Color(0xFF3A3228)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final legWalk = _wave(2.0) * 2;
    c.drawLine(Offset(cx - w * 0.05, cy + h * 0.12),
        Offset(cx - w * 0.12, cy + h * 0.28 + legWalk), legPaint);
    c.drawLine(Offset(cx + w * 0.05, cy + h * 0.08),
        Offset(cx + w * 0.12, cy + h * 0.26 - legWalk), legPaint);
    c.drawLine(Offset(cx + w * 0.15, cy + h * 0.08),
        Offset(cx + w * 0.22, cy + h * 0.24 + legWalk), legPaint);

    // Antennae
    c.drawLine(Offset(cx + w * 0.3, cy - h * 0.08),
        Offset(cx + w * 0.38, cy - h * 0.22), legPaint);
    c.drawLine(Offset(cx + w * 0.3, cy - h * 0.05),
        Offset(cx + w * 0.4, cy - h * 0.15), legPaint);
  }

  // -- HONEY: Golden drip --
  void _drawHoney(Canvas c, double w, double h, double cx, double cy) {
    // Thick drop
    final path = Path();
    path.moveTo(cx, h * 0.15);
    path.cubicTo(cx + w * 0.32, h * 0.3, cx + w * 0.3, h * 0.65,
        cx, h * 0.82);
    path.cubicTo(cx - w * 0.3, h * 0.65, cx - w * 0.32, h * 0.3,
        cx, h * 0.15);

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.2, -0.3),
            colors: [_light(0.35), baseColor, _dark(0.15)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Golden highlight
    c.drawOval(
      Rect.fromCenter(
          center: Offset(cx - w * 0.08, h * 0.32),
          width: w * 0.12,
          height: h * 0.1),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  // -- FUNGUS: Mushroom cap --
  void _drawFungus(Canvas c, double w, double h, double cx, double cy) {
    // Stem
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, h * 0.68), width: w * 0.15, height: h * 0.3),
        const Radius.circular(3),
      ),
      Paint()..color = _light(0.2),
    );

    // Cap
    final cap = Path();
    cap.moveTo(cx - w * 0.35, h * 0.55);
    cap.cubicTo(cx - w * 0.35, h * 0.2, cx + w * 0.35, h * 0.2,
        cx + w * 0.35, h * 0.55);
    cap.close();

    c.drawPath(
        cap,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.5),
            colors: [_light(0.15), baseColor, _dark(0.2)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));
  }

  // -- GAS: Faint wispy circles --
  void _drawGas(Canvas c, double w, double h, double cx, double cy) {
    final drift = _wave(0.5) * 3;
    final paint = Paint()
      ..color = baseColor.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    c.drawCircle(Offset(cx - w * 0.08, cy + drift), w * 0.2, paint);
    c.drawCircle(Offset(cx + w * 0.1, cy - drift * 0.5), w * 0.15, paint);
    c.drawCircle(Offset(cx, cy - h * 0.15 + drift * 0.3), w * 0.12, paint);
  }

  // -- SPORE: Drifting dots --
  void _drawSpore(Canvas c, double w, double h, double cx, double cy) {
    final drift = _wave(0.5) * 4;
    final paint = Paint()..color = baseColor.withValues(alpha: 0.65);
    final positions = [
      Offset(cx, h * 0.35 + drift),
      Offset(cx - w * 0.2, h * 0.5 - drift * 0.3),
      Offset(cx + w * 0.15, h * 0.45 + drift * 0.5),
      Offset(cx - w * 0.08, h * 0.62 - drift * 0.2),
      Offset(cx + w * 0.22, h * 0.58 + drift * 0.4),
    ];
    for (var i = 0; i < positions.length; i++) {
      c.drawCircle(positions[i], 2.5 - i * 0.3, paint);
    }
  }

  // -- ALGAE: Wavy green strand --
  void _drawAlgae(Canvas c, double w, double h, double cx, double cy) {
    final sway = _wave(0.6) * 4;
    final paint = Paint()
      ..color = baseColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(cx, h * 0.85);
    path.cubicTo(cx + sway, h * 0.65, cx - sway, h * 0.45, cx + sway * 0.5, h * 0.15);
    c.drawPath(path, paint);

    // Second strand
    path.reset();
    path.moveTo(cx - w * 0.12, h * 0.85);
    path.cubicTo(cx - w * 0.12 - sway * 0.7, h * 0.6,
        cx - w * 0.12 + sway * 0.5, h * 0.4,
        cx - w * 0.12 - sway * 0.3, h * 0.2);
    c.drawPath(path, paint..color = _dark(0.15));
  }

  // -- WEB: Radial web pattern --
  void _drawWeb(Canvas c, double w, double h, double cx, double cy) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // Radial threads
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final r = w * 0.4;
      c.drawLine(Offset(cx, cy),
          Offset(cx + math.cos(angle) * r, cy + math.sin(angle) * r), paint);
    }

    // Concentric rings
    for (var r = w * 0.1; r < w * 0.4; r += w * 0.1) {
      c.drawCircle(Offset(cx, cy), r, paint);
    }

    // Dewdrop
    c.drawCircle(
        Offset(cx + w * 0.15, cy - h * 0.15),
        2,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5 + _pulse(1.0) * 0.3));
  }

  // -- SALT: White cubic crystal --
  void _drawSalt(Canvas c, double w, double h, double cx, double cy) {
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 0.45, height: h * 0.45),
      const Radius.circular(2),
    );
    c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: const Alignment(-1, -1),
            end: const Alignment(1, 1),
            colors: [Colors.white, baseColor, _dark(0.05)],
          ).createShader(rr.outerRect));

    // Sparkle
    c.drawCircle(
        Offset(cx - w * 0.08, cy - h * 0.08),
        1.5,
        Paint()..color = Colors.white.withValues(alpha: 0.6 + _pulse(1.5) * 0.3));
  }

  // -- SULFUR: Yellow crystals --
  void _drawSulfur(Canvas c, double w, double h, double cx, double cy) {
    // Angular crystal cluster
    final path = Path();
    path.moveTo(cx - w * 0.15, h * 0.75);
    path.lineTo(cx - w * 0.2, h * 0.35);
    path.lineTo(cx - w * 0.05, h * 0.2);
    path.lineTo(cx + w * 0.05, h * 0.35);
    path.lineTo(cx + w * 0.15, h * 0.15);
    path.lineTo(cx + w * 0.25, h * 0.4);
    path.lineTo(cx + w * 0.15, h * 0.75);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_light(0.3), baseColor, _dark(0.15)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));
  }

  // -- CLAY: Rounded terracotta lump --
  void _drawClay(Canvas c, double w, double h, double cx, double cy) {
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + h * 0.05), width: w * 0.6, height: h * 0.5),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.2, -0.4),
          colors: [_light(0.15), baseColor, _dark(0.15)],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );
  }

  // -- CHARCOAL: Dark angular chunk --
  void _drawCharcoal(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(cx - w * 0.2, h * 0.3);
    path.lineTo(cx + w * 0.25, h * 0.25);
    path.lineTo(cx + w * 0.3, h * 0.6);
    path.lineTo(cx + w * 0.1, h * 0.75);
    path.lineTo(cx - w * 0.25, h * 0.7);
    path.close();

    c.drawPath(path, Paint()..color = baseColor);

    // Faint ember glow
    if (_pulse(0.8) > 0.5) {
      c.drawCircle(
          Offset(cx + w * 0.05, cy + h * 0.05),
          3,
          Paint()
            ..color = const Color(0x40FF4400)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    }
  }

  // -- COMPOST: Dark heap --
  void _drawCompost(Canvas c, double w, double h, double cx, double cy) {
    final path = Path();
    path.moveTo(w * 0.15, h * 0.75);
    path.cubicTo(w * 0.2, h * 0.4, w * 0.4, h * 0.28, cx, h * 0.25);
    path.cubicTo(w * 0.6, h * 0.28, w * 0.8, h * 0.4, w * 0.85, h * 0.75);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.3),
            colors: [_light(0.1), baseColor, _dark(0.15)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Organic specks
    c.drawCircle(Offset(cx - w * 0.1, h * 0.5), 1.5,
        Paint()..color = const Color(0xFF556030));
  }

  // -- RUST: Flaky orange-brown patch --
  void _drawRust(Canvas c, double w, double h, double cx, double cy) {
    // Irregular shape
    final path = Path();
    path.moveTo(cx - w * 0.25, h * 0.35);
    path.cubicTo(cx - w * 0.1, h * 0.2, cx + w * 0.15, h * 0.22,
        cx + w * 0.3, h * 0.35);
    path.cubicTo(cx + w * 0.35, h * 0.5, cx + w * 0.25, h * 0.7,
        cx + w * 0.1, h * 0.75);
    path.cubicTo(cx - w * 0.1, h * 0.78, cx - w * 0.3, h * 0.65,
        cx - w * 0.3, h * 0.5);
    path.close();

    c.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            colors: [_light(0.15), baseColor, _dark(0.2)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Pitting
    c.drawCircle(Offset(cx + w * 0.05, cy - h * 0.05), 2,
        Paint()..color = _dark(0.3).withValues(alpha: 0.5));
  }

  // -- ERASER: Checkerboard with X --
  void _drawEraser(Canvas c, double w, double h, double cx, double cy) {
    // Checkerboard background
    final cellSize = w / 4;
    for (var r = 0; r < 4; r++) {
      for (var col = 0; col < 4; col++) {
        final isDark = (r + col) % 2 == 0;
        c.drawRect(
          Rect.fromLTWH(col * cellSize + w * 0.1, r * cellSize + h * 0.1,
              cellSize * 0.8, cellSize * 0.8),
          Paint()
            ..color = isDark
                ? const Color(0xFF3A3A55)
                : const Color(0xFF4A4A70),
        );
      }
    }

    // X mark
    final xPaint = Paint()
      ..color = const Color(0xFFFF4646)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(w * 0.25, h * 0.25), Offset(w * 0.75, h * 0.75), xPaint);
    c.drawLine(Offset(w * 0.75, h * 0.25), Offset(w * 0.25, h * 0.75), xPaint);
  }

  // -- NEURAL PLANTS --

  void _drawSeaweed(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      final xOff = (i - 1) * w * 0.14;
      final path = Path()..moveTo(cx + xOff, h * 0.85);
      for (double t = 0.85; t > 0.2; t -= 0.05) {
        path.lineTo(cx + xOff + math.sin(t * 8 + i) * w * 0.08, h * t);
      }
      p.color = Color.lerp(baseColor, _dark(0.2), i * 0.15)!;
      c.drawPath(path, p);
    }
  }

  void _drawMoss(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..style = PaintingStyle.fill;
    // Fuzzy cluster of tiny dots on a surface
    final base = Paint()..color = _dark(0.3)..style = PaintingStyle.fill;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.15, h * 0.65, w * 0.7, h * 0.2), Radius.circular(w * 0.06)), base);
    for (int i = 0; i < 12; i++) {
      final fx = w * 0.2 + (i % 4) * w * 0.18 + (i * 7 % 5) * w * 0.02;
      final fy = h * 0.45 + (i ~/ 4) * h * 0.1 + (i * 3 % 5) * h * 0.02;
      p.color = Color.lerp(baseColor, _light(0.2), (i % 3) * 0.15)!;
      c.drawCircle(Offset(fx, fy), w * 0.05 + (i % 3) * w * 0.01, p);
    }
  }

  void _drawVine(Canvas c, double w, double h, double cx, double cy) {
    final stem = Paint()..color = _dark(0.1)..style = PaintingStyle.stroke..strokeWidth = 2.0..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(w * 0.3, h * 0.85);
    path.cubicTo(w * 0.25, h * 0.5, w * 0.7, h * 0.45, w * 0.65, h * 0.15);
    c.drawPath(path, stem);
    // Small leaves along the vine
    final leaf = Paint()..color = baseColor..style = PaintingStyle.fill;
    for (int i = 0; i < 3; i++) {
      final t = 0.3 + i * 0.25;
      final lx = w * 0.3 + (w * 0.35) * t + math.sin(t * 5) * w * 0.1;
      final ly = h * 0.85 - h * 0.7 * t;
      c.save();
      c.translate(lx, ly);
      c.rotate(0.3 + i * 0.4);
      c.drawOval(Rect.fromCenter(center: Offset.zero, width: w * 0.12, height: w * 0.06), leaf);
      c.restore();
    }
  }

  void _drawFlower(Canvas c, double w, double h, double cx, double cy) {
    // Stem
    c.drawLine(Offset(cx, h * 0.9), Offset(cx, h * 0.45), Paint()..color = _dark(0.2)..strokeWidth = 2.0..strokeCap = StrokeCap.round);
    // Petals
    final petal = Paint()..color = baseColor..style = PaintingStyle.fill;
    for (int i = 0; i < 5; i++) {
      final angle = i * math.pi * 2 / 5 - math.pi / 2;
      final px = cx + math.cos(angle) * w * 0.15;
      final py = h * 0.35 + math.sin(angle) * w * 0.15;
      c.drawOval(Rect.fromCenter(center: Offset(px, py), width: w * 0.14, height: w * 0.1), petal);
    }
    // Center
    c.drawCircle(Offset(cx, h * 0.35), w * 0.06, Paint()..color = _light(0.3));
  }

  void _drawRoot(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..color = baseColor..style = PaintingStyle.stroke..strokeWidth = 2.2..strokeCap = StrokeCap.round;
    // Main root going down
    final main = Path()..moveTo(cx, h * 0.15)..lineTo(cx, h * 0.85);
    c.drawPath(main, p);
    // Branches
    p.strokeWidth = 1.5;
    p.color = _dark(0.1);
    c.drawLine(Offset(cx, h * 0.4), Offset(w * 0.25, h * 0.6), p);
    c.drawLine(Offset(cx, h * 0.5), Offset(w * 0.75, h * 0.72), p);
    c.drawLine(Offset(cx, h * 0.65), Offset(w * 0.3, h * 0.82), p);
  }

  void _drawThorn(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..color = baseColor..style = PaintingStyle.fill;
    // Sharp triangle
    final path = Path()
      ..moveTo(cx, h * 0.15)
      ..lineTo(w * 0.65, h * 0.85)
      ..lineTo(w * 0.35, h * 0.85)
      ..close();
    c.drawPath(path, p);
    // Highlight edge
    final edge = Paint()..color = _light(0.4)..style = PaintingStyle.stroke..strokeWidth = 1.0;
    c.drawLine(Offset(cx, h * 0.15), Offset(w * 0.65, h * 0.85), edge);
  }

  // -- EXPLOSIVES & RADIOACTIVES --

  void _drawC4(Canvas c, double w, double h, double cx, double cy) {
    // Block of putty
    final block = Paint()..color = baseColor..style = PaintingStyle.fill;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.55, height: h * 0.35), Radius.circular(w * 0.04)), block);
    // Detonator wire
    final wire = Paint()..color = _dark(0.3)..strokeWidth = 1.5..style = PaintingStyle.stroke;
    c.drawLine(Offset(cx, cy - h * 0.175), Offset(cx, h * 0.15), wire);
    c.drawCircle(Offset(cx, h * 0.15), w * 0.04, Paint()..color = const Color(0xFFFF4444));
  }

  void _drawUranium(Canvas c, double w, double h, double cx, double cy) {
    // Radioactive trefoil
    final p = Paint()..color = baseColor..style = PaintingStyle.fill;
    c.drawCircle(Offset(cx, cy), w * 0.08, Paint()..color = _dark(0.2));
    for (int i = 0; i < 3; i++) {
      final angle = i * math.pi * 2 / 3 - math.pi / 2;
      final path = Path();
      path.moveTo(cx, cy);
      path.arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: w * 0.32),
        angle - 0.4, 0.8, false,
      );
      path.close();
      c.drawPath(path, p);
    }
  }

  void _drawLeadElement(Canvas c, double w, double h, double cx, double cy) {
    // Heavy dark block
    final p = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [_light(0.15), baseColor, _dark(0.3)],
      ).createShader(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.6, height: h * 0.5));
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.55, height: h * 0.45), Radius.circular(w * 0.06)), p);
  }

  // -- ATMOSPHERICS --

  void _drawVapor(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      p.color = baseColor.withValues(alpha: 0.5 - i * 0.1);
      final path = Path()..moveTo(w * (0.25 + i * 0.12), h * 0.8);
      path.cubicTo(w * (0.2 + i * 0.12), h * 0.55, w * (0.4 + i * 0.1), h * 0.4, w * (0.35 + i * 0.12), h * 0.2);
      c.drawPath(path, p);
    }
  }

  void _drawCloud(Canvas c, double w, double h, double cx, double cy) {
    final p = Paint()..color = baseColor..style = PaintingStyle.fill;
    c.drawCircle(Offset(cx - w * 0.1, cy), w * 0.18, p);
    c.drawCircle(Offset(cx + w * 0.12, cy - h * 0.02), w * 0.15, p);
    c.drawCircle(Offset(cx, cy - h * 0.1), w * 0.2, p);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.2, cy, w * 0.6, h * 0.12), Radius.circular(w * 0.06)), p);
  }

  // -- NOTABLE METALS --

  void _drawGoldElement(Canvas c, double w, double h, double cx, double cy) {
    // Gold bar / ingot shape
    final p = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [const Color(0xFFFFF0A0), baseColor, const Color(0xFFB8860B)],
      ).createShader(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.6, height: h * 0.4));
    final path = Path()
      ..moveTo(w * 0.3, h * 0.65)..lineTo(w * 0.25, h * 0.4)
      ..lineTo(w * 0.75, h * 0.4)..lineTo(w * 0.7, h * 0.65)..close();
    c.drawPath(path, p);
    // Top face
    final top = Paint()..color = _light(0.3);
    final topPath = Path()
      ..moveTo(w * 0.25, h * 0.4)..lineTo(w * 0.32, h * 0.32)
      ..lineTo(w * 0.78, h * 0.32)..lineTo(w * 0.75, h * 0.4)..close();
    c.drawPath(topPath, top);
  }

  void _drawSilverElement(Canvas c, double w, double h, double cx, double cy) {
    // Polished coin
    final p = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.2, -0.2),
        colors: [const Color(0xFFE8E8F0), baseColor, const Color(0xFF808090)],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: w * 0.28));
    c.drawCircle(Offset(cx, cy), w * 0.28, p);
    c.drawCircle(Offset(cx, cy), w * 0.22, Paint()..color = Colors.white.withValues(alpha: 0.15)..style = PaintingStyle.stroke..strokeWidth = 1.0);
  }

  void _drawPlatinumElement(Canvas c, double w, double h, double cx, double cy) {
    // Rounded bar with bright sheen
    final r = Rect.fromCenter(center: Offset(cx, cy), width: w * 0.55, height: h * 0.3);
    c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(w * 0.05)),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [_light(0.4), baseColor, _dark(0.15)]).createShader(r));
    // Sheen line
    c.drawLine(Offset(w * 0.3, cy - h * 0.08), Offset(w * 0.7, cy - h * 0.08),
      Paint()..color = Colors.white.withValues(alpha: 0.3)..strokeWidth = 1.0..strokeCap = StrokeCap.round);
  }

  void _drawMercury(Canvas c, double w, double h, double cx, double cy) {
    // Liquid metal droplets
    final p = Paint()
      ..shader = RadialGradient(center: const Alignment(-0.3, -0.3),
        colors: [_light(0.5), baseColor, _dark(0.2)],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy + h * 0.05), radius: w * 0.22));
    c.drawCircle(Offset(cx, cy + h * 0.05), w * 0.22, p);
    c.drawCircle(Offset(cx - w * 0.2, cy + h * 0.15), w * 0.08, Paint()..color = _dark(0.1));
    c.drawCircle(Offset(cx + w * 0.22, cy + h * 0.12), w * 0.06, Paint()..color = _dark(0.05));
  }

  void _drawTitanium(Canvas c, double w, double h, double cx, double cy) {
    // Sleek angular plate
    final path = Path()
      ..moveTo(w * 0.2, h * 0.7)..lineTo(w * 0.35, h * 0.25)
      ..lineTo(w * 0.8, h * 0.3)..lineTo(w * 0.65, h * 0.75)..close();
    c.drawPath(path, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [_light(0.3), baseColor, _dark(0.2)]).createShader(Rect.fromLTWH(w * 0.2, h * 0.25, w * 0.6, h * 0.5)));
  }

  void _drawAluminum(Canvas c, double w, double h, double cx, double cy) {
    // Thin crinkled foil
    final p = Paint()..color = baseColor..style = PaintingStyle.fill;
    final path = Path()..moveTo(w * 0.2, h * 0.4);
    path.lineTo(w * 0.35, h * 0.35);
    path.lineTo(w * 0.5, h * 0.42);
    path.lineTo(w * 0.65, h * 0.33);
    path.lineTo(w * 0.8, h * 0.4);
    path.lineTo(w * 0.75, h * 0.65);
    path.lineTo(w * 0.25, h * 0.65);
    path.close();
    c.drawPath(path, p);
    c.drawPath(path, Paint()..color = _light(0.2)..style = PaintingStyle.stroke..strokeWidth = 0.8);
  }

  void _drawSilicon(Canvas c, double w, double h, double cx, double cy) {
    // Wafer / chip
    final r = Rect.fromCenter(center: Offset(cx, cy), width: w * 0.52, height: h * 0.52);
    c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(w * 0.03)),
      Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [_light(0.15), baseColor, _dark(0.25)]).createShader(r));
    // Grid lines (circuit traces)
    final line = Paint()..color = _light(0.15)..strokeWidth = 0.6;
    for (int i = 1; i < 4; i++) {
      final t = i / 4;
      c.drawLine(Offset(r.left + r.width * t, r.top), Offset(r.left + r.width * t, r.bottom), line);
      c.drawLine(Offset(r.left, r.top + r.height * t), Offset(r.right, r.top + r.height * t), line);
    }
  }

  void _drawDiamond(Canvas c, double w, double h, double cx, double cy) {
    // Brilliant-cut diamond shape
    final path = Path()
      ..moveTo(cx, h * 0.15)
      ..lineTo(w * 0.75, h * 0.4)..lineTo(cx, h * 0.85)..lineTo(w * 0.25, h * 0.4)..close();
    c.drawPath(path, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [_light(0.5), baseColor, _light(0.2)]).createShader(Rect.fromLTWH(w * 0.25, h * 0.15, w * 0.5, h * 0.7)));
    // Facet lines
    final facet = Paint()..color = _light(0.3)..strokeWidth = 0.7..style = PaintingStyle.stroke;
    c.drawLine(Offset(cx, h * 0.15), Offset(cx, h * 0.85), facet);
    c.drawLine(Offset(w * 0.25, h * 0.4), Offset(w * 0.75, h * 0.4), facet);
  }

  // -- FAMILY-BASED PERIODIC TABLE ICONS --

  void _drawNobleGas(Canvas c, double w, double h, double cx, double cy) {
    // Glowing concentric rings (inert/stable)
    for (int i = 3; i > 0; i--) {
      c.drawCircle(Offset(cx, cy), w * 0.1 * i,
        Paint()..color = baseColor.withValues(alpha: 0.15 + (3 - i) * 0.1)..style = PaintingStyle.stroke..strokeWidth = 1.2);
    }
    c.drawCircle(Offset(cx, cy), w * 0.06, Paint()..color = baseColor.withValues(alpha: 0.6));
  }

  void _drawAlkaliMetal(Canvas c, double w, double h, double cx, double cy) {
    // Soft rounded cube with reactive glow
    final r = Rect.fromCenter(center: Offset(cx, cy), width: w * 0.48, height: h * 0.48);
    c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(w * 0.1)),
      Paint()..shader = RadialGradient(center: const Alignment(-0.2, -0.2),
        colors: [_light(0.4), baseColor, _dark(0.2)]).createShader(r));
    // Reactive spark
    final spark = Paint()..color = _light(0.6)..strokeWidth = 1.5..strokeCap = StrokeCap.round;
    c.drawLine(Offset(w * 0.7, h * 0.2), Offset(w * 0.78, h * 0.14), spark);
    c.drawLine(Offset(w * 0.72, h * 0.18), Offset(w * 0.82, h * 0.2), spark);
  }

  void _drawAlkalineEarth(Canvas c, double w, double h, double cx, double cy) {
    // Two stacked rounded bars (pair of valence electrons)
    final p = Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [_light(0.2), baseColor, _dark(0.15)]).createShader(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.5, height: h * 0.5));
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.25, h * 0.28, w * 0.5, h * 0.18), Radius.circular(w * 0.04)), p);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.25, h * 0.54, w * 0.5, h * 0.18), Radius.circular(w * 0.04)), p);
  }

  void _drawTransitionMetal(Canvas c, double w, double h, double cx, double cy) {
    // Metallic hexagon (crystalline structure)
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = i * math.pi / 3 - math.pi / 2;
      final px = cx + math.cos(angle) * w * 0.3;
      final py = cy + math.sin(angle) * w * 0.3;
      if (i == 0) { path.moveTo(px, py); } else { path.lineTo(px, py); }
    }
    path.close();
    c.drawPath(path, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [_light(0.3), baseColor, _dark(0.2)]).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: w * 0.3)));
    c.drawPath(path, Paint()..color = _light(0.15)..style = PaintingStyle.stroke..strokeWidth = 0.8);
  }

  void _drawPostTransition(Canvas c, double w, double h, double cx, double cy) {
    // Rounded rectangle with soft edges (softer metals)
    final r = Rect.fromCenter(center: Offset(cx, cy), width: w * 0.5, height: h * 0.42);
    c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(w * 0.08)),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [_light(0.2), baseColor, _dark(0.15)]).createShader(r));
  }

  void _drawMetalloid(Canvas c, double w, double h, double cx, double cy) {
    // Half metal, half nonmetal — split diamond
    final left = Path()..moveTo(cx, h * 0.2)..lineTo(w * 0.25, cy)..lineTo(cx, h * 0.8)..close();
    final right = Path()..moveTo(cx, h * 0.2)..lineTo(w * 0.75, cy)..lineTo(cx, h * 0.8)..close();
    c.drawPath(left, Paint()..color = _light(0.2));
    c.drawPath(right, Paint()..color = _dark(0.15));
    c.drawPath(Path()..moveTo(cx, h * 0.2)..lineTo(w * 0.75, cy)..lineTo(cx, h * 0.8)..lineTo(w * 0.25, cy)..close(),
      Paint()..color = baseColor.withValues(alpha: 0.3)..style = PaintingStyle.stroke..strokeWidth = 0.8);
  }

  void _drawNonmetal(Canvas c, double w, double h, double cx, double cy) {
    // Organic cloud-like blob
    final p = Paint()..color = baseColor.withValues(alpha: 0.7)..style = PaintingStyle.fill;
    c.drawCircle(Offset(cx - w * 0.06, cy - h * 0.04), w * 0.18, p);
    c.drawCircle(Offset(cx + w * 0.08, cy + h * 0.02), w * 0.15, p);
    c.drawCircle(Offset(cx - w * 0.02, cy + h * 0.08), w * 0.13, p);
  }

  void _drawHalogen(Canvas c, double w, double h, double cx, double cy) {
    // Diatomic pair (two bonded atoms)
    final p = Paint()..shader = RadialGradient(center: const Alignment(-0.3, -0.3),
      colors: [_light(0.3), baseColor, _dark(0.2)]).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: w * 0.35));
    c.drawCircle(Offset(cx - w * 0.1, cy), w * 0.18, p);
    c.drawCircle(Offset(cx + w * 0.1, cy), w * 0.18, p);
    // Bond line
    c.drawLine(Offset(cx - w * 0.05, cy), Offset(cx + w * 0.05, cy),
      Paint()..color = _light(0.15)..strokeWidth = 1.5..strokeCap = StrokeCap.round);
  }

  void _drawLanthanide(Canvas c, double w, double h, double cx, double cy) {
    // Layered orbital rings (f-block electrons)
    final ring = Paint()..color = baseColor..style = PaintingStyle.stroke..strokeWidth = 1.2;
    c.drawCircle(Offset(cx, cy), w * 0.08, Paint()..color = baseColor);
    c.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.55, height: h * 0.25), ring);
    c.save();
    c.translate(cx, cy);
    c.rotate(math.pi / 3);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: w * 0.55, height: h * 0.25), ring);
    c.restore();
  }

  void _drawActinide(Canvas c, double w, double h, double cx, double cy) {
    // Radioactive orbital rings (like lanthanide but with warning dot)
    final ring = Paint()..color = baseColor..style = PaintingStyle.stroke..strokeWidth = 1.2;
    c.drawCircle(Offset(cx, cy), w * 0.08, Paint()..color = baseColor);
    c.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: w * 0.55, height: h * 0.25), ring);
    c.save();
    c.translate(cx, cy);
    c.rotate(-math.pi / 3);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: w * 0.55, height: h * 0.25), ring);
    c.restore();
    // Warning dot
    c.drawCircle(Offset(cx, cy), w * 0.04, Paint()..color = const Color(0xFFFF6644));
  }

  void _drawSuperheavy(Canvas c, double w, double h, double cx, double cy) {
    // Unstable atom — jittered rings with decay sparks
    final ring = Paint()..color = baseColor.withValues(alpha: 0.6)..style = PaintingStyle.stroke..strokeWidth = 1.0;
    c.drawCircle(Offset(cx, cy), w * 0.07, Paint()..color = baseColor);
    c.drawCircle(Offset(cx, cy), w * 0.2, ring);
    c.drawCircle(Offset(cx, cy), w * 0.32, Paint()..color = baseColor.withValues(alpha: 0.3)..style = PaintingStyle.stroke..strokeWidth = 0.8);
    // Decay sparks
    final spark = Paint()..color = _light(0.5)..strokeWidth = 1.2..strokeCap = StrokeCap.round;
    for (int i = 0; i < 4; i++) {
      final angle = i * math.pi / 2 + 0.3;
      final r1 = w * 0.28;
      final r2 = w * 0.38;
      c.drawLine(Offset(cx + math.cos(angle) * r1, cy + math.sin(angle) * r1),
        Offset(cx + math.cos(angle) * r2, cy + math.sin(angle) * r2), spark);
    }
  }

  // -- GENERIC: Colored circle with gradient --
  void _drawGeneric(Canvas c, double w, double h, double cx, double cy) {
    c.drawCircle(
        Offset(cx, cy),
        w * 0.32,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.3),
            colors: [_light(0.3), baseColor, _dark(0.2)],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: w * 0.32)));
  }

  @override
  bool shouldRepaint(covariant VectorElementIcon old) =>
      old.elId != elId || (old.phase - phase).abs() > 0.01;
}
