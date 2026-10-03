import AppKit
import PierKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 所有打开着的浏览窗口（每个 tab 一个）。窗口控制器自己不会被别人强引用，所以在这里持有。
    private var browsers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新建窗口时默认以 tab 形式加入，行为与 Finder 一致
        NSWindow.allowsAutomaticWindowTabbing = true
        DeviceManager.shared.start()
        openBrowser()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openBrowser() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: 窗口管理

    /// 打开一个浏览窗口。`tabbedWith` 不为空时作为该窗口的新 tab 加入。
    @discardableResult
    func openBrowser(location: BrowserLocation? = nil, tabbedWith host: NSWindow? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: location)
        browsers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.browsers.removeAll { $0 === controller }
        }
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
        let controller = BrowserWindowController(location: current)
        controller.window?.tabbingMode = .disallowed
        browsers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.browsers.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
        controller.window?.tabbingMode = .preferred
    }

    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "现代的 macOS 原生 Android（MTP）文件传输工具",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
        ])
    }
}
