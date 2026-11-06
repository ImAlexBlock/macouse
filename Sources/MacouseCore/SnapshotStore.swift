import Foundation

/// 原值快照的持久化：`~/Library/Application Support/Macouse/originals.plist`。
///
/// 写指针属性是不可逆操作，快照必须能跨进程存活：CLI 的 `apply` 与 `restore`
/// 是两次独立运行，App 崩溃后重启也要能恢复。
public final class SnapshotStore {
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return base.appendingPathComponent("Macouse", isDirectory: true)
            .appendingPathComponent("originals.plist")
    }

    private let url: URL

    public init(url: URL = SnapshotStore.defaultURL) {
        self.url = url
    }

    public func load() -> [UInt64: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any]
        else {
            return [:]
        }
        var snapshot: [UInt64: [String: Any]] = [:]
        for (key, value) in plist {
            guard let registryID = UInt64(key),
                  let properties = value as? [String: Any] else { continue }
            snapshot[registryID] = properties
        }
        return snapshot
    }

    public func save(_ snapshot: [UInt64: [String: Any]]) {
        guard !snapshot.isEmpty else {
            clear()
            return
        }
        var plist: [String: Any] = [:]
        for (registryID, properties) in snapshot {
            plist[String(registryID)] = properties
        }
        guard PropertyListSerialization.propertyList(plist, isValidFor: .binary) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("snapshot 保存失败: \(error)\n".utf8))
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
