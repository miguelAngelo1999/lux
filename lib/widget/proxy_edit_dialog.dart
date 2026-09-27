import 'package:flutter/material.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/core/core_config.dart';

/// Dialog for creating or editing a proxy configuration.
/// Supports HTTP, SOCKS5, and Shadowsocks proxy types.
///
/// Password model (per product requirements):
///  - A NEW password (creating a proxy, or retyping an existing one) is the
///    user's own fresh input, so it is freely revealable while typing — no
///    admin auth needed.
///  - Once a password is SAVED, it is not editable. The field shows a locked
///    placeholder and a "Retype password" button. The stored password is never
///    shown back.
///  - Pressing "Retype password" clears the field and re-enters typing mode,
///    freely revealable again.
///  - Pressing Enter in the password field saves and closes the dialog.
class ProxyEditDialog extends StatefulWidget {
  final CoreManager coreManager;
  final ProxyDetail? initialValue; // null = create new
  final VoidCallback onSaved;

  /// When true the dialog opens focused on the password field and shows a
  /// banner explaining the current password no longer authenticates. Used by
  /// the credential-expiry flow.
  final bool focusPasswordForReauth;

  const ProxyEditDialog({
    super.key,
    required this.coreManager,
    this.initialValue,
    required this.onSaved,
    this.focusPasswordForReauth = false,
  });

  @override
  State<ProxyEditDialog> createState() => _ProxyEditDialogState();
}

class _ProxyEditDialogState extends State<ProxyEditDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode();

  late String _name;
  late String _server;
  late int _port;
  late String _username;
  late String _type;
  late String _passwordMode;
  late int _passwordTTLMinutes;
  late String _pacUrl;

  bool _isLoading = false;
  bool _obscurePassword = true;

  // Whether the user is entering a fresh password right now. New proxy = always
  // true. Existing proxy = false until the user hits "Retype password".
  bool _retyping = false;
  // Whether the existing (edited) proxy already has a stored password.
  bool _hasStoredPassword = false;

  bool get isEditing => widget.initialValue != null;

  @override
  void initState() {
    super.initState();
    final iv = widget.initialValue;
    _name = iv?.name ?? '';
    _server = iv?.server ?? '';
    _port = iv?.port ?? 1080;
    _username = iv?.raw['username'] as String? ?? '';
    _type = iv?.type ?? 'http';
    _passwordMode = iv?.raw['passwordMode'] as String? ?? 'persistent';
    _passwordTTLMinutes = (iv?.raw['passwordTTLMinutes'] as num?)?.toInt() ?? 60;
    _pacUrl = iv?.raw['pacUrl'] as String? ?? '';

    _hasStoredPassword = isEditing && (iv?.password ?? '').isNotEmpty;
    // New proxy → typing from the start. Existing proxy with a stored password
    // → locked until the user chooses to retype. Existing proxy WITHOUT a
    // stored password → typing from the start.
    _retyping = !_hasStoredPassword;

    // Re-auth flow: force retype mode and focus the password field.
    if (widget.focusPasswordForReauth) {
      _retyping = true;
      _passwordCtrl.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passwordFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Begin retyping the password from scratch: clear the field, enter typing
  /// mode (freely revealable), and focus it.
  void _startRetype() {
    setState(() {
      _retyping = true;
      _obscurePassword = true;
      _passwordCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocus.requestFocus();
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isLoading = true);

    try {
      final proxyData = <String, dynamic>{
        'name': _name,
        'server': _server,
        'port': _port,
        'username': _username,
        'type': _type,
        'passwordMode': _passwordMode,
        if (_pacUrl.isNotEmpty) 'pacUrl': _pacUrl,
      };

      // Only send the password when the user actually typed a new one. If they
      // left an existing proxy's password untouched (not retyping), omit it so
      // the stored value is preserved.
      if (_retyping) {
        proxyData['password'] = _passwordCtrl.text;
      } else if (isEditing) {
        proxyData['password'] = widget.initialValue!.password ?? '';
      } else {
        proxyData['password'] = '';
      }

      if (_passwordMode == 'timed') {
        proxyData['passwordTTLMinutes'] = _passwordTTLMinutes;
      }

      if (isEditing) {
        proxyData['id'] = widget.initialValue!.id;
        await widget.coreManager.updateProxy(widget.initialValue!.id, proxyData);
      } else {
        await widget.coreManager.addProxy(proxyData);
      }

      if (mounted) {
        widget.onSaved();
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildPasswordField() {
    // Locked view: existing stored password, not retyping. Show a masked
    // placeholder that cannot be edited, plus a "Retype password" action.
    if (!_retyping) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: tl(context, 'Password'),
          suffixIcon: TextButton(
            onPressed: _startRetype,
            child: TText('Retype', style: const TextStyle(fontSize: 12)),
          ),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text('••••••••••',
                  style: TextStyle(fontSize: 16, letterSpacing: 2)),
            ),
            const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
          ],
        ),
      );
    }

    // Typing view: the user is entering a fresh password → freely revealable,
    // no admin auth. Enter saves and closes.
    return TextFormField(
      controller: _passwordCtrl,
      focusNode: _passwordFocus,
      decoration: InputDecoration(
        labelText: tl(context, 'Password (optional)'),
        helperText: _hasStoredPassword
            ? tl(context, 'Type the new password')
            : null,
        suffixIcon: IconButton(
          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
          tooltip: _obscurePassword ? 'Show' : 'Hide',
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      obscureText: _obscurePassword,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _save(), // Enter saves + closes
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 450, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEditing ? 'Edit Proxy' : 'Create Proxy',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (widget.focusPasswordForReauth) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      border: Border.all(color: Colors.orange.shade600),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(children: [
                      Icon(Icons.key_off, size: 16, color: Colors.orange),
                      SizedBox(width: 6),
                      Flexible(
                        child: TText(
                          'The current password no longer authenticates. '
                          'Enter a new one to reconnect.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<String>(
                          value: _type,
                          decoration: InputDecoration(labelText: tl(context, 'Type')),
                          items: const [
                            DropdownMenuItem(value: 'http', child: TText('HTTP')),
                            DropdownMenuItem(value: 'socks5', child: TText('SOCKS5')),
                            DropdownMenuItem(value: 'ss', child: TText('Shadowsocks')),
                          ],
                          onChanged: isEditing ? null : (v) => setState(() => _type = v!),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: _name,
                          decoration: InputDecoration(labelText: tl(context, 'Name')),
                          onSaved: (v) => _name = v ?? '',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: _server,
                          decoration: InputDecoration(labelText: tl(context, 'Server')),
                          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                          onSaved: (v) => _server = v ?? '',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: _port.toString(),
                          decoration: InputDecoration(labelText: tl(context, 'Port')),
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            final p = int.tryParse(v ?? '');
                            if (p == null || p < 1 || p > 65535) return 'Invalid port';
                            return null;
                          },
                          onSaved: (v) => _port = int.tryParse(v ?? '') ?? 1080,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: _pacUrl,
                          decoration: InputDecoration(
                            labelText: tl(context, 'PAC URL (optional)'),
                            hintText: 'http://proxy.company.com/proxy.pac',
                            helperText: tl(context, 'Auto-config script to decide when to use this proxy'),
                            helperMaxLines: 2,
                          ),
                          keyboardType: TextInputType.url,
                          onSaved: (v) => _pacUrl = v?.trim() ?? '',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: _username,
                          decoration: InputDecoration(labelText: tl(context, 'Username (optional)')),
                          onSaved: (v) => _username = v ?? '',
                        ),
                        const SizedBox(height: 12),
                        _buildPasswordField(),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _passwordMode,
                          decoration: InputDecoration(labelText: tl(context, 'Password Mode')),
                          items: const [
                            DropdownMenuItem(value: 'persistent', child: TText('Persistent')),
                            DropdownMenuItem(value: 'one-time', child: TText('One-time (clears on switch)')),
                            DropdownMenuItem(value: 'timed', child: TText('Timed (auto-expires)')),
                          ],
                          onChanged: (v) => setState(() => _passwordMode = v!),
                        ),
                        if (_passwordMode == 'timed') ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            initialValue: _passwordTTLMinutes.toString(),
                            decoration: InputDecoration(
                              labelText: tl(context, 'Expires after (minutes)'),
                            ),
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              final m = int.tryParse(v ?? '');
                              if (m == null || m < 1) return 'Must be at least 1 minute';
                              return null;
                            },
                            onSaved: (v) => _passwordTTLMinutes = int.tryParse(v ?? '') ?? 60,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                      child: const TText('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isLoading ? null : _save,
                      child: _isLoading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : TText(isEditing ? 'Save' : 'Create'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
