import 'package:flutter/material.dart';
import 'package:lux/theme.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/pac_rules_dialog.dart';
import 'package:lux/widget/password_peek_dialog.dart';
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
  final Future<void> Function(ProxyItem item)? onPeekPassword;

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
    this.onPeekPassword,
  });

  @override
  State<ProxyListItem> createState() => _ProxyListItemState();
}

class _ProxyListItemState extends State<ProxyListItem> {
  final menuController = MenuController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _usernameFocus = FocusNode();
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
  bool _hasStoredPassword = false;
  bool _effectivePasswordLocked = false;
  String _effectivePasswordMode = 'persistent';
  bool _detailLoaded = false;
  bool _credentialsExpanded = false;
  List<String> _recentUsernames = const [];

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

  bool get _isLockedView => _hasStoredPassword && !_retyping;

  bool get _isPasswordNonRevealable =>
      _effectivePasswordLocked ||
      _effectivePasswordMode == 'one-time' ||
      _effectivePasswordMode == 'timed';

  ProxyTestStatus get _currentStatus => ProxyTestStatus(
        state: _state,
        latencyMs: _latencyMs,
        pacReachable: _pacReachable,
        errorMessage: _errorMessage,
      );

  @override
  void initState() {
    super.initState();
    // All cards (including selected) start collapsed by default.
    _credentialsExpanded = false;
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
      _obscurePassword = true;
      _detailLoaded = false;
      _credentialsExpanded = false;
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
        if (widget.item.passwordMode != null) {
          _effectivePasswordMode = widget.item.passwordMode!;
        }
      }
      final itemHasStored =
          widget.item.passwordLocked || (widget.item.password ?? '').isNotEmpty;
      if (!_passwordDirty && !_retyping && itemHasStored) {
        _hasStoredPassword = true;
      }
    }

    if (widget.selected && !oldWidget.selected) {
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
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _syncInitialCredentials() {
    _effectivePasswordLocked = widget.item.passwordLocked;
    _effectivePasswordMode = widget.item.passwordMode ?? 'persistent';
    _hasStoredPassword =
        _effectivePasswordLocked || (widget.item.password ?? '').isNotEmpty;
    _retyping = !_hasStoredPassword;
    _obscurePassword = true;
    _usernameCtrl.text = widget.item.username ?? '';
    // Never load a stored password into _passwordCtrl.
    _passwordCtrl.clear();
    _loadRecentUsernames();
  }

  Future<void> _loadRecentUsernames() async {
    if (!_supportsCredentials) return;
    final list = await readRecentUsernames(widget.item.id);
    if (!mounted) return;
    if (list.isNotEmpty) {
      setState(() => _recentUsernames = list);
    }
  }

  void _pickRecentUsername(String username) {
    final changed = _usernameCtrl.text.trim() != username;
    setState(() {
      _usernameCtrl.text = username;
      _usernameDirty = true;
    });
    if (changed) {
      // Swapping to another account on a shared laptop -> immediately open &
      // focus the password box so they just type their password and hit Enter.
      if (_isLockedView) {
        _startRetype();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _passwordFocus.requestFocus();
        });
      }
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
    final mode = (detail.raw['passwordMode'] as String?) ??
        widget.item.passwordMode ??
        'persistent';
    final remoteUser = (detail.raw['username'] as String?) ?? '';
    final remotePass = detail.password ?? '';
    final hasStored = locked || remotePass.isNotEmpty;
    setState(() {
      _effectivePasswordLocked = locked;
      _effectivePasswordMode = mode;
      _hasStoredPassword = hasStored;
      if (!_passwordDirty) {
        _retyping = !hasStored;
        if (!_retyping) {
          // Keep stored password out of _passwordCtrl at all times.
          _passwordCtrl.clear();
        }
      }
      if (!_usernameDirty && remoteUser.isNotEmpty) {
        _usernameCtrl.text = remoteUser;
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
      if (_retyping) {
        updated['password'] = _passwordCtrl.text;
        if (_passwordCtrl.text.isNotEmpty) {
          updated.remove('passwordLocked');
        }
      }

      await widget.coreManager!.updateProxy(widget.item.id, updated);
      if (trimmedUsername.isNotEmpty) {
        final updatedRecent =
            await recordRecentUsername(widget.item.id, trimmedUsername);
        if (mounted) {
          _recentUsernames = updatedRecent;
        }
      }
      if (!mounted) return;
      final savedNewPassword = _retyping && _passwordCtrl.text.isNotEmpty;
      setState(() {
        _usernameDirty = false;
        _passwordDirty = false;
        if (savedNewPassword) {
          // Immediately lock after saving so the stored password is never left in the controller.
          _hasStoredPassword = true;
          _effectivePasswordLocked = false;
          _retyping = false;
          _obscurePassword = true;
          _passwordCtrl.clear();
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
    final tokens = LuxTokens.of(context);
    Color fg, bg;
    String text;
    bool tappable = false;
    LuxGlyph glyph;
    switch (_state) {
      case TestState.untested:
        return const SizedBox.shrink(); // nothing until tested
      case TestState.testing:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.4,
            color: tokens.cobalt,
          ),
        );
      case TestState.reachable:
        fg = _pacReachable ? tokens.teal : tokens.emerald;
        bg = fg.withValues(alpha: 0.11);
        glyph = LuxGlyph.check;
        text = _pacReachable ? 'PAC OK' : '$_latencyMs ms';
        if (_pacReachable) tappable = true;
        break;
      case TestState.unreachable:
        fg = tokens.danger;
        bg = fg.withValues(alpha: 0.11);
        glyph = LuxGlyph.alertCircle;
        text = tl(context, 'Unreachable');
        break;
      case TestState.authError:
        fg = tokens.danger;
        bg = fg.withValues(alpha: 0.11);
        glyph = LuxGlyph.lock;
        text = tl(context, 'Invalid username or password');
        break;
      case TestState.certError:
        fg = tokens.amber;
        bg = fg.withValues(alpha: 0.12);
        glyph = LuxGlyph.shieldAlert;
        text = tl(context, 'Certificate Untrusted');
        tappable = true;
        break;
      case TestState.notApplicable:
        fg = tokens.textMuted;
        bg = tokens.subtlePillBg;
        glyph = LuxGlyph.route;
        text = tl(context, 'PAC — n/a');
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
          border: Border.all(color: fg.withValues(alpha: 0.18), width: 0.75),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          LuxIcon(glyph, size: 11.5, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: _state == TestState.reachable && !_pacReachable
                ? luxMonoStyle(fontSize: 10.5, color: fg)
                : TextStyle(fontSize: 10.5, fontWeight: FontWeight.w400, color: fg),
          ),
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

  Widget _inlineFieldShell(
    BuildContext context, {
    Key? boxKey,
    FocusNode? focusNode,
    required LuxGlyph prefixGlyph,
    required Widget child,
    Widget? trailing,
    bool isAuthError = false,
  }) {
    final tokens = LuxTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = isDark
        ? Colors.black.withValues(alpha: 0.24)
        : Colors.white.withValues(alpha: 0.85);
    final baseBorderColor = isAuthError
        ? tokens.danger.withValues(alpha: 0.7)
        : tokens.hairlineStrong;
    final focusBorderColor = isAuthError ? tokens.danger : tokens.cobalt;

    Widget buildShell(bool hasFocus) {
      return SizedBox(
        key: boxKey,
        height: 34,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hasFocus ? focusBorderColor : baseBorderColor,
              width: hasFocus ? 1.0 : 0.75,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                height: 34,
                child: Center(
                  child: LuxIcon(
                    prefixGlyph,
                    size: 13.5,
                    color: tokens.textMuted,
                  ),
                ),
              ),
              Expanded(child: child),
              if (trailing != null) trailing else const SizedBox(width: 8),
            ],
          ),
        ),
      );
    }

    if (focusNode == null) {
      return buildShell(false);
    }
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) => buildShell(focusNode.hasFocus),
    );
  }

  InputDecoration _collapsedFieldDecoration(
    BuildContext context, {
    required String hintText,
  }) {
    final tokens = LuxTokens.of(context);
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: tokens.textMuted,
      ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _credentialsToggleButton(BuildContext context) {
    final tokens = LuxTokens.of(context);

    return Tooltip(
      message: tl(context, 'Credentials'),
      child: InkWell(
        key: Key('credentials-toggle-${widget.item.id}'),
        borderRadius: BorderRadius.circular(7),
        onTap: _toggleCredentialsExpanded,
        child: Container(
          height: 26,
          padding: EdgeInsets.symmetric(horizontal: _credentialsExpanded ? 7 : 6),
          decoration: BoxDecoration(
            color: _credentialsExpanded
                ? tokens.cobalt.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: _credentialsExpanded
                  ? tokens.cobalt.withValues(alpha: 0.28)
                  : Colors.transparent,
              width: 0.75,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LuxIcon(
                LuxGlyph.key,
                size: 13.5,
                color: _credentialsExpanded ? tokens.cobalt : tokens.textMuted,
              ),
              if (_credentialsExpanded) ...[
                const SizedBox(width: 3),
                LuxIcon(
                  LuxGlyph.chevronUp,
                  size: 11.5,
                  color: tokens.cobalt,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget? _buildUsernameHistoryDropdown(BuildContext context, LuxTokens tokens) {
    final current = _usernameCtrl.text.trim();
    final options = <String>[
      ..._recentUsernames,
      if (current.isNotEmpty && !_recentUsernames.contains(current)) current,
    ];
    if (options.isEmpty) return null;

    return Tooltip(
      message: tl(context, 'Switch user'),
      child: PopupMenuButton<String>(
        key: Key('inline-username-history-${widget.item.id}'),
        tooltip: '',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 160),
        onSelected: _pickRecentUsername,
        itemBuilder: (ctx) => [
          for (final user in options)
            PopupMenuItem<String>(
              value: user,
              height: 34,
              child: Row(
                children: [
                  LuxIcon(
                    LuxGlyph.person,
                    size: 13,
                    color: user == current ? tokens.cobalt : tokens.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      user,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            user == current ? FontWeight.w500 : FontWeight.w400,
                        color: tokens.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (user == current) ...[
                    const SizedBox(width: 6),
                    LuxIcon(LuxGlyph.check, size: 12, color: tokens.cobalt),
                  ],
                ],
              ),
            ),
        ],
        child: SizedBox(
          width: 26,
          height: 34,
          child: Center(
            child: LuxIcon(
              LuxGlyph.chevronDown,
              size: 12.5,
              color: tokens.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineCredentialsStrip(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final item = widget.item;
    final isAuthError = _state == TestState.authError;

    final usernameField = _inlineFieldShell(
      context,
      focusNode: _usernameFocus,
      prefixGlyph: LuxGlyph.person,
      isAuthError: isAuthError,
      trailing: _buildUsernameHistoryDropdown(context, tokens),
      child: SizedBox(
        height: 34,
        child: TextField(
          key: Key('inline-username-${item.id}'),
          controller: _usernameCtrl,
          focusNode: _usernameFocus,
          style: TextStyle(
            fontSize: 12,
            height: 1.2,
            fontWeight: FontWeight.w400,
            color: tokens.textPrimary,
          ),
          textAlignVertical: TextAlignVertical.center,
          maxLines: 1,
          expands: false,
          decoration: _collapsedFieldDecoration(
            context,
            hintText: tl(context, 'Username'),
          ),
          textInputAction: TextInputAction.done,
          onChanged: (_) => _usernameDirty = true,
          onSubmitted: (_) => _saveAndTest(),
        ),
      ),
    );

    final Widget passwordField = _isLockedView
        ? _inlineFieldShell(
            context,
            boxKey: Key('inline-password-locked-${item.id}'),
            prefixGlyph: LuxGlyph.lock,
            isAuthError: isAuthError,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '••••••••••••',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.4,
                  color: tokens.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isPasswordNonRevealable)
                  Tooltip(
                    message: tl(context, 'Show'),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: InkWell(
                        key: Key('inline-password-peek-${item.id}'),
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          if (widget.onPeekPassword != null) {
                            widget.onPeekPassword!(widget.item);
                          } else if (widget.coreManager != null) {
                            showPasswordPeekDialog(
                              context: context,
                              coreManager: widget.coreManager!,
                              proxyItem: widget.item,
                            );
                          }
                        },
                        child: SizedBox(
                          width: 28,
                          height: 34,
                          child: Center(
                            child: LuxIcon(
                              LuxGlyph.eye,
                              size: 13.5,
                              color: tokens.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                TextButton(
                  key: Key('inline-retype-${item.id}'),
                  onPressed: _startRetype,
                  style: TextButton.styleFrom(
                    foregroundColor: tokens.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    tl(context, 'Retype'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          )
        : _inlineFieldShell(
            context,
            focusNode: _passwordFocus,
            prefixGlyph: LuxGlyph.lock,
            isAuthError: isAuthError,
            child: SizedBox(
              height: 34,
              child: TextField(
                key: Key('inline-password-${item.id}'),
                controller: _passwordCtrl,
                focusNode: _passwordFocus,
                obscureText: _obscurePassword,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w400,
                  color: tokens.textPrimary,
                ),
                textAlignVertical: TextAlignVertical.center,
                maxLines: 1,
                expands: false,
                decoration: _collapsedFieldDecoration(
                  context,
                  hintText: tl(context, 'Password'),
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) => _passwordDirty = true,
                onSubmitted: (_) => _saveAndTest(),
              ),
            ),
            trailing: Tooltip(
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
                      child: LuxIcon(
                        _obscurePassword ? LuxGlyph.eyeOff : LuxGlyph.eye,
                        size: 13.5,
                        color: tokens.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
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
          backgroundColor: const Color(0xFF2563EB),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          minimumSize: const Size(0, 34),
          maximumSize: const Size(double.infinity, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: _isSavingCredentials
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LuxIcon(LuxGlyph.check, size: 12.5, color: Colors.white),
                  const SizedBox(width: 5),
                  Text(
                    tl(context, 'Save & Test'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
      ),
    );

    return Column(
      key: Key('inline-auth-strip-${item.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 0.75,
          margin: const EdgeInsets.only(left: 38, right: 14),
          color: isAuthError
              ? tokens.danger.withValues(alpha: 0.32)
              : tokens.hairline,
        ),
        Container(
          color: isAuthError
              ? tokens.danger.withValues(alpha: 0.05)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(38, 9, 14, 11),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAuthError) ...[
                Row(
                  children: [
                    LuxIcon(LuxGlyph.alertCircle, size: 13, color: tokens.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tl(context, 'Invalid username or password'),
                        style: TextStyle(
                          fontSize: 11,
                          color: tokens.danger,
                          fontWeight: FontWeight.w500,
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
    final tokens = LuxTokens.of(context);
    final selected = widget.selected;
    final subtitleUsername = _usernameCtrl.text.trim();

    final titleText = item.name.isNotEmpty
        ? item.name
        : '${item.server ?? ''}:${item.port ?? ''}';

    final headerRow = LayoutBuilder(
      builder: (context, constraints) {
        final compactRow = constraints.maxWidth < 470;
        final ultraCompact = constraints.maxWidth < 410;
        return InkWell(
          onTap:
              widget.onSelect == null ? null : () => widget.onSelect!(item.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              // Leading radio (inherits ancestor RadioGroup for keyboard support).
              Transform.scale(
                scale: 0.85,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Radio<String>(value: item.id),
                ),
              ),
              const SizedBox(width: 6),
              // Name + metadata row
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
                                selected ? FontWeight.w500 : FontWeight.w400,
                            color: tokens.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: tokens.emerald.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            tl(context, 'Active'),
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w500,
                              color: tokens.emerald,
                            ),
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5.5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: tokens.subtlePillBg,
                          borderRadius: BorderRadius.circular(4),
                          border:
                              Border.all(color: tokens.hairline, width: 0.5),
                        ),
                        child: Text(
                          _typeLabel(item.type),
                          style: luxMonoStyle(
                            fontSize: 9.5,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                      if (item.server != null && item.server!.isNotEmpty) ...[
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            '${item.server}:${item.port}',
                            style: luxMonoStyle(
                              fontSize: 10.5,
                              color: tokens.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      if (_supportsCredentials &&
                          subtitleUsername.isNotEmpty &&
                          !_credentialsExpanded) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: InkWell(
                              key: Key('subtitle-username-${item.id}'),
                              borderRadius: BorderRadius.circular(6),
                              onTap: _toggleCredentialsExpanded,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: tokens.subtlePillBg,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    LuxIcon(
                                      LuxGlyph.person,
                                      size: 11,
                                      color: tokens.textMuted,
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        subtitleUsername,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w400,
                                          color: tokens.textSecondary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ]),
                    if (_errorMessage.isNotEmpty &&
                        (_state == TestState.unreachable ||
                            _state == TestState.authError ||
                            _state == TestState.certError)) ...[
                      const SizedBox(height: 3),
                      Tooltip(
                        message: _errorMessage,
                        child: Text(
                          _errorMessage,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            color: _state == TestState.certError
                                ? tokens.amber
                                : tokens.danger,
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
                if (_state == TestState.certError) ...[
                  SizedBox(
                    height: 26,
                    child: OutlinedButton(
                      onPressed: _promptCertTrust,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 26),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(
                            color: tokens.amber.withValues(alpha: 0.7),
                            width: 0.75),
                        foregroundColor: tokens.amber,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(7)),
                      ),
                      child: Text(
                        tl(context, 'Trust'),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w400),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                if ((item.pacUrl ?? '').isNotEmpty) ...[
                  Tooltip(
                    message: tl(context, 'PAC'),
                    child: SizedBox(
                      height: 26,
                      width: ultraCompact ? 28 : null,
                      child: OutlinedButton(
                        onPressed: _openPacRules,
                        style: OutlinedButton.styleFrom(
                          padding: ultraCompact
                              ? EdgeInsets.zero
                              : const EdgeInsets.symmetric(horizontal: 7),
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: BorderSide(
                              color: tokens.hairlineStrong, width: 0.75),
                          foregroundColor: tokens.textSecondary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            LuxIcon(LuxGlyph.route,
                                size: 11.5, color: tokens.textSecondary),
                            if (!ultraCompact) ...[
                              const SizedBox(width: 4),
                              Text(
                                tl(context, 'PAC'),
                                style: const TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w400),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                if (_supportsCredentials) ...[
                  _credentialsToggleButton(context),
                  const SizedBox(width: 5),
                ],
                Tooltip(
                  message: tl(context, 'Test'),
                  child: SizedBox(
                    height: 26,
                    width: compactRow ? 28 : null,
                    child: OutlinedButton(
                      onPressed:
                          _state == TestState.testing ? null : _testDelay,
                      style: OutlinedButton.styleFrom(
                        padding: compactRow
                            ? EdgeInsets.zero
                            : const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 26),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: BorderSide(
                            color: tokens.hairlineStrong, width: 0.75),
                        foregroundColor: tokens.textPrimary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(7)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          LuxIcon(LuxGlyph.bolt,
                              size: 11.5, color: tokens.cobalt),
                          if (!compactRow) ...[
                            const SizedBox(width: 3),
                            Text(
                              tl(context, 'Test'),
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w400),
                            ),
                          ],
                        ],
                      ),
                    ),
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
      },
    );

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: titleText,
      child: Material(
        color: selected ? tokens.cardBgSelected : Colors.transparent,
        child: Stack(children: [
          if (selected)
            Positioned(
              left: 0,
              top: 8,
              bottom: 8,
              child: Container(
                width: 2.5,
                decoration: BoxDecoration(
                  color: tokens.cobalt,
                  borderRadius: BorderRadius.circular(2),
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
