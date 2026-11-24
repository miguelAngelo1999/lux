import 'package:flutter/material.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';

/// Non-blocking Windows banner shown when the user declined (or could not
/// approve) the one-time `LuxCoreService` UAC setup and Lux fell back to
/// non-elevated `System` mode.
///
/// Explains in plain language what works normally vs. what is limited, and
/// provides an "Enable now" button that re-triggers the one-time setup and
/// clears the banner immediately on success.
class WindowsServiceBanner extends StatefulWidget {
  final CoreManager coreManager;

  const WindowsServiceBanner({super.key, required this.coreManager});

  @override
  State<WindowsServiceBanner> createState() => _WindowsServiceBannerState();
}

class _WindowsServiceBannerState extends State<WindowsServiceBanner> {
  bool _dismissed = false;
  bool _enabling = false;

  Future<void> _enable() async {
    if (_enabling) return;
    setState(() => _enabling = true);
    try {
      final ok = await widget.coreManager.enableWindowsService();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(SnackBar(
        content: TText(ok
            ? 'Background service enabled. Full functionality is now active.'
            : 'Admin setup cancelled. Continuing in limited System mode.'),
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final limited =
        context.select<AppStateModel, bool>((m) => m.windowsLimitedMode);
    if (!limited || _dismissed) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? Colors.amber.shade900.withAlpha(55)
        : Colors.amber.shade50;
    final borderColor = isDark
        ? Colors.amber.shade700.withAlpha(140)
        : Colors.amber.shade300;
    final iconColor = isDark ? Colors.amber.shade300 : Colors.amber.shade900;
    final textColor = isDark ? Colors.amber.shade100 : Colors.amber.shade900;

    return Container(
      key: const Key('windows_limited_mode_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.admin_panel_settings_outlined,
              size: 18,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TText(
                  'Running in limited mode (admin setup skipped)',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 3),
                TText(
                  'Working normally: web browsers and standard desktop apps.',
                  style: TextStyle(fontSize: 11.5, color: textColor),
                ),
                const SizedBox(height: 2),
                TText(
                  'Limited without one-time admin setup: Microsoft Store / UWP apps (such as iCloud for Windows and Microsoft Store) may fail to connect or sign in, and Mixed / TUN modes cannot be enabled.',
                  style: TextStyle(fontSize: 11.5, color: textColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            key: const Key('windows_banner_enable_btn'),
            onPressed: _enabling ? null : _enable,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 32),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: _enabling
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const TText('Enable now'),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('windows_banner_dismiss_btn'),
            icon: Icon(Icons.close, size: 16, color: iconColor),
            tooltip: tl(context, 'Dismiss'),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}
