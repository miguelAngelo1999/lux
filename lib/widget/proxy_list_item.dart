import 'package:flutter/material.dart';
import 'package:lux/widget/pac_rules_dialog.dart';
import 'package:lux/widget/proxy_item_action_menu.dart';
import 'package:lux/util/t_text.dart';

import '../const/const.dart';
import '../core/core_config.dart';
import '../core/core_manager.dart';
import '../util/cert_trust.dart';

/// Result state of the per-proxy reachability test.
enum TestState { untested, testing, reachable, unreachable, certError, authError, notApplicable }

/// Snapshot of a proxy's latest test outcome reported to the parent page.
class ProxyTestStatus {
  final TestState state;
  final int latencyMs;
  final bool pacReachable;
  final String errorMessage;

  const ProxyTestStatus({
    this.state = TestState.untested,
    this.latencyMs = 0,
    this.pacReachable = false,
    this.errorMessage = '',
  });
}

/// Callback bridge attached to the currently selected [ProxyListItem] so
/// page-level actions (e.g. status banner buttons) can focus the inline
/// password field, run a test, or open the cert-trust flow.
class ProxyItemController {
  VoidCallback? focusPassword;
  VoidCallback? runTest;
  VoidCallback? promptCertTrust;

  void detach() {
    focusPassword = null;
    runTest = null;
    promptCertTrust = null;
  }
}

class ProxyListItem extends StatefulWidget {
  final ProxyItem item;
  final void Function(ProxyItemAction action) onChange;
  final CoreManager? coreManager;
  // Whole-row selection (Option B): tapping anywhere on the row selects this
  // proxy, not only the radio dot. [selected] drives the selected styling.
  final bool selected;
  final void Function(String id)? onSelect;
  final void Function(ProxyTestStatus status)? onTestStatusChanged;
  final ProxyItemController? selectedController;
  final VoidCallback? onCredentialsSaved;

  const ProxyListItem({
    super.key,
    required this.item,
    required this.onChange,
    this.coreManager,
    this.selected = false,
    this.onSelect,
    this.onTestStatusChanged,
    this.selectedController,
    this.onCredentialsSaved,
  });

  @override
  State<ProxyListItem> createState() => _ProxyListItemState();
}

class _ProxyListItemState extends State<ProxyListItem> {
  final menuController = MenuController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode();

  TestState _state = TestState.untested;
  int _latencyMs = 0;
  bool _pacReachable = false;
  String _errorMessage = '';

  bool _obscurePassword = true;
  bool _retyping = false;
  bool _isSavingCredentials = false;
  bool _usernameDirty = false;
  bool _passwordDirty = false;
  bool _effectivePasswordLocked = false;
  bool _detailLoaded = false;
  bool _credentialsExpanded = false;

  /// A PAC-only proxy has a PAC URL and no fixed server, so a latency test to a
  /// single upstream is meaningless — show "PAC — n/a" instead of a red fail.
  bool get _isPacOnly {
    final pac = widget.item.pacUrl ?? '';
    final server = widget.item.server ?? '';
    return pac.isNotEmpty && server.isEmpty;
  }

  /// Proxy types that authenticate with username/password.
  bool get _supportsCredentials {
    if (widget.item.type == 'direct') return false;
    return widget.item.type == 'http' ||
        widget.item.type == 'socks5' ||
        (widget.item.pacUrl ?? '').isNotEmpty;
  }

  bool get _isLockedView => _effectivePasswordLocked && !_retyping;

  ProxyTestStatus get _currentStatus => ProxyTestStatus(
        state: _state,
        latencyMs: _latencyMs,
        pacReachable: _pacReachable,
        errorMessage: _errorMessage,
      );

  @override
  void initState() {
    super.initState();
    _credentialsExpanded = widget.selected && _supportsCredentials;
    _syncInitialCredentials();
    if (widget.selected) {
      _attachSelectedController();
      _loadProxyDetail();
    }
  }

  @override
  void didUpdateWidget(covariant ProxyListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _usernameDirty = false;
      _passwordDirty = false;
      _retyping = false;
      _detailLoaded = false;
      _credentialsExpanded = widget.selected && _supportsCredentials;
      _state = TestState.untested;
      _latencyMs = 0;
      _pacReachable = false;
      _errorMessage = '';
      _syncInitialCredentials();
    } else {
      if (!_usernameDirty &&
          (widget.item.username ?? '').isNotEmpty &&
          _usernameCtrl.text != widget.item.username) {
        _usernameCtrl.text = widget.item.username!;
      }
      if (!_retyping) {
        _effectivePasswordLocked = widget.item.passwordLocked;
      }
    }

    if (widget.selected && !oldWidget.selected) {
      _credentialsExpanded = _supportsCredentials;
      _attachSelectedController();
      _loadProxyDetail();
      if (_state != TestState.untested) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onTestStatusChanged?.call(_currentStatus);
        });
      }
    } else if (!widget.selected && oldWidget.selected) {
      _credentialsExpanded = false;
      oldWidget.selectedController?.detach();
    } else if (widget.selected) {
      _attachSelectedController();
    }
  }

  @override
  void dispose() {
    if (widget.selected) {
      widget.selectedController?.detach();
    }
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _syncInitialCredentials() {
    _effectivePasswordLocked = widget.item.passwordLocked;
    _usernameCtrl.text = widget.item.username ?? '';
    if (!_effectivePasswordLocked) {
      _passwordCtrl.text = widget.item.password ?? '';
    } else {
      _passwordCtrl.clear();
    }
  }

  void _attachSelectedController() {
    final ctrl = widget.selectedController;
    if (ctrl == null || !widget.selected) return;
    ctrl.focusPassword = _focusPasswordField;
    ctrl.runTest = _testDelay;
    ctrl.promptCertTrust = _promptCertTrust;
  }

  Future<void> _loadProxyDetail() async {
    if (!_supportsCredentials || widget.coreManager == null) return;
    if (_detailLoaded) return;
    _detailLoaded = true;
    final detail = await widget.coreManager!.getProxyDetail(widget.item.id);
    if (!mounted || detail == null) return;
    final locked =
        (detail.raw['passwordLocked'] as bool?) ?? widget.item.passwordLocked;
    final remoteUser = (detail.raw['username'] as String?) ?? '';
    final remotePass = detail.password ?? '';
    setState(() {
      if (!_retyping) {
        _effectivePasswordLocked = locked;
      }
      if (!_usernameDirty && remoteUser.isNotEmpty) {
        _usernameCtrl.text = remoteUser;
      }
      if (!locked && !_retyping && !_passwordDirty && remotePass.isNotEmpty) {
        _passwordCtrl.text = remotePass;
      }
    });
  }

  void _toggleCredentialsExpanded() {
    if (!_supportsCredentials) return;
    setState(() => _credentialsExpanded = !_credentialsExpanded);
    if (_credentialsExpanded) {
      _loadProxyDetail();
    }
  }

  void _startRetype() {
    setState(() {
      _credentialsExpanded = true;
      _retyping = true;
      _obscurePassword = true;
      _passwordCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocus.requestFocus();
    });
  }

  void _focusPasswordField() {
    if (!mounted || !_supportsCredentials) return;
    if (!_credentialsExpanded) {
      setState(() => _credentialsExpanded = true);
      _loadProxyDetail();
    }
    if (_isLockedView) {
      _startRetype();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocus.requestFocus();
    });
  }

  Future<void> _saveAndTest() async {
    if (_isSavingCredentials || _state == TestState.testing) return;
    if (widget.coreManager == null) return;

    final trimmedUsername = _usernameCtrl.text.trim();
    _usernameCtrl.text = trimmedUsername;
    setState(() => _isSavingCredentials = true);

    try {
      final detail = await widget.coreManager!.getProxyDetail(widget.item.id);
      final updated = detail != null
          ? Map<String, dynamic>.from(detail.raw)
          : <String, dynamic>{
              'id': widget.item.id,
              'name': widget.item.name,
              'type': widget.item.type,
              if (widget.item.server != null) 'server': widget.item.server,
              if (widget.item.port != null) 'port': widget.item.port,
              if ((widget.item.pacUrl ?? '').isNotEmpty)
                'pacUrl': widget.item.pacUrl,
            };

      updated['username'] = trimmedUsername;
      if (!_isLockedView) {
        updated['password'] = _passwordCtrl.text;
        if (_retyping && _passwordCtrl.text.isNotEmpty) {
          updated.remove('passwordLocked');
        }
      }

      await widget.coreManager!.updateProxy(widget.item.id, updated);
      if (!mounted) return;
      setState(() {
        _usernameDirty = false;
        _passwordDirty = false;
        if (_retyping && _passwordCtrl.text.isNotEmpty) {
          _effectivePasswordLocked = false;
          _retyping = false;
        }
      });
      widget.onCredentialsSaved?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _isSavingCredentials = false);
      }
    }

    if (mounted) {
      await _testDelay();
    }
  }

  Future<void> _testDelay() async {
    if (_state == TestState.testing || widget.coreManager == null) return;
    setState(() {
      _state = TestState.testing;
      _pacReachable = false;
      _errorMessage = '';
    });
    widget.onTestStatusChanged?.call(_currentStatus);
    final result = await widget.coreManager!.testProxyDelayDetailed(widget.item.id);
    if (!mounted) return;
    setState(() {
      _errorMessage = result.error;
      if (result.delay == 0 && result.pacOnly) {
        _state = TestState.reachable;
        _latencyMs = 0;
        _pacReachable = true;
        _errorMessage = '';
      } else if (result.delay >= 0) {
        _state = TestState.reachable;
        _latencyMs = result.delay;
        _pacReachable = false;
        _errorMessage = '';
      } else if (result.certError) {
        _state = TestState.certError;
        if (_errorMessage.isEmpty) _errorMessage = 'Certificate Untrusted';
      } else if (result.error.contains('407') ||
                 result.error.toLowerCase().contains('auth') ||
                 result.error.toLowerCase().contains('denied') ||
                 result.error.toLowerCase().contains('rejected')) {
        _state = TestState.authError;
      } else {
        _state = TestState.unreachable;
      }
    });
    widget.onTestStatusChanged?.call(_currentStatus);
    if (_state == TestState.authError && _supportsCredentials) {
      _focusPasswordField();
    }
    // Note: unlike before, we do NOT auto-open the cert dialog. The certError
    // state shows a "Trust?" chip the user taps deliberately (_promptCertTrust).
  }

  void _openPacRules() {
    if (widget.coreManager == null) return;
    PacRulesDialog.show(
      context: context,
      coreManager: widget.coreManager!,
      proxyId: widget.item.id,
      proxyName: widget.item.name.isNotEmpty
          ? widget.item.name
          : '${widget.item.server ?? ''}:${widget.item.port ?? ''}',
      initialPacUrl: widget.item.pacUrl,
    );
  }

  Future<void> _promptCertTrust() async {
    if (!mounted || widget.coreManager == null) return;
    final item = widget.item;
    var server = item.server ?? '';
    var port = item.port ?? 0;
    if ((server.isEmpty || port == 0) && _isPacOnly) {
      final up = await widget.coreManager!.getPacUpstream(item.id);
      if (up != null) {
        server = up.server;
        port = up.port;
      }
    }
    if (!mounted || server.isEmpty || port == 0) return;

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
        final thumbprint = extractCertThumbprintSha1(cert.pem);
        if (thumbprint != null && await isCertInSystemStore(thumbprint: thumbprint)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: TText('Certificate is already trusted. Proxy is ready.')),
          );
          _testDelay();
          return;
        }
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
      final item = widget.item;
      var server = item.server ?? '';
      var port = item.port ?? 0;
      if ((server.isEmpty || port == 0) && _isPacOnly) {
        final up = await widget.coreManager!.getPacUpstream(item.id);
        if (up != null) {
          server = up.server;
          port = up.port;
        }
      }

      // Execute proven CLI installer script method
      await trustProxyCertificate(proxyHost: server, pem: cert.pem);

      // Notify lux_core in-memory extra roots
      try {
        await widget.coreManager!.installCert(cert.pem);
      } catch (_) {}

      if (!mounted) return;

      // On success: Show confirmation toast and immediately re-test proxy connection
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: TText('Certificate installed and trusted. Proxy is ready.')),
      );

      _testDelay();
    } on CertTrustException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Certificate installation failed: $e')),
      );
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
        icon = Icons.check_circle_outline;
        text = _pacReachable ? 'PAC OK' : '$_latencyMs ms';
        if (_pacReachable) tappable = true;
        break;
      case TestState.unreachable:
        fg = cs.error; bg = cs.error.withAlpha(28);
        icon = Icons.error_outline; text = tl(context, 'Unreachable');
        break;
      case TestState.authError:
        fg = const Color(0xFFE05638); bg = const Color(0x22E05638);
        icon = Icons.lock_outline; text = tl(context, 'Invalid username or password');
        break;
      case TestState.certError:
        fg = const Color(0xFFE0A31E); bg = const Color(0x22E0A31E);
        icon = Icons.gpp_maybe_outlined; text = tl(context, 'Certificate Untrusted');
        tappable = true;
        break;
      case TestState.notApplicable:
        fg = cs.outline; bg = Colors.transparent;
        icon = Icons.info_outline; text = tl(context, 'PAC — n/a');
        tappable = true;
        break;
    }

    final String tooltipMessage;
    if (_state == TestState.certError) {
      tooltipMessage = _errorMessage.isNotEmpty
          ? 'Certificate Untrusted: $_errorMessage. Click to install.'
          : tl(context, 'Reachable, but its certificate is not trusted. Click to fix.');
    } else if (_pacReachable || _state == TestState.notApplicable) {
      tooltipMessage = tl(context, 'Active PAC proxy. Click to view rules.');
    } else if (_errorMessage.isNotEmpty) {
      tooltipMessage = _errorMessage;
    } else {
      tooltipMessage = text;
    }

    final chip = Tooltip(
      message: tooltipMessage,
      child: Container(
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
      ),
    );
    if (!tappable) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        if (_state == TestState.certError) {
          _promptCertTrust();
        } else if (_pacReachable || _state == TestState.notApplicable) {
          _openPacRules();
        }
      },
      child: chip,
    );
  }

  InputDecoration _inlineInputDecoration(
    BuildContext context, {
    required String hintText,
    required IconData prefixIcon,
    bool isAuthError = false,
    Widget? suffixIcon,
    BoxConstraints? suffixIconConstraints,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = isDark
        ? (widget.selected
            ? Colors.black.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.04))
        : (widget.selected
            ? Colors.black.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.02));
    final baseBorderColor = isAuthError
        ? const Color(0xFFE05638).withValues(alpha: 0.75)
        : (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.14));
    final focusBorderColor =
        isAuthError ? const Color(0xFFE05638) : cs.primary;

    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontSize: 12,
        color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      ),
      filled: true,
      fillColor: fillColor,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      prefixIcon: Icon(prefixIcon, size: 15, color: cs.onSurfaceVariant),
      prefixIconConstraints:
          const BoxConstraints(minWidth: 32, maxHeight: 34),
      suffixIcon: suffixIcon,
      suffixIconConstraints: suffixIconConstraints,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: baseBorderColor, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: baseBorderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: focusBorderColor, width: 1),
      ),
    );
  }

  Widget _credentialsToggleChip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final username = _usernameCtrl.text.trim();
    final active = _credentialsExpanded;
    final fg = active ? cs.primary : cs.onSurfaceVariant;
    final bg = active
        ? cs.primary.withValues(alpha: 0.14)
        : cs.onSurface.withValues(alpha: 0.04);
    final border = active
        ? cs.primary.withValues(alpha: 0.45)
        : cs.outline.withValues(alpha: 0.35);

    return Tooltip(
      message: tl(context, 'Credentials'),
      child: InkWell(
        key: Key('credentials-toggle-${widget.item.id}'),
        borderRadius: BorderRadius.circular(6),
        onTap: _toggleCredentialsExpanded,
        child: Container(
          height: 26,
          padding:
              EdgeInsets.symmetric(horizontal: username.isNotEmpty ? 8 : 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.key_rounded, size: 13, color: fg),
              if (username.isNotEmpty) ...[
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 88),
                  child: Text(
                    username,
                    style: TextStyle(fontSize: 11, color: fg),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineCredentialsStrip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final item = widget.item;
    final isAuthError = _state == TestState.authError;
    const authErrorColor = Color(0xFFE05638);
    const accentBlue = Color(0xFF2563EB);

    final lockedFill = isDark
        ? (widget.selected
            ? Colors.black.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.04))
        : (widget.selected
            ? Colors.black.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.02));
    final lockedBorder = isAuthError
        ? authErrorColor.withValues(alpha: 0.75)
        : (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.14));

    final usernameField = SizedBox(
      height: 34,
      child: TextField(
        key: Key('inline-username-${item.id}'),
        controller: _usernameCtrl,
        style: const TextStyle(fontSize: 12.5, height: 1.2),
        textAlignVertical: TextAlignVertical.center,
        decoration: _inlineInputDecoration(
          context,
          hintText: tl(context, 'Username'),
          prefixIcon: Icons.person_outline,
          isAuthError: isAuthError,
        ),
        textInputAction: TextInputAction.done,
        onChanged: (_) => _usernameDirty = true,
        onSubmitted: (_) => _saveAndTest(),
      ),
    );

    final Widget passwordField = _isLockedView
        ? SizedBox(
            height: 34,
            child: Container(
              key: Key('inline-password-locked-${item.id}'),
              decoration: BoxDecoration(
                color: lockedFill,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: lockedBorder, width: 1),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 34,
                    child: Center(
                      child: Icon(
                        Icons.lock_outline,
                        size: 15,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      '••••••••••',
                      style: TextStyle(fontSize: 12.5, letterSpacing: 1.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    key: Key('inline-retype-${item.id}'),
                    onPressed: _startRetype,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      tl(context, 'Retype'),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          )
        : SizedBox(
            height: 34,
            child: TextField(
              key: Key('inline-password-${item.id}'),
              controller: _passwordCtrl,
              focusNode: _passwordFocus,
              obscureText: _obscurePassword,
              style: const TextStyle(fontSize: 12.5, height: 1.2),
              textAlignVertical: TextAlignVertical.center,
              decoration: _inlineInputDecoration(
                context,
                hintText: tl(context, 'Password'),
                prefixIcon: Icons.lock_outline,
                isAuthError: isAuthError,
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 30, maxHeight: 34),
                suffixIcon: Tooltip(
                  message: tl(context, _obscurePassword ? 'Show' : 'Hide'),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: InkWell(
                      key: Key('inline-password-toggle-${item.id}'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      child: SizedBox(
                        width: 30,
                        height: 34,
                        child: Center(
                          child: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 15,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              textInputAction: TextInputAction.done,
              onChanged: (_) => _passwordDirty = true,
              onSubmitted: (_) => _saveAndTest(),
            ),
          );

    final saveButton = SizedBox(
      height: 34,
      child: FilledButton(
        key: Key('inline-save-test-${item.id}'),
        onPressed: (widget.coreManager == null ||
                _isSavingCredentials ||
                _state == TestState.testing)
            ? null
            : _saveAndTest,
        style: FilledButton.styleFrom(
          backgroundColor: accentBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: _isSavingCredentials
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                tl(context, 'Save & Test'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
      ),
    );

    return Column(
      key: Key('inline-auth-strip-${item.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 1,
          margin: const EdgeInsets.only(left: 36, right: 12),
          color: isAuthError
              ? authErrorColor.withValues(alpha: 0.35)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08)),
        ),
        Container(
          color: isAuthError
              ? authErrorColor.withValues(alpha: 0.06)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(36, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAuthError) ...[
                Row(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 14, color: authErrorColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tl(context, 'Invalid username or password'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: authErrorColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 360) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: usernameField),
                            const SizedBox(width: 8),
                            Expanded(child: passwordField),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: saveButton,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(flex: 3, child: usernameField),
                      const SizedBox(width: 8),
                      Expanded(flex: 4, child: passwordField),
                      const SizedBox(width: 8),
                      saveButton,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
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

    final headerRow = InkWell(
      // Whole-row select — the core fix. Tapping anywhere that isn't an
      // explicit action control (Test button / result chip / ⋯ menu)
      // selects this proxy.
      onTap: widget.onSelect == null ? null : () => widget.onSelect!(item.id),
      child: Padding(
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
                if (_errorMessage.isNotEmpty &&
                    (_state == TestState.unreachable ||
                     _state == TestState.authError ||
                     _state == TestState.certError)) ...[
                  const SizedBox(height: 2),
                  Tooltip(
                    message: _errorMessage,
                    child: Text(
                      _errorMessage,
                      style: TextStyle(
                        fontSize: 9.5,
                        color: _state == TestState.certError
                            ? const Color(0xFFE0A31E)
                            : cs.error,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
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
            // Explicit, labeled PAC Rules button
            if ((item.pacUrl ?? '').isNotEmpty) ...[
              SizedBox(
                height: 26,
                child: OutlinedButton(
                  onPressed: _openPacRules,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 26),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: cs.outline.withAlpha(100)),
                    foregroundColor: cs.onSurfaceVariant,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.alt_route, size: 12),
                      const SizedBox(width: 4),
                      Text(tl(context, 'PAC'),
                          style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            // Credentials toggle chip (available on every HTTP/SOCKS5/PAC proxy)
            if (_supportsCredentials) ...[
              _credentialsToggleChip(context),
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
            hasPac: (item.pacUrl ?? '').isNotEmpty,
          ),
        ]),
      ),
    );

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: titleText,
      child: Material(
        color: selected ? cs.primaryContainer.withAlpha(90) : Colors.transparent,
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
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headerRow,
              if (_credentialsExpanded && _supportsCredentials)
                _buildInlineCredentialsStrip(context),
            ],
          ),
        ]),
      ),
    );
  }
}
