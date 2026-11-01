import 'package:flutter/material.dart';
import 'package:lux/widget/proxy_item_action_menu.dart';
import 'package:lux/util/t_text.dart';

import '../const/const.dart';
import '../core/core_config.dart';
import '../core/core_manager.dart';

/// Result state of the per-proxy reachability test.
enum TestState { untested, testing, reachable, unreachable, certError, notApplicable }

class ProxyListItem extends StatefulWidget {
  final ProxyItem item;
  final void Function(ProxyItemAction action) onChange;
  final CoreManager? coreManager;
  // Whole-row selection (Option B): tapping anywhere on the row selects this
  // proxy, not only the radio dot. [selected] drives the selected styling.
  final bool selected;
  final void Function(String id)? onSelect;

  const ProxyListItem({
    super.key,
    required this.item,
    required this.onChange,
    this.coreManager,
    this.selected = false,
    this.onSelect,
  });

  @override
  State<ProxyListItem> createState() => _ProxyListItemState();
}

class _ProxyListItemState extends State<ProxyListItem> {
  final menuController = MenuController();
  TestState _state = TestState.untested;
  int _latencyMs = 0;

  /// A PAC-only proxy has a PAC URL and no fixed server, so a latency test to a
  /// single upstream is meaningless — show "PAC — n/a" instead of a red fail.
  bool get _isPacOnly {
    final pac = widget.item.pacUrl ?? '';
    final server = widget.item.server ?? '';
    return pac.isNotEmpty && server.isEmpty;
  }

  Future<void> _testDelay() async {
    if (_state == TestState.testing || widget.coreManager == null) return;
    if (_isPacOnly) {
      setState(() => _state = TestState.notApplicable);
      return;
    }
    setState(() => _state = TestState.testing);
    final result = await widget.coreManager!.testProxyDelayDetailed(widget.item.id);
    if (!mounted) return;
    setState(() {
      if (result.delay >= 0) {
        _state = TestState.reachable;
        _latencyMs = result.delay;
      } else if (result.certError) {
        _state = TestState.certError;
      } else {
        _state = TestState.unreachable;
      }
    });
    // Note: unlike before, we do NOT auto-open the cert dialog. The certError
    // state shows a "Trust?" chip the user taps deliberately (_promptCertTrust).
  }

  Future<void> _promptCertTrust() async {
    if (!mounted || widget.coreManager == null) return;
    final item = widget.item;
    final server = item.server ?? '';
    final port = item.port ?? 0;
    if (server.isEmpty || port == 0) return;

    final shouldCheck = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.security, size: 20, color: Colors.orange),
          SizedBox(width: 8),
          Flexible(child: TText('Certificate Error', style: TextStyle(fontSize: 15))),
        ]),
        content: const TText(
          'The proxy uses an SSL certificate not trusted by this system. '
          'This usually means a corporate proxy is inspecting traffic.\n\n'
          'Would you like to detect and install the certificate?',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const TText('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const TText('Trust Certificate'),
          ),
        ],
      ),
    );

    if (shouldCheck != true || !mounted) return;

    try {
      // Get full proxy detail for username
      final detail = await widget.coreManager!.getProxyDetail(item.id);
      final username = detail?.raw['username'] as String? ?? '';
      final password = detail?.password ?? item.password ?? '';

      final cert = await widget.coreManager!.checkCert(
        server: server,
        port: port,
        username: username,
        password: password,
      );

      if (!mounted) return;

      if (cert.intercepted && cert.pem.isNotEmpty) {
        await _installCert(cert);
      } else if (cert.error.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cert check failed: ${cert.error}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('No intercepting certificate detected')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _installCert(CertCheckResult cert) async {
    try {
      // lux_core runs as root — use its install-cert endpoint directly
      await widget.coreManager!.installCert(cert.pem);

      if (!mounted) return;

      // Brief pause then re-check to confirm the cert is now trusted.
      // This stops the infinite re-prompt loop: if install worked the check
      // will return intercepted=false and we show success; if still untrusted
      // (e.g. macOS cached trust state needs restart) we tell the user that
      // instead of showing the install button again.
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      final item = widget.item;
      final detail = await widget.coreManager!.getProxyDetail(item.id);
      final username = detail?.raw['username'] as String? ?? '';
      final password = detail?.password ?? item.password ?? '';

      CertCheckResult? recheck;
      try {
        recheck = await widget.coreManager!.checkCert(
          server: item.server ?? '',
          port: item.port ?? 0,
          username: username,
          password: password,
        );
      } catch (_) {}

      if (!mounted) return;

      if (recheck == null || !recheck.intercepted) {
        // All good — cert is now trusted by the system
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Certificate installed and trusted. Proxy is ready.')),
        );
        // Re-test delay to update the chip
        _testDelay();
      } else {
        // Still showing as untrusted right after install — the install likely
        // failed silently (e.g. wrong cert extracted, permission issue).
        // System trust is immediate; no restart is needed or helpful.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 6),
            content: TText(
              'Certificate installed but proxy still reports untrusted. '
              'Try running the proxy test again — if it persists, the cert may not have installed correctly.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Certificate installation failed: $e')),
        );
      }
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'http':
        return 'HTTP';
      case 'socks5':
        return 'SOCKS5';
      case 'ss':
        return 'SS';
      case 'vmess':
        return 'VMess';
      case 'vless':
        return 'VLess';
      case 'trojan':
        return 'Trojan';
      case 'direct':
        return 'DIRECT';
      default:
        return type.toUpperCase();
    }
  }

  // ── test result chip (separate from the Test button — Option B) ──────────
  Widget _resultChip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Color fg, bg;
    String text;
    bool tappable = false;
    IconData? icon;
    switch (_state) {
      case TestState.untested:
        return const SizedBox.shrink(); // nothing until tested
      case TestState.testing:
        return const SizedBox(
          width: 12, height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        );
      case TestState.reachable:
        fg = Colors.green; bg = Colors.green.withAlpha(28);
        icon = Icons.check_circle_outline; text = '$_latencyMs ms';
        break;
      case TestState.unreachable:
        fg = cs.error; bg = cs.error.withAlpha(28);
        icon = Icons.error_outline; text = tl(context, 'Unreachable');
        break;
      case TestState.certError:
        fg = const Color(0xFFE0A31E); bg = const Color(0x22E0A31E);
        icon = Icons.gpp_maybe_outlined; text = tl(context, 'Trust?');
        tappable = true;
        break;
      case TestState.notApplicable:
        fg = cs.outline; bg = Colors.transparent;
        icon = Icons.info_outline; text = tl(context, 'PAC — n/a');
        break;
    }
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: fg),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 10.5, color: fg)),
      ]),
    );
    if (!tappable) return chip;
    // certError → tapping opens the Trust-Certificate flow deliberately.
    return Tooltip(
      message: tl(context,
          'Reachable, but its certificate is not trusted. Click to fix.'),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _promptCertTrust,
        child: chip,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cs = Theme.of(context).colorScheme;
    final selected = widget.selected;

    final titleText = item.name.isNotEmpty
        ? item.name
        : '${item.server ?? ''}:${item.port ?? ''}';

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: titleText,
      child: Material(
        color: selected ? cs.primaryContainer.withAlpha(90) : Colors.transparent,
        child: InkWell(
          // Whole-row select — the core fix. Tapping anywhere that isn't an
          // explicit action control (Test button / result chip / ⋯ menu)
          // selects this proxy.
          onTap: widget.onSelect == null ? null : () => widget.onSelect!(item.id),
          child: Stack(children: [
            if (selected)
              Positioned(
                left: 0, top: 6, bottom: 6,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                // Leading radio (visual + keyboard; inherits the ancestor
                // RadioGroup so Space/arrow keys still work).
                Radio<String>(value: item.id),
                const SizedBox(width: 4),
                // Name + subtitle (part of the select surface)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(
                            titleText,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.withAlpha(36),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(tl(context, 'Active'),
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.green)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.secondaryContainer,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(_typeLabel(item.type),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSecondaryContainer)),
                        ),
                        if (item.server != null && item.server!.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text('${item.server}:${item.port}',
                                style:
                                    TextStyle(fontSize: 10, color: cs.outline),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ]),
                    ],
                  ),
                ),
                // ── Trailing action cluster: bounded, do NOT select the row ──
                if (widget.coreManager != null) ...[
                  _resultChip(context),
                  const SizedBox(width: 6),
                  // Explicit, labeled Trust button — only when the proxy is
                  // reachable but its certificate isn't trusted. Opens the
                  // same cert-trust flow as tapping the "Trust?" chip.
                  if (_state == TestState.certError) ...[
                    SizedBox(
                      height: 26,
                      child: OutlinedButton(
                        onPressed: _promptCertTrust,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: const BorderSide(color: Color(0xFFE0A31E)),
                          foregroundColor: const Color(0xFFE0A31E),
                        ),
                        child: Text(tl(context, 'Trust'),
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Explicit, labeled Test button (Option B).
                  SizedBox(
                    height: 26,
                    child: OutlinedButton(
                      onPressed:
                          _state == TestState.testing ? null : _testDelay,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 26),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(color: cs.primary.withAlpha(140)),
                        foregroundColor: cs.primary,
                      ),
                      child: Text(tl(context, 'Test'),
                          style: const TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                ProxyItemActionMenu(
                  onClick: widget.onChange,
                  controller: menuController,
                  id: item.id,
                  type: item.type,
                  passwordLocked: item.passwordLocked,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
