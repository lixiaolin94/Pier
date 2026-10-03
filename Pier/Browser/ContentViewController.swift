import AppKit
import PierKit

/// 内容区：文件列表 + 底部路径栏 + 状态栏；没有位置时显示占位提示
@MainActor
final class ContentViewController: NSViewController {
    weak var browser: BrowserWindowController? {
        didSet { fileList.browser = browser }
    }

    let fileList = FileListViewController()
    private let pathControl = NSPathControl()
    private let pathBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusBar = NSView()
    private let placeholder = NSStackView()
    private var location: BrowserLocation?

    private static let pathBarKey = "ShowPathBar"
    private static let statusBarKey = "ShowStatusBar"

    var isPathBarVisible: Bool { !pathBar.isHidden }
    var isStatusBarVisible: Bool { !statusBar.isHidden }

    override func loadView() {
        UserDefaults.standard.register(defaults: [Self.pathBarKey: true, Self.statusBarKey: true])
        let root = NSView()

        addChild(fileList)
        let list = fileList.view
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list)

        // 路径栏
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathItemClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathBar.addSubview(pathControl)
        addSeparator(to: pathBar)

        // 状态栏
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        addSeparator(to: statusBar)

        let bottom = NSStackView(views: [pathBar, statusBar])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottom)

        // 占位
        let icon = NSImageView(image: NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: String(localized: "未连接设备"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: String(localized: "用数据线连接 Android 设备，并在设备上选择「文件传输」（MTP）模式。"))
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 320
        [icon, title, hint].forEach(placeholder.addArrangedSubview)
        placeholder.orientation = .vertical
        placeholder.spacing = 10
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)

        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pathBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 24),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            pathControl.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: pathBar.trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
        ])

        pathBar.isHidden = !UserDefaults.standard.bool(forKey: Self.pathBarKey)
        statusBar.isHidden = !UserDefaults.standard.bool(forKey: Self.statusBarKey)
        view = root

        fileList.onStatusChange = { [weak self] in self?.updateStatus() }
    }

    private func addSeparator(to bar: NSView) {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
    }

    func show(_ location: BrowserLocation?, forceReload: Bool) {
        _ = view
        let changed = location != self.location
        self.location = location
        let hasLocation = location?.resolved != nil
        placeholder.isHidden = hasLocation
        fileList.view.isHidden = !hasLocation
        if changed || forceReload { fileList.load(hasLocation ? location : nil) }
        updatePath()
        updateStatus()
    }

    // MARK: 路径栏

    private func updatePath() {
        guard let location, let (device, storage) = location.resolved else {
            pathControl.pathItems = []
            return
        }
        var items: [NSPathControlItem] = []
        func add(_ title: String, _ image: NSImage?) {
            let item = NSPathControlItem()
            item.title = title
            item.image = image
            items.append(item)
        }
        add(device.name, NSImage(systemSymbolName: "candybarphone", accessibilityDescription: nil))
        add(storage.displayName, NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil))
        for folder in location.path { add(folder.name, FileTypes.icon(forName: folder.name, isFolder: true)) }
        pathControl.pathItems = items
    }

    @objc private func pathItemClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem, let index = sender.pathItems.firstIndex(of: clicked),
              var target = location else { return }
        // 0 = 设备，1 = 存储根目录，2… = 各级文件夹
        let depth = max(index - 1, 0)
        target.path = Array(target.path.prefix(depth))
        browser?.navigate(to: target)
    }

    // MARK: 状态栏

    private func updateStatus() {
        guard let (_, storage) = location?.resolved else {
            statusLabel.stringValue = ""
            return
        }
        var parts: [String] = []
        let count = fileList.displayedCount
        let selected = fileList.selectedCount
        if fileList.isLoading {
            parts.append(String(localized: "正在读取…（\(count) 项）"))
        } else if selected > 0 {
            parts.append(String(localized: "已选择 \(selected) 项，共 \(count) 项"))
        } else {
            parts.append(String(localized: "\(count) 项"))
        }
        parts.append(String(localized: "\(Format.bytes(storage.info.freeSpace)) 可用"))
        if storage.isReadOnly { parts.append(String(localized: "只读")) }
        statusLabel.stringValue = parts.joined(separator: "，")
    }

    func togglePathBar() {
        pathBar.isHidden.toggle()
        UserDefaults.standard.set(!pathBar.isHidden, forKey: Self.pathBarKey)
    }

    func toggleStatusBar() {
        statusBar.isHidden.toggle()
        UserDefaults.standard.set(!statusBar.isHidden, forKey: Self.statusBarKey)
    }
}
