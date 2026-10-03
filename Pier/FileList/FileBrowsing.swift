import AppKit
import PierKit

/// 列表视图、图标视图的宿主（内容区）：数据、操作、拖放都由它统一处理，两种视图只负责呈现与交互
@MainActor
protocol FileViewHost: AnyObject {
    var contents: FolderContents { get }
    func open(_ node: FileNode, inNewTab: Bool)
    func selectionDidChange()
    func populateContextMenu(_ menu: NSMenu, for nodes: [FileNode])
    func pasteboardWriter(for node: FileNode) -> NSPasteboardWriting?
    /// `node` 为 nil 表示放到当前文件夹
    func validateDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> NSDragOperation
    func acceptDrop(_ info: NSDraggingInfo, onto node: FileNode?) -> Bool
    func renameProblem(_ node: FileNode, to name: String) -> String?
    func commitRename(_ node: FileNode, to name: String)
}

/// 一种文件视图（列表 / 图标）
@MainActor
protocol FileBrowsingView: NSViewController {
    var host: FileViewHost? { get set }
    var selectedNodes: [FileNode] { get }
    /// 右键点在未选中的项目上时，操作对象是被点的那个（Finder 行为）
    var actionNodes: [FileNode] { get }
    func contentsDidChange(_ change: FolderContents.Change)
    func select(_ nodes: [FileNode])
    func beginRename(_ node: FileNode)
    /// 让视图成为第一响应者
    func focus()
    /// 某个项目在屏幕上的位置（Quick Look 缩放动画用）
    func screenRect(for node: FileNode) -> NSRect?
}

/// 视图里共用的键盘操作
@MainActor
enum FileViewKeys {
    /// 处理了返回 true
    static func handle(_ event: NSEvent, from view: NSView) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.specialKey == .downArrow {
            NSApp.sendAction(#selector(BrowserActions.openSelection(_:)), to: nil, from: view)
            return true
        }
        if flags.isEmpty || flags == .function {
            switch event.keyCode {
            case 49:   // 空格：Quick Look
                NSApp.sendAction(#selector(BrowserActions.quickLook(_:)), to: nil, from: view)
                return true
            case 36, 76:   // 回车：改名（Finder 行为）
                NSApp.sendAction(#selector(BrowserActions.renameSelection(_:)), to: nil, from: view)
                return true
            default:
                break
            }
        }
        return false
    }
}

extension NSTextField {
    /// 选中文件名中扩展名之前的部分（Finder 改名时的行为）
    func selectBaseName() {
        guard let editor = currentEditor() else { return }
        let name = stringValue as NSString
        let ext = name.pathExtension
        let length = ext.isEmpty || name.length == ext.count + 1 ? name.length : name.length - ext.count - 1
        editor.selectedRange = NSRange(location: 0, length: length)
    }
}
