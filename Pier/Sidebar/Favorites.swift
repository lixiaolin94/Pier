import Foundation

/// 侧边栏「收藏」：按设备持久标识 + 路径名字记住，设备重连后照样能用
@MainActor
final class Favorites {
    static let shared = Favorites()
    static let didChange = Notification.Name("work.xiaolin.Pier.favoritesDidChange")

    private(set) var items: [StoredLocation] = []
    private let url = AppPaths.support.appendingPathComponent("favorites.json")

    private init() {
        if let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([StoredLocation].self, from: data) {
            self.items = items
        }
    }

    func add(_ location: StoredLocation) {
        guard !items.contains(location) else { return }
        items.append(location)
        save()
    }

    func remove(_ location: StoredLocation) {
        items.removeAll { $0 == location }
        save()
    }

    func move(from index: Int, to destination: Int) {
        guard items.indices.contains(index) else { return }
        let item = items.remove(at: index)
        items.insert(item, at: min(destination > index ? destination - 1 : destination, items.count))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
