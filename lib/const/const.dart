import 'dart:io';

import 'package:path/path.dart' as path;

class LuxCoreName {
  static String get platform {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'darwin';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static String get arch {
    return const String.fromEnvironment('OS_ARCH', defaultValue: 'amd64');
  }

  static String get ext {
    if (Platform.isWindows) return '.exe';
    return '';
  }

  static String get name {
    return 'lux_core$ext';
  }
}

class Paths {
  static Directory get flutterAssets {
    File mainFile = File(Platform.resolvedExecutable);
    String assetsPath = '../data/flutter_assets';
    if (Platform.isMacOS) {
      assetsPath = '../../Frameworks/App.framework/Resources/flutter_assets';
    }
    return Directory(path.normalize(path.join(mainFile.path, assetsPath)));
  }

  static Directory get assets {
    return Directory(path.join(flutterAssets.path, 'assets'));
  }

  static Directory get assetsBin {
    return Directory(path.join(assets.path, 'bin'));
  }

  static String get appIcon {
    return path.join(
        assets.path, Platform.isWindows ? 'app_icon.ico' : 'tray.icns');
  }

  static String get pubspec {
    return path.join(flutterAssets.path, "pubspec.yaml");
  }
}

const darkBackgroundColor = 0xff292929;

const launchFromStartupArg = 'launch_from_startup';

const localServersGroupKey = 'local_servers';

/// Raw GitHub URL for appcast.json — always reliably served, no GDrive redirects.
/// release.py updates this file in the repo after each release.
const appcastUrl = 'https://raw.githubusercontent.com/miguelAngelo1999/lux/personal/all-features/appcast.json';

/// Also update init_appcast.py if the GDrive appcast file ID changes.
/// GDrive direct download (for reference): https://drive.usercontent.google.com/download?id=1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p&export=download&confirm=t

/// Fallback: browser releases page
const releasesPageUrl = 'https://github.com/miguelAngelo1999/lux/releases/latest';

/// Legacy alias kept for compatibility
const latestReleaseUrl = releasesPageUrl;

enum ProxyItemAction {
  edit,
  delete,
  qrCode,
  peekPassword,
  lockPassword,
}
