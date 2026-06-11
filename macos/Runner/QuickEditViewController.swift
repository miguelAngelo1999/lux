import Cocoa

/// Native NSPopover credential editor anchored to the menubar status item.
class QuickEditViewController: NSViewController {

    // MARK: - Data
    var proxies: [[String: Any]] = []
    var selectedProxyId: String = ""
    var onSave: ((_ proxyId: String, _ username: String, _ password: String) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - UI
    private lazy var profileLabel = makeLabel("Profile")
    private lazy var profilePopup = NSPopUpButton()
    private lazy var usernameLabel = makeLabel("Username")
    private lazy var usernameField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "Username"
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    private lazy var passwordLabel = makeLabel("Password")
    private lazy var passwordField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "Password"
        f.translatesAutoresizingMaskIntoConstraints = false
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

    // MARK: - Lifecycle
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadProxies()
    }

    // MARK: - Setup
    private func setupUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Profile row
        let profileRow = makeRow(label: profileLabel, control: profilePopup)
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)

        // Username row
        let usernameRow = makeRow(label: usernameLabel, control: usernameField)

        // Password row
        let passwordRow = makeRow(label: passwordLabel, control: passwordField)

        // Buttons
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        stack.addArrangedSubview(profileRow)
        stack.addArrangedSubview(usernameRow)
        stack.addArrangedSubview(passwordRow)
        stack.addArrangedSubview(buttonRow)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([l.widthAnchor.constraint(equalToConstant: 68)])
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
            guard let name = proxy["name"] as? String,
                  let id = proxy["id"] as? String else { continue }
            profilePopup.addItem(withTitle: name)
            profilePopup.lastItem?.representedObject = id
        }
        // Select current proxy
        if !selectedProxyId.isEmpty {
            for (i, proxy) in proxies.enumerated() {
                if proxy["id"] as? String == selectedProxyId {
                    profilePopup.selectItem(at: i)
                    loadCredentials(for: proxy)
                    break
                }
            }
        } else if !proxies.isEmpty {
            loadCredentials(for: proxies[0])
        }
    }

    private func loadCredentials(for proxy: [String: Any]) {
        usernameField.stringValue = proxy["username"] as? String ?? ""
        passwordField.stringValue = proxy["password"] as? String ?? ""
    }

    // MARK: - Actions
    @objc private func profileChanged() {
        let idx = profilePopup.indexOfSelectedItem
        if idx >= 0 && idx < proxies.count {
            loadCredentials(for: proxies[idx])
        }
    }

    @objc private func save() {
        let idx = profilePopup.indexOfSelectedItem
        guard idx >= 0, idx < proxies.count,
              let proxyId = proxies[idx]["id"] as? String else { return }
        onSave?(proxyId, usernameField.stringValue, passwordField.stringValue)
    }

    @objc private func cancel() {
        onCancel?()
    }
}
