import AppKit
import UniformTypeIdentifiers

@MainActor
enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func bytes(_ n: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(clamping: n)) }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func date(_ d: Date?) -> String { d.map(dateFormatter.string(from:)) ?? "--" }
}

/// 文件图标与"种类"描述，按扩展名缓存
@MainActor
enum FileTypes {
    private static var iconCache: [String: NSImage] = [:]
    private static var kindCache: [String: String] = [:]

    static func type(forName name: String) -> UTType {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    static func icon(forName name: String, isFolder: Bool) -> NSImage {
        let key = isFolder ? "/folder" : (name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: isFolder ? .folder : type(forName: name))
        iconCache[key] = image
        return image
    }

    static func kind(forName name: String, isFolder: Bool) -> String {
        if isFolder { return String(localized: "文件夹") }
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = kindCache[ext] { return cached }
        let type = type(forName: name)
        let kind: String
        if ext.isEmpty {
            kind = String(localized: "文稿")
        } else if type.isDynamic || type == .data {
            kind = String(localized: "\(ext.uppercased()) 文件")
        } else {
            kind = type.localizedDescription ?? String(localized: "\(ext.uppercased()) 文件")
        }
        kindCache[ext] = kind
        return kind
    }
}
