import 'package:flutter/material.dart';
import 'package:lux/widget/proxy_item_action_menu.dart';
import 'package:lux/util/t_text.dart';

import '../const/const.dart';
import '../core/core_config.dart';
import '../core/core_manager.dart';

class ProxyListItem extends StatefulWidget {
  final ProxyItem item;
  final void Function(ProxyItemAction action) onChange;
  final CoreManager? coreManager;

  const ProxyListItem({
    super.key,
    required this.item,
    required this.onChange,
    this.coreManager,
  });

  @override
  State<ProxyListItem> createState() => _ProxyListItemState();
}

class _ProxyListItemState extends State<ProxyListItem> {
  final menuController = MenuController();
  int? _delay; // ms, null = untested, -1 = failed
  bool _testing = false;

  Future<void> _testDelay() async {
    if (_testing || widget.coreManager == null) return;
    setState(() {
      _testing = true;
      _delay = null;
    });
    final result = await widget.coreManager!.testProxyDelayDetailed(widget.item.id);
    if (mounted) {
      setState(() {
        _delay = result.delay;
        _testing = false;
      });
      if (result.certError && result.delay < 0) {
        _promptCertTrust();
      }
    }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Certificate installed. Please re-test the proxy.')),
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

  Color _delayColor(int ms) {
    if (ms < 0) return Colors.red;
    if (ms < 200) return Colors.green;
    if (ms < 500) return Colors.orange;
    return Colors.red;
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

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return RadioListTile<String>(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Row(
        children: [
          // Name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name.isNotEmpty
                      ? item.name
                      : '${item.server}:${item.port}',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    // Type badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        _typeLabel(item.type),
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer,
                        ),
                      ),
                    ),
                    // Server address
                    if (item.server != null && item.server!.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${item.server}:${item.port}',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .outline,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // Delay indicator + test button
          if (widget.coreManager != null)
            GestureDetector(
              onTap: _testDelay,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _delay == null
                      ? Theme.of(context).colorScheme.surface
                      : _delayColor(_delay!).withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: _delay == null
                        ? Theme.of(context).colorScheme.outline.withAlpha(80)
                        : _delayColor(_delay!).withAlpha(100),
                  ),
                ),
                child: _testing
                    ? const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5),
                      )
                    : Text(
                        _delay == null
                            ? '...'
                            : _delay! < 0
                                ? tl(context, 'fail')
                                : '${_delay}ms',
                        style: TextStyle(
                          fontSize: 10,
                          color: _delay == null
                              ? Theme.of(context).colorScheme.outline
                              : _delayColor(_delay!),
                        ),
                      ),
              ),
            ),
          // Action menu
          ProxyItemActionMenu(
            onClick: widget.onChange,
            controller: menuController,
            id: item.id,
            type: item.type,
            passwordLocked: item.passwordLocked,
          ),
        ],
      ),
      value: item.id,
    );
  }
}
