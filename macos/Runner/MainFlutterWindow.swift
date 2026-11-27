import Cocoa
import FlutterMacOS
import window_manager
import LaunchAtLogin

class MainFlutterWindow: NSWindow {

  private var quickEditChannel: FlutterMethodChannel?
  private var surfaceChannel: FlutterMethodChannel?
  private var quickEditPanel: NSPanel?
  private var windowBackdropView: NSVisualEffectView?
  private var sidebarBackdropView: NSView?
  private var flutterVC: FlutterViewController?
  private var accessibilityObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.flutterVC = flutterViewController
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Configure native macOS glass/vibrancy surface with graceful fallback
    // for macOS 12-15 (NSVisualEffectView) and Reduce Transparency (opaque).
    setupWindowSurface(for: flutterViewController)

    // Window surface channel: reports live capability tier to Flutter and
    // syncs NSAppearance when the user picks Light/Dark/System in Lux.
    let surfChannel = FlutterMethodChannel(
      name: "lux_window_surface",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.surfaceChannel = surfChannel
    surfChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result("opaque")
        return
      }
      switch call.method {
      case "getSurfaceTier":
        result(self.currentSurfaceTier())
      case "setAppearance":
        let mode = (call.arguments as? [String: Any])?["mode"] as? String ?? "system"
        DispatchQueue.main.async {
          self.applyWindowAppearance(mode)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.refreshSurfaceTransparency()
      self.surfaceChannel?.invokeMethod("onSurfaceTierChanged", arguments: self.currentSurfaceTier())
    }

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

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }

  deinit {
    if let obs = accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
  }

  // MARK: - Native macOS Liquid Glass / Vibrancy surface

  private func currentSurfaceTier() -> String {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      return "opaque"
    }
    if #available(macOS 26.0, *) {
      return "liquid_glass"
    }
    return "vibrancy"
  }

  private func applyWindowAppearance(_ mode: String) {
    switch mode {
    case "dark":
      self.appearance = NSAppearance(named: .darkAqua)
    case "light":
      self.appearance = NSAppearance(named: .aqua)
    default:
      self.appearance = nil
    }
  }

  private func setupWindowSurface(for controller: FlutterViewController) {
    guard let hostView = self.contentView else { return }
    let flutterView = controller.view

    // Wrap the Flutter view inside a container so native behind-window glass
    // layers sit deterministically below the transparent Flutter metal surface.
    let container = NSView(frame: hostView.bounds)
    container.autoresizingMask = [.width, .height]

    let baseBackdrop = NSVisualEffectView(frame: container.bounds)
    baseBackdrop.autoresizingMask = [.width, .height]
    baseBackdrop.material = .underWindowBackground
    baseBackdrop.blendingMode = .behindWindow
    baseBackdrop.state = .followsWindowActiveState
    container.addSubview(baseBackdrop)
    self.windowBackdropView = baseBackdrop

    let sidebarView: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: .zero)
      glass.style = .regular
      glass.cornerRadius = 14
      glass.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(glass)
      NSLayoutConstraint.activate([
        glass.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
        glass.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        glass.widthAnchor.constraint(equalToConstant: 164),
      ])
      sidebarView = glass
    } else {
      let vibrancy = NSVisualEffectView(frame: .zero)
      vibrancy.material = .sidebar
      vibrancy.blendingMode = .behindWindow
      vibrancy.state = .followsWindowActiveState
      vibrancy.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(vibrancy)
      NSLayoutConstraint.activate([
        vibrancy.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        vibrancy.topAnchor.constraint(equalTo: container.topAnchor),
        vibrancy.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        vibrancy.widthAnchor.constraint(equalToConstant: 176),
      ])
      sidebarView = vibrancy
    }
    self.sidebarBackdropView = sidebarView

    // Keep Flutter view filling the container on top of the native backdrop.
    flutterView.frame = container.bounds
    flutterView.autoresizingMask = [.width, .height]
    container.addSubview(flutterView)
    self.contentView = container

    refreshSurfaceTransparency()
  }

  private func refreshSurfaceTransparency() {
    let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    if reduced {
      self.isOpaque = true
      self.backgroundColor = .windowBackgroundColor
      self.flutterVC?.backgroundColor = .windowBackgroundColor
      self.windowBackdropView?.isHidden = true
      self.sidebarBackdropView?.isHidden = true
    } else {
      self.isOpaque = false
      self.backgroundColor = .clear
      self.flutterVC?.backgroundColor = .clear
      self.windowBackdropView?.isHidden = false
      self.sidebarBackdropView?.isHidden = false
    }
  }
}
