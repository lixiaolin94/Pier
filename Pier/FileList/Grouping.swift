import AppKit
import PierKit

/// Finder 式「群组」：把排好序的项目分成若干段，组内保持当前排序
enum FileGrouping: String, CaseIterable {
    case none, name, kind, size, date

    var title: String {
        switch self {
        case .none: String(localized: "无")
        case .name: String(localized: "名称")
        case .kind: String(localized: "种类")
        case .size: String(localized: "大小")
        case .date: String(localized: "修改日期")
        }
    }

    /// 与 Finder 相同的快捷键：⌃⌘0 不分组，⌃⌘1 名称，⌃⌘2 种类，⌃⌘6 修改日期，⌃⌘7 大小
    var keyEquivalent: String {
        switch self {
        case .none: "0"
        case .name: "1"
        case .kind: "2"
        case .date: "6"
        case .size: "7"
        }
    }
}

/// 一组项目
@MainActor
final class FileGroup: NSObject {
    let title: String
    let nodes: [FileNode]

    init(title: String, nodes: [FileNode]) {
        self.title = title
        self.nodes = nodes
    }
}

@MainActor
enum Grouper {
    /// 分组。`nodes` 已经按当前规则排好序；返回的组按各分组方式的自然顺序排列。
    static func group(_ nodes: [FileNode], by grouping: FileGrouping) -> [FileGroup] {
        guard grouping != .none, !nodes.isEmpty else { return [FileGroup(title: "", nodes: nodes)] }
        var buckets: [String: [FileNode]] = [:]
        var order: [String: Int] = [:]
        for node in nodes {
            let (key, rank) = bucket(of: node, by: grouping)
            buckets[key, default: []].append(node)
            order[key] = rank
        }
        return buckets.keys
            .sorted { (order[$0]!, $0) < (order[$1]!, $1) }
            .map { FileGroup(title: $0, nodes: buckets[$0]!) }
    }

    /// 某个项目所在的组名，以及组之间的排序权重（小的在前）
    private static func bucket(of node: FileNode, by grouping: FileGrouping) -> (String, Int) {
        switch grouping {
        case .none:
            return ("", 0)
        case .name:
            return nameBucket(node.name)
        case .kind:
            if node.isFolder { return (String(localized: "文件夹"), 0) }
            return (FileTypes.kind(forName: node.name, isFolder: false), 1)
        case .size:
            if node.isFolder { return (String(localized: "文件夹"), 0) }
            let mb: UInt64 = 1 << 20
            switch node.object.size {
            case 0: return (String(localized: "零字节"), 1)
            case ..<mb: return (String(localized: "小于 1 MB"), 2)
            case ..<(100 * mb): return (String(localized: "1 MB 到 100 MB"), 3)
            case ..<(1024 * mb): return (String(localized: "100 MB 到 1 GB"), 4)
            case ...0xFFFF_FFFF: return (String(localized: "1 GB 到 4 GB"), 5)
            default: return (String(localized: "大于 4 GB"), 6)   // FAT32 放不下、DBI 要分段写的文件
            }
        case .date:
            guard let date = node.object.modified else { return (String(localized: "无日期"), 99) }
            let calendar = Calendar.current
            if calendar.isDateInToday(date) { return (String(localized: "今天"), 0) }
            if calendar.isDateInYesterday(date) { return (String(localized: "昨天"), 1) }
            let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if days < 7 { return (String(localized: "过去 7 天"), 2) }
            if days < 30 { return (String(localized: "过去 30 天"), 3) }
            let year = calendar.component(.year, from: date)
            if year == calendar.component(.year, from: Date()) { return (String(localized: "今年早些时候"), 4) }
            return (String(year), 10 + (3000 - year))   // 年份越近越靠前
        }
    }

    /// 首字母：英文按字母，中文按拼音首字母，数字一组，其余归到 #
    private static func nameBucket(_ name: String) -> (String, Int) {
        let trimmed = name.drop { $0 == "." || $0 == "_" || $0 == " " }
        guard let first = trimmed.first else { return ("#", 2) }
        if first.isNumber { return ("0–9", 1) }
        var latin = String(first)
        if !first.isASCII {
            latin = latin.applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) ?? latin
        }
        if let letter = latin.uppercased().first, letter.isASCII, letter.isLetter { return (String(letter), 0) }
        return ("#", 2)
    }
}
