import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

import '../core/core_config.dart';
import '../core/core_manager.dart';
import '../tr.dart';
import '../util/utils.dart';

class AppBottomBar extends StatefulWidget {
  final CoreManager coreManager;

  const AppBottomBar(this.coreManager, {super.key});

  @override
  State<AppBottomBar> createState() => _AppBottomBarState();
}

class _AppBottomBarState extends State<AppBottomBar> with WindowListener {
  ProxyMode proxyMode = ProxyMode.tun;
  TrafficState? trafficData;
  WebSocketChannel? trafficChannel;
  StreamSubscription? _trafficSub;
  bool isWindowHidden = false;

  Future<void> refreshMode() async {
    try {
      final value = await widget.coreManager.getSetting();
      if (!mounted) return;
      setState(() {
        proxyMode = value.mode;
      });
    } catch (_) {}
  }

  void _onCoreGenerationChanged() {
    if (!mounted) return;
    refreshMode();
    if (trafficChannel == null) {
      _connectTrafficChannel();
    }
  }

  void _connectTrafficChannel() {
    _trafficSub?.cancel();
    _trafficSub = null;
    widget.coreManager.getTrafficChannel().then((channel) async {
      if (channel == null || !mounted) return;
      try {
        // Required by web_socket_channel 3.x: without awaiting ready the
        // subscription can attach before the socket is open and traffic frames
        // are dropped silently, so the speed readout stays at zero.
        await channel.ready;
      } catch (_) {
        trafficChannel = null;
        widget.coreManager.clearTrafficChannel();
        return;
      }
      if (!mounted) return;
      trafficChannel = channel;
      _trafficSub = trafficChannel?.stream.listen(
        (message) {
          if (isWindowHidden || !mounted) {
            return;
          }
          try {
            TrafficData value = TrafficData.fromJson(json.decode(message));
            setState(() {
              trafficData = TrafficState(rawData: value);
            });
          } catch (_) {}
        },
        onError: (_) {
          _trafficSub = null;
          trafficChannel = null;
          widget.coreManager.clearTrafficChannel();
        },
        onDone: () {
          _trafficSub = null;
          trafficChannel = null;
          widget.coreManager.clearTrafficChannel();
        },
        cancelOnError: true,
      );
    }).catchError((_) {
      trafficChannel = null;
      widget.coreManager.clearTrafficChannel();
    });
  }

  @override
  void initState() {
    super.initState();
    refreshMode();
    windowManager.addListener(this);
    widget.coreManager.coreGeneration.addListener(_onCoreGenerationChanged);
    _connectTrafficChannel();
  }

  @override
  void onWindowFocus() {
    isWindowHidden = false;
    refreshMode();
    if (trafficChannel == null) {
      _connectTrafficChannel();
    }
  }

  @override
  void onWindowClose() {
    isWindowHidden = true;
  }

  @override
  void dispose() {
    widget.coreManager.coreGeneration.removeListener(_onCoreGenerationChanged);
    windowManager.removeListener(this);
    _trafficSub?.cancel();
    trafficChannel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 2, bottom: 2, left: 4, right: 4),
      decoration: BoxDecoration(
          border: Border(
        top: BorderSide(
          color: Theme.of(context).dividerColor,
          width: 1.0,
        ),
      )),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: tr().bottomBarTip,
            child: Icon(
              Icons.help_outline,
              size: 16,
            ),
          ),
          SizedBox(width: 4),
          Tooltip(
            message: trafficData?.totalMsg ?? "",
            child: SizedBox(
              width: 68,
              child: Text(
                trafficData?.total != null ? "${trafficData?.total}" : "0 B",
              ),
            ),
          ),
          SizedBox(width: 4),
          Tooltip(
            message: trafficData?.uploadMsg ?? "",
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.arrow_upward_sharp, size: 14),
                SizedBox(
                  width: 76,
                  child: Text(
                    trafficData?.upload != null
                        ? "${trafficData?.upload}/s"
                        : "0 B/s",
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: trafficData?.downloadMsg ?? "",
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.arrow_downward_sharp, size: 14),
                SizedBox(
                  width: 76,
                  child: Text(
                    trafficData?.download != null
                        ? "${trafficData?.download}/s"
                        : "0 B/s",
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 4),
          Tooltip(
            message: tr().proxyModeTooltip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                getModeLabel(proxyMode),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TrafficState {
  final TrafficData rawData;

  TrafficState({required this.rawData});

  String get download {
    var download = rawData.speed.proxy.download + rawData.speed.direct.download;
    return formatBytes(download);
  }

  String get downloadMsg {
    return "${tr().proxyLabel}: ${formatBytes(rawData.speed.proxy.download)}/s\n\n${tr().bypassLabel}: ${formatBytes(rawData.speed.direct.download)}/s";
  }

  String get upload {
    var upload = rawData.speed.proxy.upload + rawData.speed.direct.upload;
    return formatBytes(upload);
  }

  String get uploadMsg {
    return "${tr().proxyLabel}: ${formatBytes(rawData.speed.proxy.upload)}/s\n\n${tr().bypassLabel}: ${formatBytes(rawData.speed.direct.upload)}/s";
  }

  String get total {
    var total = rawData.total.proxy.upload +
        rawData.total.proxy.download +
        rawData.total.direct.upload +
        rawData.total.direct.download;
    return formatBytes(total);
  }

  String get totalMsg {
    var proxyTotal =
        formatBytes(rawData.total.proxy.upload + rawData.total.proxy.download);
    var directTotal = formatBytes(
        rawData.total.direct.upload + rawData.total.direct.download);
    return "${tr().proxyLabel}: $proxyTotal\n\n${tr().bypassLabel}: $directTotal";
  }
}

String getModeLabel(ProxyMode value) {
  switch (value) {
    case ProxyMode.tun:
      return tr().tunModeLabel;
    case ProxyMode.system:
      return tr().systemModeLabel;
    default:
      return tr().mixedModeLabel;
  }
}
