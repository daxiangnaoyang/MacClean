import Foundation

struct ScanPreferences: Codable, Equatable {
    var version = 1
    var roots: [String]
    var options: ScanOptions
    var bookmarks: [String: Data] = [:]
}

struct ScanPreferencesStore {
    let url: URL
    func load() throws -> ScanPreferences? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ScanPreferences.self, from: Data(contentsOf: url))
        guard value.version == 1, value.options.entryLimit >= 0, value.options.maxDepth >= 0,
              value.roots.allSatisfy({ $0.hasPrefix("/") }) else { throw cleanError("扫描设置格式不受支持") }
        return value
    }
    func save(_ value: ScanPreferences) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Keep an explicitly granted URL alive for the model's lifetime, then balance access.
// No panel is opened while restoring bookmarks or scanning.
final class DirectoryGrant {
    let url: URL
    private let accessed: Bool
    init(_ url: URL) { self.url = url; accessed = url.startAccessingSecurityScopedResource() }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
    static func restore(_ data: Data) throws -> (grant: DirectoryGrant, refreshed: Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let grant = DirectoryGrant(url)
        let renewed = stale ? try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return (grant, renewed)
    }
}
