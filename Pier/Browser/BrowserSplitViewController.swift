import AppKit

/// 侧边栏 + 内容区
@MainActor
final class BrowserSplitViewController: NSSplitViewController {
    weak var browser: BrowserWindowController? {
        didSet {
            sidebar.browser = browser
            content.browser = browser
        }
    }

    let sidebar = SidebarViewController()
    let content = ContentViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360
        addSplitViewItem(contentItem)

        splitView.autosaveName = "PierBrowserSplit"
    }

    func show(_ location: BrowserLocation?, forceReload: Bool = false) {
        _ = view   // 确保子控制器已加载
        sidebar.select(location)
        content.show(location, forceReload: forceReload)
    }
}
