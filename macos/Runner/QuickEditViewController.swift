import Cocoa

/// Native NSPanel credential editor anchored to the menubar status item.
class QuickEditViewController: NSViewController {

    // MARK: - Data
    var proxies: [[String: Any]] = []
    var selectedProxyId: String = ""
    var onSave: ((_ proxyId: String, _ username: String, _ password: String, _ passwordMode: String, _ ttlMinutes: Int) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - State
    private var currentPasswordMode: String = "persistent"
    private var currentTTLMinutes: Int = 60

    // MARK: - UI
    private lazy var profilePopup: NSPopUpButton = {
        let p = NSPopUpButton()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.target = self
        p.action = #selector(profileChanged)
        return p
    }()
    private lazy var usernameField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "Username"
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    private lazy var passwordField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "Password"
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    private lazy var passwordModePopup: NSPopUpButton = {
        let p = NSPopUpButton()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.addItem(withTitle: "Persistent")
        p.lastItem?.representedObject = "persistent"
        p.addItem(withTitle: "One-time (clears on switch)")
        p.lastItem?.representedObject = "one-time"
        p.addItem(withTitle: "Timed (auto-expires)")
        p.lastItem?.representedObject = "timed"
        p.target = self
        p.action = #selector(passwordModeChanged)
        return p
    }()
    private lazy var ttlContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private lazy var ttlLabel = makeSmallLabel("Expires after (minutes):")
    private lazy var ttlField: NSTextField = {
        let f = NSTextField()
        f.stringValue = "60"
        f.placeholderString = "60"
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return f
    }()
    private lazy var saveButton: NSButton = {
        let b = NSButton(title: "Save", target: self, action: #selector(save))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    private lazy var cancelButton: NSButton = {
        let b = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    private var mainStack: NSStackView!

    // MARK: - Lifecycle
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 260))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadProxies()
    }

    // MARK: - Setup
    private func setupUI() {
        mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 8
        mainStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Profile
        mainStack.addArrangedSubview(makeRow(label: makeLabel("Profile"), control: profilePopup))

        // Username
        mainStack.addArrangedSubview(makeRow(label: makeLabel("Username"), control: usernameField))

        // Password
        mainStack.addArrangedSubview(makeRow(label: makeLabel("Password"), control: passwordField))

        // Password mode
        mainStack.addArrangedSubview(makeRow(label: makeLabel("Mode"), control: passwordModePopup))

        // TTL row (hidden unless timed)
        let ttlRow = NSStackView(views: [ttlLabel, ttlField])
        ttlRow.orientation = .horizontal
        ttlRow.spacing = 6
        ttlRow.alignment = .centerY
        ttlContainer.addSubview(ttlRow)
        ttlRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ttlRow.topAnchor.constraint(equalTo: ttlContainer.topAnchor),
            ttlRow.bottomAnchor.constraint(equalTo: ttlContainer.bottomAnchor),
            ttlRow.leadingAnchor.constraint(equalTo: ttlContainer.leadingAnchor, constant: 70),
            ttlRow.trailingAnchor.constraint(equalTo: ttlContainer.trailingAnchor),
        ])
        ttlContainer.isHidden = true
        mainStack.addArrangedSubview(ttlContainer)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        mainStack.addArrangedSubview(sep)

        // Buttons
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        mainStack.addArrangedSubview(buttonRow)

        view.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([l.widthAnchor.constraint(equalToConstant: 62)])
        return l
    }

    private func makeSmallLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func makeRow(label: NSTextField, control: NSView) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Data Loading
    private func loadProxies() {
        profilePopup.removeAllItems()
        for proxy in proxies {
            guard let name = proxy["name"] as? String else { continue }
            profilePopup.addItem(withTitle: name)
            profilePopup.lastItem?.representedObject = proxy["id"] as? String
        }
        // Select current proxy
        for (i, proxy) in proxies.enumerated() {
            if proxy["id"] as? String == selectedProxyId {
                profilePopup.selectItem(at: i)
                loadCredentials(for: proxy)
                break
            }
        }
        if profilePopup.indexOfSelectedItem < 0, !proxies.isEmpty {
            loadCredentials(for: proxies[0])
        }
    }

    private func loadCredentials(for proxy: [String: Any]) {
        usernameField.stringValue = proxy["username"] as? String ?? ""
        passwordField.stringValue = proxy["password"] as? String ?? ""
        let mode = proxy["passwordMode"] as? String ?? "persistent"
        currentPasswordMode = mode
        currentTTLMinutes = (proxy["ttlMinutes"] as? Int) ?? 60
        // Set popup selection
        for i in 0..<passwordModePopup.numberOfItems {
            if passwordModePopup.item(at: i)?.representedObject as? String == mode {
                passwordModePopup.selectItem(at: i)
                break
            }
        }
        ttlField.stringValue = "\(currentTTLMinutes)"
        updateTTLVisibility()
    }

    private func updateTTLVisibility() {
        let shouldShow = currentPasswordMode == "timed"
        if ttlContainer.isHidden == shouldShow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.ttlContainer.animator().isHidden = !shouldShow
            }
            // Resize panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.resizePanel(forTimed: shouldShow)
            }
        }
    }

    private func resizePanel(forTimed: Bool) {
        guard let panel = view.window else { return }
        let targetHeight: CGFloat = forTimed ? 290 : 260
        var frame = panel.frame
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Actions
    @objc private func profileChanged() {
        let idx = profilePopup.indexOfSelectedItem
        if idx >= 0, idx < proxies.count {
            loadCredentials(for: proxies[idx])
        }
    }

    @objc private func passwordModeChanged() {
        currentPasswordMode = passwordModePopup.selectedItem?.representedObject as? String ?? "persistent"
        updateTTLVisibility()
    }

    @objc private func save() {
        let idx = profilePopup.indexOfSelectedItem
        guard idx >= 0, idx < proxies.count,
              let proxyId = proxies[idx]["id"] as? String else { return }
        let ttl = Int(ttlField.stringValue) ?? 60
        onSave?(proxyId, usernameField.stringValue, passwordField.stringValue, currentPasswordMode, ttl)
    }

    @objc private func cancel() {
        onCancel?()
    }
}
