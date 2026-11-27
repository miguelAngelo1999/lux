import 'package:flutter/material.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/theme.dart';
import 'package:lux/tr.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/proxy_list_item.dart';

import '../core/core_config.dart';

class ProxyListCard extends StatefulWidget {
  final ProxyList proxyList;
  final Function onCollapse;
  final bool isCollapsed;
  final List<SubscriptionItem> subscriptionList;
  final CoreManager? coreManager;

  final void Function(ProxyItemAction action, ProxyItem item) onItemChange;
  // Whole-row select + which proxy is active, so the row can make the entire
  // tile select (not just the radio dot) and show selected styling.
  final void Function(String id)? onSelect;
  final String? selectedId;
  final void Function(String id, ProxyTestStatus status)? onTestStatusChanged;
  final ProxyItemController? selectedController;
  final VoidCallback? onCredentialsSaved;
  final Future<void> Function(ProxyItem item)? onPeekPassword;

  const ProxyListCard({
    super.key,
    required this.proxyList,
    required this.onCollapse,
    required this.isCollapsed,
    required this.onItemChange,
    required this.subscriptionList,
    this.coreManager,
    this.onSelect,
    this.selectedId,
    this.onTestStatusChanged,
    this.selectedController,
    this.onCredentialsSaved,
    this.onPeekPassword,
  });

  @override
  State<ProxyListCard> createState() => _ProxyListCardState();
}

class _ProxyListCardState extends State<ProxyListCard> {
  String getTitle() {
    if (widget.proxyList.id != localServersGroupKey) {
      try {
        var filteredSubscriptions = widget.subscriptionList
            .where((item) => item.id == widget.proxyList.id);
        var curSubscription = filteredSubscriptions.firstOrNull;
        if (curSubscription != null) {
          if (curSubscription.name.isNotEmpty) {
            return curSubscription.name;
          }
          return Uri.parse(curSubscription.url).host;
        }
      } catch (e) {
        return "invalid proxy group title";
      }
    }
    return tr().localServer;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final proxyList = widget.proxyList;
    final title = getTitle();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Quiet section header with count pill
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 7),
            child: Row(
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onCollapse(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LuxIcon(
                            widget.isCollapsed
                                ? LuxGlyph.chevronDown
                                : LuxGlyph.chevronUp,
                            size: 13,
                            color: tokens.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            title.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.7,
                              color: tokens.textMuted,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: tokens.subtlePillBg,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${proxyList.proxies.length}',
                              style: luxMonoStyle(
                                fontSize: 10,
                                color: tokens.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (proxyList.proxies.isNotEmpty && widget.isCollapsed)
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tokens.hairline, width: 0.75),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: proxyList.proxies.length,
                  itemBuilder: (context, index) {
                    final item = proxyList.proxies[index];
                    final isSelected = widget.selectedId == item.id;
                    return ProxyListItem(
                      key: Key(item.id),
                      item: item,
                      coreManager: widget.coreManager,
                      selected: isSelected,
                      onSelect: widget.onSelect,
                      onTestStatusChanged: widget.onTestStatusChanged == null
                          ? null
                          : (status) =>
                              widget.onTestStatusChanged!(item.id, status),
                      selectedController:
                          isSelected ? widget.selectedController : null,
                      onCredentialsSaved: widget.onCredentialsSaved,
                      onPeekPassword: widget.onPeekPassword,
                      onChange: (action) => widget.onItemChange(action, item),
                    );
                  },
                  separatorBuilder: (BuildContext context, int index) {
                    return Container(
                      height: 0.75,
                      margin: const EdgeInsets.symmetric(horizontal: 14),
                      color: tokens.hairline,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
