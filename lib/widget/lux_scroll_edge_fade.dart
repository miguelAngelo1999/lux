import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Scroll-aware edge feathering using a GPU `ShaderMask` (`BlendMode.dstIn`).
///
/// Softly fades scrolled content into whatever surface sits behind it (solid
/// Porcelain/Obsidian or translucent macOS Liquid Glass / Vibrancy) only on the
/// edges where additional scrollable content currently exists:
/// - At the top of a list, the top edge stays crisp while the bottom fades.
/// - Mid-scroll, both edges gently feather.
/// - At the bottom, the bottom fade recedes so the final item sits sharp.
/// - When all items fit without scrolling, the mask is bypassed completely.
class LuxScrollEdgeFade extends StatefulWidget {
  final Widget child;
  final Axis axis;
  final double startFade;
  final double endFade;

  const LuxScrollEdgeFade({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.startFade = 20.0,
    this.endFade = 32.0,
  });

  @override
  State<LuxScrollEdgeFade> createState() => _LuxScrollEdgeFadeState();
}

class _LuxScrollEdgeFadeState extends State<LuxScrollEdgeFade> {
  double _startStrength = 0.0;
  double _endStrength = 0.0;

  void _updateFromMetrics(ScrollMetrics metrics) {
    if (metrics.axis != widget.axis) return;
    final double nextStart;
    final double nextEnd;
    if (!metrics.hasContentDimensions || metrics.maxScrollExtent <= 1.0) {
      nextStart = 0.0;
      nextEnd = 0.0;
    } else {
      nextStart = (metrics.extentBefore / 24.0).clamp(0.0, 1.0);
      nextEnd = (metrics.extentAfter / 28.0).clamp(0.0, 1.0);
    }
    if ((nextStart - _startStrength).abs() > 0.015 ||
        (nextEnd - _endStrength).abs() > 0.015) {
      void apply() {
        if (!mounted) return;
        setState(() {
          _startStrength = nextStart;
          _endStrength = nextEnd;
        });
      }

      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      } else {
        apply();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final startPx = widget.startFade * _startStrength;
    final endPx = widget.endFade * _endStrength;
    final active = startPx > 0.5 || endPx > 0.5;

    final masked = active
        ? ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect bounds) {
              final extent = widget.axis == Axis.vertical
                  ? bounds.height
                  : bounds.width;
              if (extent <= 1.0) {
                return const LinearGradient(
                  colors: [Colors.white, Colors.white],
                ).createShader(bounds);
              }
              final startStop = (startPx / extent).clamp(0.0, 0.25);
              final endStop = (1.0 - (endPx / extent)).clamp(0.75, 1.0);

              final colors = <Color>[];
              final stops = <double>[];

              if (startStop > 0.001) {
                colors.add(Colors.transparent);
                stops.add(0.0);
                colors.add(Colors.white);
                stops.add(startStop);
              } else {
                colors.add(Colors.white);
                stops.add(0.0);
              }

              if (endStop < 0.999) {
                colors.add(Colors.white);
                stops.add(endStop);
                colors.add(Colors.transparent);
                stops.add(1.0);
              } else {
                colors.add(Colors.white);
                stops.add(1.0);
              }

              return LinearGradient(
                begin: widget.axis == Axis.vertical
                    ? Alignment.topCenter
                    : Alignment.centerLeft,
                end: widget.axis == Axis.vertical
                    ? Alignment.bottomCenter
                    : Alignment.centerRight,
                colors: colors,
                stops: stops,
              ).createShader(bounds);
            },
            child: widget.child,
          )
        : widget.child;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) {
          _updateFromMetrics(notification.metrics);
        }
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) {
            _updateFromMetrics(notification.metrics);
          }
          return false;
        },
        child: masked,
      ),
    );
  }
}
