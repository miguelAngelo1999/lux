import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Ultra-fine (1.35px stroke) Lucide / SF-Symbols-inspired vector glyphs drawn
/// directly on Flutter's canvas so Lux keeps razor-sharp thin strokes across
/// Retina macOS and Windows HiDPI without adding external font packages.
enum LuxGlyph {
  proxies,
  rules,
  connections,
  logs,
  settings,
  shield,
  plus,
  radar,
  externalLink,
  bolt,
  key,
  person,
  lock,
  eye,
  eyeOff,
  moreHorizontal,
  chevronDown,
  chevronUp,
  check,
  wifiOff,
  wifiLock,
  alertCircle,
  power,
  arrowUp,
  arrowDown,
  route,
  globe,
  home,
  swap,
  shieldAlert,
  sun,
  moon,
  refresh,
  download,
  search,
  trash,
  copy,
  close,
  pause,
  play,
  edit,
  upload,
  chevronRight,
  xCircle,
}

class LuxIcon extends StatelessWidget {
  final LuxGlyph glyph;
  final double size;
  final Color? color;
  final double strokeWidth;

  const LuxIcon(
    this.glyph, {
    super.key,
    this.size = 16,
    this.color,
    this.strokeWidth = 1.35,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _LuxGlyphPainter(
            glyph: glyph,
            color: resolvedColor,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

/// Authentic Lux brand mark: uses the bundled `assets/logo.png` icon (dark
/// slate rounded square with teal X), with a matching vector fallback for
/// headless tests.
class LuxLogoMark extends StatelessWidget {
  final double size;
  final Color? color;

  const LuxLogoMark({super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _LuxLogoFallbackPainter()),
        ),
      ),
    );
  }
}

class _LuxLogoFallbackPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final bg = Paint()..color = const Color(0xFF232736);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(5.5 * s),
      ),
      bg,
    );
    final xPaint = Paint()
      ..color = const Color(0xFF56B4C4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * s
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(6.8 * s, 6.8 * s), Offset(17.2 * s, 17.2 * s), xPaint);
    canvas.drawLine(Offset(17.2 * s, 6.8 * s), Offset(6.8 * s, 17.2 * s), xPaint);
  }

  @override
  bool shouldRepaint(covariant _LuxLogoFallbackPainter old) => false;
}

class _LuxGlyphPainter extends CustomPainter {
  final LuxGlyph glyph;
  final Color color;
  final double strokeWidth;

  _LuxGlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    Offset pt(double x, double y) => Offset(x * s, y * s);
    Rect rect(double l, double t, double w, double h) =>
        Rect.fromLTWH(l * s, t * s, w * s, h * s);

    switch (glyph) {
      case LuxGlyph.proxies:
        // Stacked server/network layers (clean thin diamond stack)
        final top = Path()
          ..moveTo(12 * s, 3.5 * s)
          ..lineTo(20.5 * s, 8 * s)
          ..lineTo(12 * s, 12.5 * s)
          ..lineTo(3.5 * s, 8 * s)
          ..close();
        canvas.drawPath(top, p);
        final mid = Path()
          ..moveTo(3.5 * s, 12.2 * s)
          ..lineTo(12 * s, 16.7 * s)
          ..lineTo(20.5 * s, 12.2 * s);
        canvas.drawPath(mid, p);
        final bot = Path()
          ..moveTo(3.5 * s, 16.2 * s)
          ..lineTo(12 * s, 20.7 * s)
          ..lineTo(20.5 * s, 16.2 * s);
        canvas.drawPath(bot, p);

      case LuxGlyph.rules:
        // Split routing branch
        canvas.drawCircle(pt(6, 6), 2.2 * s, p);
        canvas.drawCircle(pt(18, 6), 2.2 * s, p);
        canvas.drawCircle(pt(12, 18.5), 2.2 * s, p);
        final left = Path()
          ..moveTo(6 * s, 8.2 * s)
          ..cubicTo(6 * s, 12.5 * s, 12 * s, 12 * s, 12 * s, 16.3 * s);
        final right = Path()
          ..moveTo(18 * s, 8.2 * s)
          ..cubicTo(18 * s, 12.5 * s, 12 * s, 12 * s, 12 * s, 16.3 * s);
        canvas.drawPath(left, p);
        canvas.drawPath(right, p);

      case LuxGlyph.connections:
        // Diagonal / bidirectional activity arrows
        canvas.drawLine(pt(5, 8.5), pt(19, 8.5), p);
        final a1 = Path()
          ..moveTo(15.5 * s, 5 * s)
          ..lineTo(19 * s, 8.5 * s)
          ..lineTo(15.5 * s, 12 * s);
        canvas.drawPath(a1, p);
        canvas.drawLine(pt(19, 15.5), pt(5, 15.5), p);
        final a2 = Path()
          ..moveTo(8.5 * s, 12 * s)
          ..lineTo(5 * s, 15.5 * s)
          ..lineTo(8.5 * s, 19 * s);
        canvas.drawPath(a2, p);

      case LuxGlyph.logs:
        // Terminal >_
        final caret = Path()
          ..moveTo(5 * s, 7.5 * s)
          ..lineTo(10.5 * s, 12.5 * s)
          ..lineTo(5 * s, 17.5 * s);
        canvas.drawPath(caret, p);
        canvas.drawLine(pt(12.5, 17.5), pt(19.5, 17.5), p);

      case LuxGlyph.settings:
        // Clean horizontal sliders (3 lines + circles)
        canvas.drawLine(pt(4, 7), pt(9, 7), p);
        canvas.drawLine(pt(13, 7), pt(20, 7), p);
        canvas.drawCircle(pt(11, 7), 2 * s, p);
        canvas.drawLine(pt(4, 12), pt(14, 12), p);
        canvas.drawLine(pt(18, 12), pt(20, 12), p);
        canvas.drawCircle(pt(16, 12), 2 * s, p);
        canvas.drawLine(pt(4, 17), pt(7, 17), p);
        canvas.drawLine(pt(11, 17), pt(20, 17), p);
        canvas.drawCircle(pt(9, 17), 2 * s, p);

      case LuxGlyph.shield:
        final path = Path()
          ..moveTo(12 * s, 3.2 * s)
          ..lineTo(19.2 * s, 6.2 * s)
          ..lineTo(19.2 * s, 11.8 * s)
          ..cubicTo(19.2 * s, 16.4 * s, 15.8 * s, 19.6 * s, 12 * s, 21 * s)
          ..cubicTo(8.2 * s, 19.6 * s, 4.8 * s, 16.4 * s, 4.8 * s, 11.8 * s)
          ..lineTo(4.8 * s, 6.2 * s)
          ..close();
        canvas.drawPath(path, p);

      case LuxGlyph.shieldAlert:
        final path = Path()
          ..moveTo(12 * s, 3.2 * s)
          ..lineTo(19.2 * s, 6.2 * s)
          ..lineTo(19.2 * s, 11.8 * s)
          ..cubicTo(19.2 * s, 16.4 * s, 15.8 * s, 19.6 * s, 12 * s, 21 * s)
          ..cubicTo(8.2 * s, 19.6 * s, 4.8 * s, 16.4 * s, 4.8 * s, 11.8 * s)
          ..lineTo(4.8 * s, 6.2 * s)
          ..close();
        canvas.drawPath(path, p);
        canvas.drawLine(pt(12, 8.8), pt(12, 13.2), p);
        canvas.drawCircle(pt(12, 16.1), 0.8 * s, fill);

      case LuxGlyph.plus:
        canvas.drawLine(pt(12, 5.5), pt(12, 18.5), p);
        canvas.drawLine(pt(5.5, 12), pt(18.5, 12), p);

      case LuxGlyph.radar:
        // Concentric wifi/radio waves for Detect Proxy
        canvas.drawCircle(pt(12, 12), 1.6 * s, fill);
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12), radius: 5.2 * s),
          -math.pi * 0.72,
          math.pi * 0.44,
          false,
          p,
        );
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12), radius: 5.2 * s),
          math.pi * 0.28,
          math.pi * 0.44,
          false,
          p,
        );
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12), radius: 8.6 * s),
          -math.pi * 0.75,
          math.pi * 0.5,
          false,
          p,
        );
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12), radius: 8.6 * s),
          math.pi * 0.25,
          math.pi * 0.5,
          false,
          p,
        );

      case LuxGlyph.externalLink:
        final box = Path()
          ..moveTo(14 * s, 5 * s)
          ..lineTo(19 * s, 5 * s)
          ..lineTo(19 * s, 10 * s);
        canvas.drawPath(box, p);
        canvas.drawLine(pt(11, 13), pt(19, 5), p);
        final frame = Path()
          ..moveTo(11 * s, 6 * s)
          ..lineTo(6.5 * s, 6 * s)
          ..quadraticBezierTo(5 * s, 6 * s, 5 * s, 7.5 * s)
          ..lineTo(5 * s, 17.5 * s)
          ..quadraticBezierTo(5 * s, 19 * s, 6.5 * s, 19 * s)
          ..lineTo(16.5 * s, 19 * s)
          ..quadraticBezierTo(18 * s, 19 * s, 18 * s, 17.5 * s)
          ..lineTo(18 * s, 13 * s);
        canvas.drawPath(frame, p);

      case LuxGlyph.bolt:
        final path = Path()
          ..moveTo(13.2 * s, 3.2 * s)
          ..lineTo(5.8 * s, 13.4 * s)
          ..lineTo(11.8 * s, 13.4 * s)
          ..lineTo(10.8 * s, 20.8 * s)
          ..lineTo(18.2 * s, 10.6 * s)
          ..lineTo(12.2 * s, 10.6 * s)
          ..close();
        canvas.drawPath(path, p);

      case LuxGlyph.key:
        canvas.drawCircle(pt(8.2, 15.2), 3.6 * s, p);
        canvas.drawLine(pt(10.8, 12.6), pt(19.5, 4.5), p);
        canvas.drawLine(pt(16.5, 7.3), pt(19, 9.8), p);
        canvas.drawLine(pt(14.3, 9.4), pt(16.5, 11.6), p);

      case LuxGlyph.person:
        canvas.drawCircle(pt(12, 8.2), 3.4 * s, p);
        final shoulders = Path()
          ..moveTo(5.4 * s, 19.4 * s)
          ..cubicTo(5.4 * s, 15.8 * s, 8.2 * s, 14.2 * s, 12 * s, 14.2 * s)
          ..cubicTo(15.8 * s, 14.2 * s, 18.6 * s, 15.8 * s, 18.6 * s, 19.4 * s);
        canvas.drawPath(shoulders, p);

      case LuxGlyph.lock:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect(5.2, 10.6, 13.6, 9.4), Radius.circular(2.4 * s)),
          p,
        );
        final shackle = Path()
          ..moveTo(8.4 * s, 10.6 * s)
          ..lineTo(8.4 * s, 7.6 * s)
          ..arcToPoint(
            pt(15.6, 7.6),
            radius: Radius.circular(3.6 * s),
          )
          ..lineTo(15.6 * s, 10.6 * s);
        canvas.drawPath(shackle, p);

      case LuxGlyph.eye:
        final eye = Path()
          ..moveTo(2.8 * s, 12 * s)
          ..cubicTo(5.6 * s, 7.2 * s, 8.8 * s, 6.2 * s, 12 * s, 6.2 * s)
          ..cubicTo(15.2 * s, 6.2 * s, 18.4 * s, 7.2 * s, 21.2 * s, 12 * s)
          ..cubicTo(18.4 * s, 16.8 * s, 15.2 * s, 17.8 * s, 12 * s, 17.8 * s)
          ..cubicTo(8.8 * s, 17.8 * s, 5.6 * s, 16.8 * s, 2.8 * s, 12 * s)
          ..close();
        canvas.drawPath(eye, p);
        canvas.drawCircle(pt(12, 12), 2.5 * s, p);

      case LuxGlyph.eyeOff:
        final eye = Path()
          ..moveTo(2.8 * s, 12 * s)
          ..cubicTo(5.6 * s, 7.2 * s, 8.8 * s, 6.2 * s, 12 * s, 6.2 * s)
          ..cubicTo(15.2 * s, 6.2 * s, 18.4 * s, 7.2 * s, 21.2 * s, 12 * s)
          ..cubicTo(18.4 * s, 16.8 * s, 15.2 * s, 17.8 * s, 12 * s, 17.8 * s)
          ..cubicTo(8.8 * s, 17.8 * s, 5.6 * s, 16.8 * s, 2.8 * s, 12 * s)
          ..close();
        canvas.drawPath(eye, p);
        canvas.drawLine(pt(4.2, 4.2), pt(19.8, 19.8), p);

      case LuxGlyph.moreHorizontal:
        canvas.drawCircle(pt(6, 12), 1.15 * s, fill);
        canvas.drawCircle(pt(12, 12), 1.15 * s, fill);
        canvas.drawCircle(pt(18, 12), 1.15 * s, fill);

      case LuxGlyph.chevronDown:
        final path = Path()
          ..moveTo(6.5 * s, 9.2 * s)
          ..lineTo(12 * s, 14.8 * s)
          ..lineTo(17.5 * s, 9.2 * s);
        canvas.drawPath(path, p);

      case LuxGlyph.chevronUp:
        final path = Path()
          ..moveTo(6.5 * s, 14.8 * s)
          ..lineTo(12 * s, 9.2 * s)
          ..lineTo(17.5 * s, 14.8 * s);
        canvas.drawPath(path, p);

      case LuxGlyph.check:
        final path = Path()
          ..moveTo(5.2 * s, 12.6 * s)
          ..lineTo(9.8 * s, 17.2 * s)
          ..lineTo(18.8 * s, 7.2 * s);
        canvas.drawPath(path, p);

      case LuxGlyph.wifiOff:
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 18), radius: 8 * s),
          -math.pi * 0.78,
          math.pi * 0.56,
          false,
          p,
        );
        canvas.drawCircle(pt(12, 18.2), 1.1 * s, fill);
        canvas.drawLine(pt(4.5, 4.5), pt(19.5, 19.5), p);

      case LuxGlyph.wifiLock:
        canvas.drawArc(
          Rect.fromCircle(center: pt(10, 17), radius: 7.5 * s),
          -math.pi * 0.78,
          math.pi * 0.52,
          false,
          p,
        );
        canvas.drawCircle(pt(10, 17.2), 1.0 * s, fill);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect(14, 13.2, 6.2, 5.2), Radius.circular(1.2 * s)),
          p,
        );
        final sh = Path()
          ..moveTo(15.5 * s, 13.2 * s)
          ..lineTo(15.5 * s, 11.4 * s)
          ..arcToPoint(pt(18.7, 11.4), radius: Radius.circular(1.6 * s))
          ..lineTo(18.7 * s, 13.2 * s);
        canvas.drawPath(sh, p);

      case LuxGlyph.alertCircle:
        canvas.drawCircle(pt(12, 12), 8.6 * s, p);
        canvas.drawLine(pt(12, 8), pt(12, 12.8), p);
        canvas.drawCircle(pt(12, 15.9), 0.9 * s, fill);

      case LuxGlyph.power:
        canvas.drawLine(pt(12, 4), pt(12, 11.5), p);
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12.6), radius: 7 * s),
          -math.pi * 0.32,
          math.pi * 1.64,
          false,
          p,
        );

      case LuxGlyph.arrowUp:
        canvas.drawLine(pt(12, 18), pt(12, 6), p);
        final head = Path()
          ..moveTo(7.5 * s, 10.5 * s)
          ..lineTo(12 * s, 6 * s)
          ..lineTo(16.5 * s, 10.5 * s);
        canvas.drawPath(head, p);

      case LuxGlyph.arrowDown:
        canvas.drawLine(pt(12, 6), pt(12, 18), p);
        final head = Path()
          ..moveTo(7.5 * s, 13.5 * s)
          ..lineTo(12 * s, 18 * s)
          ..lineTo(16.5 * s, 13.5 * s);
        canvas.drawPath(head, p);

      case LuxGlyph.route:
        // Clean split-branch routing fork (two arrows diverging upward).
        final leftBranch = Path()
          ..moveTo(12 * s, 19.5 * s)
          ..lineTo(12 * s, 12.2 * s)
          ..lineTo(6.2 * s, 6.4 * s);
        canvas.drawPath(leftBranch, p);
        final leftHead = Path()
          ..moveTo(6.2 * s, 10.6 * s)
          ..lineTo(6.2 * s, 6.4 * s)
          ..lineTo(10.4 * s, 6.4 * s);
        canvas.drawPath(leftHead, p);
        final rightBranch = Path()
          ..moveTo(12 * s, 12.2 * s)
          ..lineTo(17.8 * s, 6.4 * s);
        canvas.drawPath(rightBranch, p);
        final rightHead = Path()
          ..moveTo(13.6 * s, 6.4 * s)
          ..lineTo(17.8 * s, 6.4 * s)
          ..lineTo(17.8 * s, 10.6 * s);
        canvas.drawPath(rightHead, p);

      case LuxGlyph.globe:
        canvas.drawCircle(pt(12, 12), 8.5 * s, p);
        canvas.drawLine(pt(3.5, 12), pt(20.5, 12), p);
        canvas.drawOval(rect(8.5, 3.5, 7, 17), p);

      case LuxGlyph.home:
        final roof = Path()
          ..moveTo(4.2 * s, 11.4 * s)
          ..lineTo(12 * s, 4.4 * s)
          ..lineTo(19.8 * s, 11.4 * s);
        canvas.drawPath(roof, p);
        final walls = Path()
          ..moveTo(6.4 * s, 9.6 * s)
          ..lineTo(6.4 * s, 19.2 * s)
          ..lineTo(17.6 * s, 19.2 * s)
          ..lineTo(17.6 * s, 9.6 * s);
        canvas.drawPath(walls, p);

      case LuxGlyph.swap:
        canvas.drawLine(pt(5, 9), pt(19, 9), p);
        final a1 = Path()
          ..moveTo(15.5 * s, 5.5 * s)
          ..lineTo(19 * s, 9 * s)
          ..lineTo(15.5 * s, 12.5 * s);
        canvas.drawPath(a1, p);
        canvas.drawLine(pt(19, 15), pt(5, 15), p);
        final a2 = Path()
          ..moveTo(8.5 * s, 11.5 * s)
          ..lineTo(5 * s, 15 * s)
          ..lineTo(8.5 * s, 18.5 * s);
        canvas.drawPath(a2, p);

      case LuxGlyph.sun:
        canvas.drawCircle(pt(12, 12), 4.0 * s, p);
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            Offset((12 + math.cos(a) * 6.8) * s, (12 + math.sin(a) * 6.8) * s),
            Offset((12 + math.cos(a) * 9.0) * s, (12 + math.sin(a) * 9.0) * s),
            p,
          );
        }

      case LuxGlyph.moon:
        final moonPath = Path()
          ..moveTo(18.8 * s, 14.5 * s)
          ..arcToPoint(
            pt(9.5, 5.2),
            radius: Radius.circular(6.8 * s),
            clockwise: true,
          )
          ..arcToPoint(
            pt(18.8, 14.5),
            radius: Radius.circular(8.2 * s),
            largeArc: true,
            clockwise: false,
          )
          ..close();
        canvas.drawPath(moonPath, p);

      case LuxGlyph.refresh:
        canvas.drawArc(
          Rect.fromCircle(center: pt(12, 12), radius: 7.4 * s),
          -math.pi * 0.72,
          math.pi * 1.48,
          false,
          p,
        );
        final head = Path()
          ..moveTo(16.6 * s, 4.8 * s)
          ..lineTo(18.8 * s, 8.2 * s)
          ..lineTo(15.0 * s, 8.8 * s);
        canvas.drawPath(head, p);

      case LuxGlyph.download:
        canvas.drawLine(pt(12, 4.5), pt(12, 15.2), p);
        final head = Path()
          ..moveTo(8.2 * s, 11.6 * s)
          ..lineTo(12 * s, 15.4 * s)
          ..lineTo(15.8 * s, 11.6 * s);
        canvas.drawPath(head, p);
        final tray = Path()
          ..moveTo(5.2 * s, 16.5 * s)
          ..lineTo(5.2 * s, 19 * s)
          ..lineTo(18.8 * s, 19 * s)
          ..lineTo(18.8 * s, 16.5 * s);
        canvas.drawPath(tray, p);

      case LuxGlyph.search:
        canvas.drawCircle(pt(10.8, 10.8), 6.2 * s, p);
        canvas.drawLine(pt(15.5, 15.5), pt(19.6, 19.6), p);

      case LuxGlyph.trash:
        canvas.drawLine(pt(5, 7), pt(19, 7), p);
        canvas.drawLine(pt(9.2, 4.5), pt(14.8, 4.5), p);
        final body = Path()
          ..moveTo(6.8 * s, 7 * s)
          ..lineTo(7.6 * s, 19 * s)
          ..lineTo(16.4 * s, 19 * s)
          ..lineTo(17.2 * s, 7 * s);
        canvas.drawPath(body, p);
        canvas.drawLine(pt(10.2, 10.5), pt(10.2, 15.8), p);
        canvas.drawLine(pt(13.8, 10.5), pt(13.8, 15.8), p);

      case LuxGlyph.copy:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect(9, 9, 10.5, 10.5), Radius.circular(2 * s)),
          p,
        );
        final back = Path()
          ..moveTo(6.5 * s, 15 * s)
          ..lineTo(5.5 * s, 15 * s)
          ..quadraticBezierTo(4.5 * s, 15 * s, 4.5 * s, 14 * s)
          ..lineTo(4.5 * s, 5.5 * s)
          ..quadraticBezierTo(4.5 * s, 4.5 * s, 5.5 * s, 4.5 * s)
          ..lineTo(14 * s, 4.5 * s)
          ..quadraticBezierTo(15 * s, 4.5 * s, 15 * s, 5.5 * s)
          ..lineTo(15 * s, 6.5 * s);
        canvas.drawPath(back, p);

      case LuxGlyph.close:
        canvas.drawLine(pt(6.5, 6.5), pt(17.5, 17.5), p);
        canvas.drawLine(pt(17.5, 6.5), pt(6.5, 17.5), p);

      case LuxGlyph.pause:
        canvas.drawLine(pt(9, 6), pt(9, 18), p);
        canvas.drawLine(pt(15, 6), pt(15, 18), p);

      case LuxGlyph.play:
        final tri = Path()
          ..moveTo(7.5 * s, 5.5 * s)
          ..lineTo(18.2 * s, 12 * s)
          ..lineTo(7.5 * s, 18.5 * s)
          ..close();
        canvas.drawPath(tri, p);

      case LuxGlyph.edit:
        final pen = Path()
          ..moveTo(15.8 * s, 5.2 * s)
          ..lineTo(18.8 * s, 8.2 * s)
          ..lineTo(8.5 * s, 18.5 * s)
          ..lineTo(4.8 * s, 19.2 * s)
          ..lineTo(5.5 * s, 15.5 * s)
          ..close();
        canvas.drawPath(pen, p);

      case LuxGlyph.upload:
        canvas.drawLine(pt(12, 15.5), pt(12, 4.8), p);
        final head = Path()
          ..moveTo(8.2 * s, 8.4 * s)
          ..lineTo(12 * s, 4.6 * s)
          ..lineTo(15.8 * s, 8.4 * s);
        canvas.drawPath(head, p);
        final tray = Path()
          ..moveTo(5.2 * s, 16.5 * s)
          ..lineTo(5.2 * s, 19 * s)
          ..lineTo(18.8 * s, 19 * s)
          ..lineTo(18.8 * s, 16.5 * s);
        canvas.drawPath(tray, p);

      case LuxGlyph.chevronRight:
        final path = Path()
          ..moveTo(9.2 * s, 6.5 * s)
          ..lineTo(14.8 * s, 12 * s)
          ..lineTo(9.2 * s, 17.5 * s);
        canvas.drawPath(path, p);

      case LuxGlyph.xCircle:
        canvas.drawCircle(pt(12, 12), 8.6 * s, p);
        canvas.drawLine(pt(9, 9), pt(15, 15), p);
        canvas.drawLine(pt(15, 9), pt(9, 15), p);
    }
  }

  @override
  bool shouldRepaint(covariant _LuxGlyphPainter old) =>
      old.glyph != glyph || old.color != color || old.strokeWidth != strokeWidth;
}
