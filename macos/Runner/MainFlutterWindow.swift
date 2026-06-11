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
  }

  // MARK: - Native floating panel

  private func showPanel(proxies: [[String: Any]], selectedId: String) {
    // Close existing panel
    quickEditPanel?.close()

    let vc = QuickEditViewController()
    vc.proxies = proxies
    vc.selectedProxyId = selectedId
    vc.onSave = { [weak self] proxyId, username, password in
      self?.quickEditPanel?.close()
      self?.quickEditChannel?.invokeMethod("onSave", arguments: [
        "proxyId": proxyId,
        "username": username,
        "password": password
      ])
    }
    vc.onCancel = { [weak self] in
      self?.quickEditPanel?.close()
    }

    // Position near top-right (below menubar)
    let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let panelWidth: CGFloat = 316
    let panelHeight: CGFloat = 220
    let panelX = screenFrame.maxX - panelWidth - 8
    let panelY = screenFrame.maxY - 24 - panelHeight // 24 = menubar height

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
    panel.makeKeyAndOrderFront(nil)
    self.quickEditPanel = panel
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
