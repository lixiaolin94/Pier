import AppKit

/// 主菜单。快捷键尽量与 Finder 一致。target 为 nil 的项沿响应链分发，由当前窗口/视图决定是否可用。
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = NSMenu(title: String(localized: "帮助"))
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }

    private static func appMenu() -> NSMenu {
        let name = "Pier"
        let m = NSMenu(title: name)
        m.addItem(item(String(localized: "关于 \(name)"), #selector(AppDelegate.showAboutPanel(_:))))
        let update = item(String(localized: "检查更新…"), #selector(AppUpdater.checkForUpdates(_:)))
        update.target = AppUpdater.shared
        m.addItem(update)
        m.addItem(.separator())
        m.addItem(item(String(localized: "设置…"), nil, ","))
        m.addItem(.separator())
        let services = NSMenu(title: String(localized: "服务"))
        let servicesItem = item(String(localized: "服务"), nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        m.addItem(servicesItem)
        m.addItem(.separator())
        m.addItem(item(String(localized: "隐藏 \(name)"), #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item(String(localized: "全部显示"), #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "退出 \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "文件"))
        m.addItem(item(String(localized: "新建窗口"), #selector(AppDelegate.newBrowserWindow(_:)), "n"))
        m.addItem(item(String(localized: "新建文件夹"), #selector(BrowserActions.newFolder(_:)), "n", [.command, .shift]))
        m.addItem(item(String(localized: "新建标签页"), #selector(NSResponder.newWindowForTab(_:)), "t"))
        m.addItem(item(String(localized: "打开"), #selector(BrowserActions.openSelection(_:)), "o"))
        m.addItem(item(String(localized: "在新标签页中打开"), #selector(BrowserActions.openSelectionInNewTab(_:))))
        m.addItem(item(String(localized: "关闭窗口"), #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "显示简介"), #selector(BrowserActions.getInfo(_:)), "i"))
        m.addItem(item(String(localized: "重新命名"), #selector(BrowserActions.renameSelection(_:))))
        m.addItem(item(String(localized: "快速查看"), #selector(BrowserActions.quickLook(_:)), "y"))
        m.addItem(item(String(localized: "显示所在文件夹"), #selector(BrowserActions.showEnclosingFolder(_:)), "r"))
        m.addItem(item(String(localized: "下载到…"), #selector(BrowserActions.downloadSelection(_:)), "d", [.command, .shift]))
        m.addItem(item(String(localized: "上传…"), #selector(BrowserActions.upload(_:)), "u", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "删除"), #selector(BrowserActions.deleteSelection(_:)), "\u{8}"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "重新连接设备"), #selector(BrowserActions.reconnectDevice(_:))))
        m.addItem(item(String(localized: "推出"), #selector(BrowserActions.ejectDevice(_:)), "e"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "编辑"))
        m.addItem(item(String(localized: "撤销"), Selector(("undo:")), "z"))
        m.addItem(item(String(localized: "重做"), Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "剪切"), #selector(NSText.cut(_:)), "x"))
        m.addItem(item(String(localized: "拷贝"), #selector(NSText.copy(_:)), "c"))
        m.addItem(item(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v"))
        m.addItem(item(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "查找"), #selector(BrowserActions.focusSearch(_:)), "f"))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "显示"))
        m.addItem(item(String(localized: "图标"), #selector(BrowserActions.showAsIcons(_:)), "1"))
        m.addItem(item(String(localized: "列表"), #selector(BrowserActions.showAsList(_:)), "2"))
        m.addItem(item(String(localized: "分栏"), #selector(BrowserActions.showAsColumns(_:)), "3"))
        m.addItem(item(String(localized: "画廊"), #selector(BrowserActions.showAsGallery(_:)), "4"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "显示隐藏文件"), #selector(BrowserActions.toggleHiddenFiles(_:)), ".", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "显示标签页栏"), #selector(NSWindow.toggleTabBar(_:)), "t", [.command, .shift]))
        m.addItem(item(String(localized: "显示所有标签页"), #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "显示路径栏"), #selector(BrowserActions.togglePathBar(_:)), "p", [.command, .option]))
        m.addItem(item(String(localized: "显示状态栏"), #selector(BrowserActions.toggleStatusBar(_:)), "/"))
        m.addItem(item(String(localized: "显示边栏"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "自定工具栏…"), #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        m.addItem(item(String(localized: "进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func goMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "前往"))
        m.addItem(item(String(localized: "返回"), #selector(BrowserActions.goBack(_:)), "["))
        m.addItem(item(String(localized: "前进"), #selector(BrowserActions.goForward(_:)), "]"))
        m.addItem(item(String(localized: "上层文件夹"), #selector(BrowserActions.goToEnclosingFolder(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "刷新"), #selector(BrowserActions.reload(_:)), "r", [.command, .shift]))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "窗口"))
        m.addItem(item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item(String(localized: "缩放"), #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "显示上一个标签页"), #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        m.addItem(item(String(localized: "显示下一个标签页"), #selector(NSWindow.selectNextTab(_:)), "\t", .control))
        m.addItem(item(String(localized: "将标签页移到新窗口"), #selector(NSWindow.moveTabToNewWindow(_:))))
        m.addItem(item(String(localized: "合并所有窗口"), #selector(NSWindow.mergeAllWindows(_:))))
        m.addItem(.separator())
        m.addItem(item(String(localized: "传输"), #selector(AppDelegate.showTransfers(_:)), "l", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}

/// 沿响应链分发的浏览器动作。用 @objc 协议声明 selector，让菜单与实现解耦；各响应者只实现自己处理的那部分。
@MainActor @objc protocol BrowserActions {
    @objc optional func newFolder(_ sender: Any?)
    @objc optional func openSelection(_ sender: Any?)
    @objc optional func openSelectionInNewTab(_ sender: Any?)
    @objc optional func getInfo(_ sender: Any?)
    @objc optional func downloadSelection(_ sender: Any?)
    @objc optional func upload(_ sender: Any?)
    @objc optional func deleteSelection(_ sender: Any?)
    @objc optional func ejectDevice(_ sender: Any?)
    @objc optional func focusSearch(_ sender: Any?)
    @objc optional func showAsIcons(_ sender: Any?)
    @objc optional func showAsList(_ sender: Any?)
    @objc optional func showAsColumns(_ sender: Any?)
    @objc optional func toggleHiddenFiles(_ sender: Any?)
    @objc optional func showAsGallery(_ sender: Any?)
    @objc optional func togglePathBar(_ sender: Any?)
    @objc optional func toggleStatusBar(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    @objc optional func goToEnclosingFolder(_ sender: Any?)
    @objc optional func reload(_ sender: Any?)
    @objc optional func renameSelection(_ sender: Any?)
    @objc optional func quickLook(_ sender: Any?)
    @objc optional func showEnclosingFolder(_ sender: Any?)
    @objc optional func reconnectDevice(_ sender: Any?)
}
