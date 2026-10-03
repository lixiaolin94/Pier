import AppKit
import PierKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 所有打开着的浏览窗口（每个 tab 一个）。窗口控制器自己不会被别人强引用，所以在这里持有。
    private var browsers: [BrowserWindowController] = []
    /// 上一次已就绪的设备（持久标识 → 名字），用来发现"拔线"
    private var readyDevices: [String: String] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 新建窗口时默认以 tab 形式加入，行为与 Finder 一致
        NSWindow.allowsAutomaticWindowTabbing = true
        // 和 Finder 一样，正常退出后再打开也回到原来的窗口和 tab（不受系统"退出时关闭窗口"设置影响）
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DeviceManager.shared.start()
        AppUpdater.shared.start()
        _ = Services.transfers
        NotificationCenter.default.addObserver(self, selector: #selector(devicesDidChange(_:)), name: DeviceManager.devicesDidChange, object: nil)
        // 窗口恢复在这之前已经完成；没有恢复出窗口时才新开一个
        if browsers.isEmpty { openBrowser() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openBrowser() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 还有传输没完成时，退出前提醒
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = Services.transfers.pendingTransfers
        guard !pending.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "还有 \(pending.count) 个传输没有完成。")
        alert.informativeText = String(localized: "现在退出会暂停这些传输。下次打开 Pier 后，可以在传输列表里继续未完成的下载。")
        alert.addButton(withTitle: String(localized: "退出"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Services.transfers.pauseAll()
        Services.transfers.saveNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Services.transfers.saveNow()
        DeviceManager.shared.closeAllSessions()
    }

    // MARK: 设备

    @objc private func devicesDidChange(_ note: Notification) {
        Services.transfers.devicesDidChange()
        let now = Dictionary(DeviceManager.shared.devices.filter(\.isReady).map { ($0.persistentID, $0.name) }, uniquingKeysWith: { a, _ in a })
        let gone = readyDevices.filter { now[$0.key] == nil }
        readyDevices = now
        // 拔线时有传输被打断：提示一下，重新连接后会自动继续
        for (id, name) in gone {
            let interrupted = Services.transfers.transfers.filter { $0.deviceID == id && $0.state == .waitingForDevice }
            guard !interrupted.isEmpty else { continue }
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(name)”已断开")
            alert.informativeText = String(localized: "\(interrupted.count) 个传输已暂停，重新连接这台设备后会自动继续。")
            if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: 窗口管理

    /// 创建一个浏览窗口控制器并登记（不显示）
    func makeBrowser(location: BrowserLocation?, restoring stored: StoredLocation? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: location, restoring: stored)
        browsers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.browsers.removeAll { $0 === controller }
        }
        return controller
    }

    /// 打开一个浏览窗口。`tabbedWith` 不为空时作为该窗口的新 tab 加入。
    @discardableResult
    func openBrowser(location: BrowserLocation? = nil, tabbedWith host: NSWindow? = nil) -> BrowserWindowController {
        let controller = makeBrowser(location: location)
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        return controller
    }

    @objc func newBrowserWindow(_ sender: Any?) {
        // ⌘N：新窗口打开当前位置（Finder 行为）。不加入现有 tab 组。
        let current = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.location
        let controller = makeBrowser(location: current)
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.tabbingMode = .preferred
    }

    /// 没有窗口时也能打开传输列表
    @objc func showTransfers(_ sender: Any?) {
        let controller = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? browsers.first ?? openBrowser()
        controller.showTransfers(sender)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "现代的 macOS 原生 Android（MTP）文件传输工具",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
        ])
    }
}
