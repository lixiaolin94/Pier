import AppKit
import PierKit

/// 用对话框改名（图标、分栏、画廊视图用；列表视图是行内改名）
@MainActor
enum RenamePrompt {
    static func run(_ node: FileNode, in window: NSWindow, host: FileViewHost?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "重新命名“\(node.name)”")
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "重新命名"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak host] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                host?.commitRename(node, to: field.stringValue)
            }
        }
        DispatchQueue.main.async { field.selectBaseName() }
    }
}

/// 缩略图请求：同一个节点只请求一次，换文件夹时取消不再需要的
@MainActor
final class ThumbnailRequests {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// 生成好后回调（只在成功时）
    func request(_ node: FileNode, device: MTPDevice?, size: CGFloat, completion: @escaping @MainActor (FileNode) -> Void) {
        let id = ObjectIdentifier(node)
        guard node.thumbnail == nil, tasks[id] == nil, let device, LocalCopies.shared.canThumbnail(node.object) else { return }
        tasks[id] = Task { [weak self, weak node] in
            guard let object = node?.object else { return }
            let image = await LocalCopies.shared.thumbnail(for: object, on: device, size: CGSize(width: size, height: size))
            guard let self, let node, !Task.isCancelled else { return }
            self.tasks[id] = nil
            guard let image else { return }
            node.thumbnail = image
            completion(node)
        }
    }

    /// 只保留这些节点的请求
    func keep(only nodes: [FileNode]) {
        let alive = Set(nodes.map(ObjectIdentifier.init))
        for (id, task) in tasks where !alive.contains(id) {
            task.cancel()
            tasks[id] = nil
        }
    }
}

extension FileNode {
    /// 显示用的图标：有缩略图用缩略图
    @MainActor var displayIcon: NSImage { thumbnail ?? FileTypes.icon(forName: name, isFolder: isFolder) }

    /// "种类 · 大小"
    @MainActor var kindAndSize: String {
        let kind = FileTypes.kind(forName: name, isFolder: isFolder)
        return isFolder ? kind : "\(kind) · \(Format.bytes(object.size))"
    }
}
