import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/elevate.dart';
import 'package:path/path.dart' as path;

import '../../const/const.dart';
import '../../error.dart';

const corePathVar = "LUX_CORE_PATH";

class CoreRunErrorHandler extends StatefulWidget {
  final CoreRunError errorDetail;

  const CoreRunErrorHandler({
    super.key,
    required this.errorDetail,
  });

  @override
  State<CoreRunErrorHandler> createState() => _CoreRunErrorHandlerState();
}

class _CoreRunErrorHandlerState extends State<CoreRunErrorHandler> {
  var isElevated = false;
  var isGranting = false;
  var grantFailed = false;
  var corePath = path.join(Paths.assetsBin.path, LuxCoreName.name);

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      getFileOwner(corePath).then((owner) {
        setState(() {
          isElevated = owner == "root";
        });
      });
    }
  }

  Future<void> _grantAccess() async {
    setState(() {
      isGranting = true;
      grantFailed = false;
    });

    final code = await elevate(corePath, 'Lux needs administrator privileges to create the network adapter.');

    if (!mounted) return;

    if (code == 0) {
      // Success — restart the app so it picks up the new elevation.
      exit(0);
    } else {
      setState(() {
        isGranting = false;
        grantFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsElevation = Platform.isMacOS && !isElevated;

    return Scaffold(
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                needsElevation ? Icons.admin_panel_settings : Icons.warning_amber,
                size: 56,
                color: needsElevation
                    ? Theme.of(context).primaryColor
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 20),
              Text(
                needsElevation
                    ? tl(context, 'Administrator Access Required')
                    : tr().somethingWrong,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                needsElevation
                    ? tl(context, 'Lux needs administrator privileges to create the network adapter. Click below and enter your Mac password when prompted.')
                    : '${tr().coreRunError}: ${widget.errorDetail.message}',
                style: const TextStyle(fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (needsElevation) ...[
                if (isGranting)
                  const Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      TText('Waiting for password...', style: TextStyle(fontSize: 12)),
                    ],
                  )
                else
                  FilledButton.icon(
                    onPressed: _grantAccess,
                    icon: const Icon(Icons.lock_open),
                    label: const TText('Grant Access'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    ),
                  ),
                if (grantFailed) ...[
                  const SizedBox(height: 16),
                  Text(
                    tl(context, 'Setup was cancelled or failed. Try again, or if this keeps happening, open Terminal and paste:'),
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(
                      'sudo xattr -cr /Applications/Lux.app && '
                      'BIN="/Applications/Lux.app/Contents/Frameworks/App.framework/'
                      'Resources/flutter_assets/assets/bin/lux_core" && '
                      r'REAL="${BIN}_real" && sudo mv "$BIN" "$REAL" && '
                      r'''printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL" | '''
                      r'sudo tee "$BIN" > /dev/null && sudo chmod 755 "$BIN" && '
                      r'sudo chown root:wheel "$REAL" && sudo chmod 4755 "$REAL" && '
                      r'''echo "$(whoami) ALL=(root) NOPASSWD: $REAL *" | '''
                      r'sudo tee /etc/sudoers.d/lux_core > /dev/null && '
                      'sudo chmod 0440 /etc/sudoers.d/lux_core',
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
