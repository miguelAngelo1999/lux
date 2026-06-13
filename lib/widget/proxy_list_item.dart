import 'package:flutter/material.dart';
import 'package:lux/widget/proxy_item_action_menu.dart';

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
    final ms = await widget.coreManager!.testProxyDelay(widget.item.id);
    if (mounted) {
      setState(() {
        _delay = ms;
        _testing = false;
      });
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
                                ? 'fail'
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
