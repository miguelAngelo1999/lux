import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // On macOS Sequoia, NIB objects are not instantiated until the app becomes
    // visible when launched in background. Force regular policy + activate so
    // awakeFromNib fires and Flutter engine starts.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Force window show — waitUntilReadyToShow may never fire under launchctl.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if let window = self.mainFlutterWindow {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }

    // MethodChannel: Dart calls "setDockVisibility" to show/hide dock icon.
    // "hide" → .accessory (tray only, no dock icon)
    // "show" → .regular (dock icon visible, for when window is open)
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      FlutterMethodChannel(
        name: "lux_dock",
        binaryMessenger: controller.engine.binaryMessenger
      ).setMethodCallHandler { (call, result) in
        switch call.method {
        case "hide":
          NSApp.setActivationPolicy(.accessory)
          result(nil)
        case "show":
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // When dock icon is clicked (or app reopened), switch back to regular
    // so the dock icon stays visible while the window is open.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if !flag {
      for window in NSApp.windows {
        if !window.isVisible {
          window.setIsVisible(true)
        }
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

}
