import AppKit
import PierKit
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

/// 设备、存储的符号图标（侧边栏和路径栏共用）。
///
/// 和磁盘工具一样只表达层级、不猜设备种类：MTP/PTP 设备可能是手机、平板、相机、游戏机……
/// 按厂商或存储名字猜图标迟早会猜错，具体是什么交给名字说明。
@MainActor
enum DeviceSymbols {
    /// 一台连接着的设备
    static func name(for device: MTPDevice) -> String { "externaldrive.connected.to.line.below" }

    /// 设备上的一个存储（卷）
    static func name(for storage: MTPStorage) -> String { "internaldrive" }

    /// 固定 16×16 的方形图标，符号按原比例居中。
    /// NSPathControl 会把每项的图片缩放成正方形，直接给符号图片时竖长的符号（手机、存储卡）会被拉宽。
    static func squareIcon(_ name: String, side: CGFloat = 16) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let s = symbol.size
            let scale = min(rect.width / s.width, rect.height / s.height, 1)
            let w = s.width * scale, h = s.height * scale
            symbol.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
        image.isTemplate = true   // 跟随路径栏的文字颜色
        return image
    }
}
