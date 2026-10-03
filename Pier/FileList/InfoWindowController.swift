import AppKit
import PierKit

/// "显示简介"面板：路径、大小（64 位精确值）、种类、格式、存储
@MainActor
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [InfoWindowController] = []

    static func show(_ node: FileNode, device: MTPDevice, storage: MTPStorage?) {
        let controller = InfoWindowController(node: node, device: device, storage: storage)
        open.append(controller)
        // 多个面板错开摆放
        if let last = open.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
    }

    private init(node: FileNode, device: MTPDevice, storage: MTPStorage?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "“\(node.name)”简介")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self

        let object = node.object
        let icon = NSImageView(image: FileTypes.icon(forName: node.name, isFolder: node.isFolder))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(wrappingLabelWithString: node.name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.isSelectable = true
        let header = NSStackView(views: [icon, title])
        header.alignment = .centerY
        header.spacing = 10

        var rows: [(String, String)] = [
            (String(localized: "种类"), FileTypes.kind(forName: node.name, isFolder: node.isFolder)),
        ]
        if !node.isFolder {
            let exact = NumberFormatter.localizedString(from: NSNumber(value: object.size), number: .decimal)
            rows.append((String(localized: "大小"), String(localized: "\(Format.bytes(object.size))（\(exact) 字节）")))
        }
        let path = ([device.name, storage?.displayName ?? ""] + node.folderPath.map(\.name)).joined(separator: " ▸ ")
        rows.append((String(localized: "位置"), path))
        if let modified = object.modified { rows.append((String(localized: "修改日期"), Format.date(modified))) }
        rows.append((String(localized: "格式"), String(format: "0x%04X", object.format.rawValue)))
        rows.append((String(localized: "对象句柄"), String(format: "0x%08X", object.handle)))
        if let storage { rows.append((String(localized: "存储"), String(format: "%@（0x%08X）", storage.displayName, storage.id))) }
        if device.quirks?.namesMayBeIncomplete == true {
            rows.append((String(localized: "注意"), String(localized: "这台设备列出的名称会去掉中文等非 ASCII 字符，名称可能不完整。")))
        }

        let grid = NSGridView(views: rows.map { label, value in
            let l = NSTextField(labelWithString: label + "：")
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            let v = NSTextField(wrappingLabelWithString: value)
            v.isSelectable = true
            v.preferredMaxLayoutWidth = 220
            return [l, v]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        let stack = NSStackView(views: [header, NSBox.separator(), grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
