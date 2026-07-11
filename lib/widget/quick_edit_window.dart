import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/elevation_helper.dart';
import 'package:window_manager/window_manager.dart';
import 'package:lux/util/t_text.dart';

/// A compact credential editor that appears as a floating panel near the menubar.
/// Shows profile selector + username + password fields.
class QuickEditWindow extends StatefulWidget {
  final CoreManager coreManager;
  final VoidCallback onDone;

  const QuickEditWindow({
    super.key,
    required this.coreManager,
    required this.onDone,
  });

  @override
  State<QuickEditWindow> createState() => _QuickEditWindowState();
}

class _QuickEditWindowState extends State<QuickEditWindow> {
  List<ProxyItem> _proxies = [];
  String _selectedId = '';
  String _username = '';
  String _password = '';
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final list = await widget.coreManager.getProxyList();
      final proxies = list.proxies
          .where((p) => p.type != 'direct')
          .toList();
      String selectedId = list.id;
      // Fall back to first non-direct proxy
      if (proxies.isNotEmpty &&
          !proxies.any((p) => p.id == selectedId)) {
        selectedId = proxies.first.id;
      }
      setState(() {
        _proxies = proxies;
        _selectedId = selectedId;
        _isLoading = false;
      });
      await _loadProxyDetail(selectedId);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadProxyDetail(String id) async {
    try {
      final detail = await widget.coreManager.getProxyDetail(id);
      if (detail != null && mounted) {
        setState(() {
          _username = detail.raw['username'] as String? ?? '';
          _password = detail.password ?? '';
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final detail = await widget.coreManager.getProxyDetail(_selectedId);
      if (detail == null) throw Exception('Proxy not found');
      final updated = Map<String, dynamic>.from(detail.raw);
      updated['username'] = _username;
      updated['password'] = _password;
      await widget.coreManager.updateProxy(_selectedId, updated);
      widget.onDone();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF2C2C2E)
              : const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title bar (draggable)
            GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF3A3A3C)
                      : const Color(0xFFE5E5EA),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.vpn_key_outlined, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Edit Credentials',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    GestureDetector(
                      onTap: widget.onDone,
                      child: const Icon(Icons.close, size: 16),
                    ),
                  ],
                ),
              ),
            ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Profile selector — shows active proxy name with tick mark
                    DropdownButtonFormField<String>(
                      value: _selectedId.isEmpty ? null : _selectedId,
                      decoration: _inputDecoration('Profile', isDark),
                      isDense: true,
                      hint: TText('Select profile', style: TextStyle(fontSize: 13)),
                      selectedItemBuilder: (ctx) => _proxies.map((p) {
                        // Show name + active indicator when dropdown is closed
                        final isActive = p.id == _selectedId;
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            isActive ? '${p.name}' : p.name,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      items: _proxies
                          .map((p) {
                            final isActive = p.id == _selectedId;
                            return DropdownMenuItem(
                              value: p.id,
                              child: Row(children: [
                                if (isActive)
                                  const Icon(Icons.check, size: 14, color: Colors.blue)
                                else
                                  const SizedBox(width: 14),
                                const SizedBox(width: 6),
                                Text(p.name, style: const TextStyle(fontSize: 13)),
                              ]),
                            );
                          })
                          .toList(),
                      onChanged: (id) {
                        if (id != null) {
                          setState(() => _selectedId = id);
                          _loadProxyDetail(id);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    // Username
                    TextFormField(
                      initialValue: _username,
                      decoration: _inputDecoration('Username', isDark),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (v) => _username = v,
                    ),
                    const SizedBox(height: 10),
                    // Password
                    TextFormField(
                      initialValue: _password,
                      obscureText: _obscurePassword,
                      decoration: _inputDecoration('Password', isDark).copyWith(
                        suffixIcon: GestureDetector(
                          onTap: () async {
                            if (_obscurePassword) {
                              final ok = await ElevationHelper.requestElevation(
                                message: 'Authenticate to reveal proxy password',
                                context: context,
                              );
                              if (ok) setState(() => _obscurePassword = false);
                            } else {
                              setState(() => _obscurePassword = true);
                            }
                          },
                          child: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 16,
                          ),
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (v) => _password = v,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: widget.onDone,
                            style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                            child: TText('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: _isSaving ? null : _save,
                            style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                            child: _isSaving
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white),
                                  )
                                : TText('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, bool isDark) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12),
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      filled: true,
      fillColor: isDark
          ? const Color(0xFF48484A)
          : const Color(0xFFFFFFFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide.none,
      ),
    );
  }
}
