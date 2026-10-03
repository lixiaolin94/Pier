import AppKit
import PierKit

/// 传输列表（工具栏按钮弹出的 popover）：每个任务的进度、速度、剩余时间，可暂停、继续、取消、重试
@MainActor
final class TransfersViewController: NSViewController {
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "没有传输任务"))
    private let clearButton = NSButton(title: String(localized: "清除已完成"), target: nil, action: nil)
    private var transfers: [Transfer] = []
    private var heightConstraint: NSLayoutConstraint?

    private var queue: TransferQueue { Services.transfers }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "传输"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearFinished(_:))
        let header = NSStackView(views: [title, NSView(), clearButton])
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 6, right: 10)

        let column = NSTableColumn(identifier: .init("transfer"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 58
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAutomaticRowHeights = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, NSBox.separator(), scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        root.addSubview(emptyLabel)
        let height = scroll.heightAnchor.constraint(equalToConstant: 80)
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 420),
            height,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(listDidChange(_:)), name: TransferQueue.didChange, object: nil)
        center.addObserver(self, selector: #selector(progressDidUpdate(_:)), name: TransferQueue.progressDidUpdate, object: nil)
        reload()
    }

    @objc private func listDidChange(_ note: Notification) { reload() }

    @objc private func progressDidUpdate(_ note: Notification) {
        for row in 0..<transfers.count {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TransferCellView)?.update()
        }
    }

    private func reload() {
        let newList = Array(queue.transfers.reversed())
        if newList.map(\.id) == transfers.map(\.id) {
            progressDidUpdate(Notification(name: TransferQueue.didChange))
        } else {
            transfers = newList
            tableView.reloadData()
        }
        emptyLabel.isHidden = !transfers.isEmpty
        clearButton.isEnabled = transfers.contains { $0.state.isFinished }
        heightConstraint?.constant = min(max(CGFloat(transfers.count) * tableView.rowHeight, 80), 460)
    }

    @objc private func clearFinished(_ sender: Any?) { queue.clearFinished() }
}

extension TransfersViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { transfers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TransferCellView.identifier, owner: self) as? TransferCellView) ?? TransferCellView()
        cell.transfer = transfers[row]
        return cell
    }
}

/// 一行传输：图标、名字、进度条、状态文字、操作按钮
@MainActor
final class TransferCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TransferCell")

    var transfer: Transfer? { didSet { configure() } }

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let primaryButton = NSButton()
    private let closeButton = NSButton()
    private let revealButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1

        for (button, symbol, tip) in [(primaryButton, "pause.circle.fill", ""), (closeButton, "xmark.circle.fill", String(localized: "取消")),
                                      (revealButton, "magnifyingglass.circle.fill", String(localized: "在 Finder 中显示"))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.target = self
            button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        }
        primaryButton.action = #selector(primaryClicked(_:))
        closeButton.action = #selector(closeClicked(_:))
        revealButton.action = #selector(revealClicked(_:))

        let texts = NSStackView(views: [nameLabel, progressBar, statusLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let buttons = NSStackView(views: [revealButton, primaryButton, closeButton])
        buttons.spacing = 4
        let row = NSStackView(views: [icon, texts, buttons])
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            progressBar.widthAnchor.constraint(equalTo: texts.widthAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor),
        ])
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        guard let t = transfer else { return }
        icon.image = FileTypes.icon(forName: t.name, isFolder: t.isFolder)
        let arrow = t.direction == .download ? "↓" : "↑"
        nameLabel.stringValue = "\(arrow) \(t.name)"
        nameLabel.toolTip = t.direction == .download
            ? String(localized: "从“\(t.deviceName)”下载到 \(t.localURL.deletingLastPathComponent().path)")
            : String(localized: "上传到“\(t.deviceName)”的 \(([""] + t.remoteFolder.map(\.name)).joined(separator: "/"))")
        update()
    }

    func update() {
        guard let t = transfer else { return }
        let s = t.progress.snapshot
        progressBar.doubleValue = s.fraction
        progressBar.isHidden = t.state.isFinished
        statusLabel.stringValue = t.statusText
        statusLabel.textColor = t.state.isFailed ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = statusLabel.stringValue

        switch t.state {
        case .paused:
            primaryButton.isHidden = false
            primaryButton.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
            primaryButton.toolTip = String(localized: "继续")
        case .failed:
            primaryButton.isHidden = false
            primaryButton.image = NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: nil)
            primaryButton.toolTip = String(localized: "重试")
        case .completed, .cancelled:
            primaryButton.isHidden = true
        default:
            primaryButton.isHidden = false
            primaryButton.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: nil)
            primaryButton.toolTip = String(localized: "暂停")
        }
        closeButton.toolTip = t.state.isFinished ? String(localized: "从列表中移除") : String(localized: "取消")
        revealButton.isHidden = !(t.direction == .download && t.state == .completed)
    }

    @objc private func primaryClicked(_ sender: Any?) {
        guard let t = transfer else { return }
        switch t.state {
        case .paused, .failed: Services.transfers.resume(t)
        default: Services.transfers.pause(t)
        }
    }

    @objc private func closeClicked(_ sender: Any?) {
        guard let t = transfer else { return }
        Services.transfers.remove(t)
    }

    @objc private func revealClicked(_ sender: Any?) {
        guard let t = transfer else { return }
        NSWorkspace.shared.activateFileViewerSelecting([t.localURL])
    }
}

extension Transfer {
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    /// 状态行：进度、速度、剩余时间，或者错误原因
    @MainActor var statusText: String {
        let s = progress.snapshot
        let amount = "\(Format.bytes(s.completedBytes)) / \(Format.bytes(s.totalBytes))"
        let files = s.totalFiles > 1 ? String(localized: "，第 \(min(s.completedFiles + 1, s.totalFiles))/\(s.totalFiles) 个文件") : ""
        switch state {
        case .waiting:
            return String(localized: "等待中…")
        case .preparing:
            return String(localized: "正在准备…")
        case .running:
            var parts = [amount + files]
            if bytesPerSecond > 0 { parts.append("\(Format.bytes(UInt64(bytesPerSecond)))/s") }
            if let remaining = remainingSeconds, remaining > 1, let text = Self.durationFormatter.string(from: remaining) {
                parts.append(String(localized: "剩余约 \(text)"))
            }
            if s.isEstimated { parts.append(String(localized: "进度为估算")) }
            return parts.joined(separator: " · ")
        case .paused:
            return String(localized: "已暂停 · \(amount)")
        case .waitingForDevice:
            return String(localized: "等待“\(deviceName)”重新连接…")
        case let .failed(message):
            return message
        case .completed:
            var text = String(localized: "已完成 · \(Format.bytes(s.totalBytes))")
            if !skipped.isEmpty { text += String(localized: "，跳过了 \(skipped.count) 个名称冲突的项目") }
            return text
        case .cancelled:
            return String(localized: "已取消")
        }
    }
}

/// 工具栏上的传输按钮图标：有任务时画一圈进度
@MainActor
enum TransferToolbarIcon {
    static func image(fraction: Double?, failed: Bool) -> NSImage {
        guard let fraction else {
            let image = NSImage(systemSymbolName: failed ? "exclamationmark.arrow.circlepath" : "arrow.down.circle",
                                accessibilityDescription: String(localized: "传输")) ?? NSImage()
            return image
        }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - 1.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.02, fraction)), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            (failed ? NSColor.systemRed : NSColor.controlAccentColor).setStroke()
            arc.stroke()
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
                let tinted = NSImage(size: arrow.size, flipped: false) { r in
                    arrow.draw(in: r)
                    NSColor.labelColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: NSPoint(x: center.x - arrow.size.width / 2, y: center.y - arrow.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.accessibilityDescription = String(localized: "传输")
        return image
    }
}
