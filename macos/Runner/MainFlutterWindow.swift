import Cocoa
import FlutterMacOS
import window_manager
import LaunchAtLogin

class MainFlutterWindow: NSWindow {

  private var quickEditChannel: FlutterMethodChannel?
  private var quickEditPanel: NSPanel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // LaunchAtLogin channel
    FlutterMethodChannel(
      name: "launch_at_startup",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "launchAtStartupIsEnabled":
        result(LaunchAtLogin.isEnabled)
      case "launchAtStartupSetEnabled":
        if let arguments = call.arguments as? [String: Any] {
          LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Native quick-edit panel channel
    let channel = FlutterMethodChannel(
      name: "lux_quick_edit",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.quickEditChannel = channel
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {
      case "showNearMenubar":
        guard let args = call.arguments as? [String: Any],
              let proxies = args["proxies"] as? [[String: Any]],
              let selectedId = args["selectedId"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
          return
        }
        DispatchQueue.main.async { self.showPanel(proxies: proxies, selectedId: selectedId) }
        result(nil)
      case "hide":
        DispatchQueue.main.async { self.quickEditPanel?.close() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
    // Window visibility is managed by waitUntilReadyToShow in main.dart.
  }

  // MARK: - Native floating panel

  private func showPanel(proxies: [[String: Any]], selectedId: String) {
    // Close existing panel
    quickEditPanel?.close()

    let vc = QuickEditViewController()
    vc.proxies = proxies
    vc.selectedProxyId = selectedId
    vc.onSave = { [weak self] proxyId, username, password, passwordMode, ttlMinutes in
      self?.quickEditPanel?.close()
      self?.quickEditChannel?.invokeMethod("onSave", arguments: [
        "proxyId": proxyId,
        "username": username,
        "password": password,
        "passwordMode": passwordMode,
        "ttlMinutes": ttlMinutes
      ])
    }
    vc.onCancel = { [weak self] in
      self?.quickEditPanel?.close()
    }

    let panelWidth: CGFloat = 300
    let panelHeight: CGFloat = 200

    // Try to find the tray icon button position
    var panelX: CGFloat = 0
    var panelY: CGFloat = 0
    var foundTrayButton = false

    // Walk all status items to find our icon
    for window in NSApp.windows {
      if NSStringFromClass(type(of: window)) == "NSStatusBarWindow" {
        // Get frame in screen coordinates
        let windowFrame = window.frame
        // Position panel below this status bar window
        panelX = windowFrame.midX - panelWidth / 2
        panelY = windowFrame.minY - panelHeight
        foundTrayButton = true
        break
      }
    }

    if !foundTrayButton {
      // Fallback: position near top-right
      let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      panelX = screenFrame.maxX - panelWidth - 8
      panelY = screenFrame.maxY - 24 - panelHeight
    }

    let panel = NSPanel(
      contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
      styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.level = .statusBar
    panel.backgroundColor = NSColor.windowBackgroundColor
    panel.isReleasedWhenClosed = false
    panel.contentViewController = vc

    // Close when focus lost (click outside)
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { [weak panel] _ in
      panel?.close()
    }

    // Animate in: slide down from menubar
    panel.setFrame(NSRect(x: panelX, y: panelY + 12, width: panelWidth, height: panelHeight), display: false)
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)
      panel.animator().alphaValue = 1.0
    }
    self.quickEditPanel = panel
  }

}
