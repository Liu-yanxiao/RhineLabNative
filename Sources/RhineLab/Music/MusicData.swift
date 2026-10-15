import Foundation

enum Experience {
    static let music = !CommandLine.arguments.contains("--archive")
}

struct MusicTrack: Codable, Identifiable, Equatable, Hashable {
    let songID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artwork: URL?
    var platform = "wy"
    var id: String { platform + ":" + songID }
    var time: String { duration > 0 ? Self.clock(duration) : "—" }

    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MusicCollection: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case favorites, custom, builtin, temporary }
    let id: String
    var title: String
    var subtitle: String
    var kind: Kind = .custom
    var english: String { kind == .favorites ? "FAVORITES" : "PLAYLIST" }
}

struct MusicSceneItem: Identifiable, Equatable {
    let collection: MusicCollection?
    let track: MusicTrack?
    var id: String { (collection?.id ?? "search-session") + "|" + (track?.id ?? "empty") }
    var title: String { track?.title ?? collection!.title }
    var subtitle: String { track?.artist ?? collection!.subtitle }
    var artwork: URL? { track?.artwork }
}

enum MusicCatalog {
    private static let lock = NSLock()
    private static var lists = defaults
    private static var tracklists: [String: [MusicTrack]] = [:]
    private static var searchTracks: [MusicTrack] = []
    private static var sceneItems = defaults.map { MusicSceneItem(collection: $0, track: nil) }
    private static var cachedContent = makeContent(defaults, sceneItems)
    static let defaults: [MusicCollection] = [
        .init(id: "favorites", title: "喜欢的音乐", subtitle: "收藏的歌曲", kind: .favorites),
        .init(id: "custom", title: "我的歌单", subtitle: "自己的音乐收藏"),
    ]
    static let searchCollection = MusicCollection(id: "search-session", title: "搜索试听", subtitle: "当前搜索结果", kind: .temporary)
    private static var visibleLists: [MusicCollection] { lists + (searchTracks.isEmpty ? [] : [searchCollection]) }
    static var collections: [MusicCollection] { lock.lock(); defer { lock.unlock() }; return visibleLists }
    static var queue: [MusicTrack] { lock.lock(); defer { lock.unlock() }; return searchTracks }
    static var items: [MusicSceneItem] { lock.lock(); defer { lock.unlock() }; return sceneItems }
    static func tracks(_ collection: MusicCollection) -> [MusicTrack] {
        lock.lock(); defer { lock.unlock() }
        return collection.kind == .temporary ? searchTracks : tracklists[collection.id] ?? []
    }
    static func install(_ collections: [MusicCollection], playlists: [String: [MusicTrack]] = [:]) {
        lock.lock(); defer { lock.unlock() }
        lists = collections.isEmpty ? defaults : collections
        tracklists = playlists
        rebuild()
    }
    static func presentQueue(_ tracks: [MusicTrack]) {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        searchTracks = tracks.filter { seen.insert($0.id).inserted }
        rebuild()
    }
    private static func rebuild() {
        let columns = visibleLists
        sceneItems = columns.flatMap { collection -> [MusicSceneItem] in
            let tracks = collection.kind == .temporary ? searchTracks : tracklists[collection.id] ?? []
            return tracks.isEmpty ? [MusicSceneItem(collection: collection, track: nil)] : tracks.map { MusicSceneItem(collection: collection, track: $0) }
        }
        cachedContent = makeContent(columns, sceneItems)
    }
    static var columns: [String] { archiveContent.columns }
    static var archiveContent: ArchiveContent { lock.lock(); defer { lock.unlock() }; return cachedContent }
    private static func makeContent(_ columns: [MusicCollection], _ items: [MusicSceneItem]) -> ArchiveContent {
        let records = items.map { item in
            ArchiveRecord(id: item.id, title: item.title, en: item.track?.album ?? item.collection!.english, department: item.subtitle,
                          category: item.collection!.id, date: "", lead: "", clearance: "", abstract: item.subtitle,
                          findings: [], source: item.track?.platform == "msr" ? "https://monster-siren.hypergryph.com/music" : "https://music.163.com")
        }
        return ArchiveContent(categories: columns.map(\.id), columns: columns.map(\.id), records: records)
    }
}

struct MusicBuiltin: Codable {
    let collection: MusicCollection
    let tracks: [MusicTrack]
    private struct Catalog: Decodable { let playlists: [MusicBuiltin] }
    static func load() -> [MusicBuiltin] {
        guard let url = Bundle.main.url(forResource: "music-playlists", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.playlists
    }
}

enum MusicSource: String, CaseIterable, Codable {
    case xinghai, hyw
    var label: String { self == .xinghai ? "星海" : "HYW" }
    var alternate: MusicSource { self == .xinghai ? .hyw : .xinghai }
}

protocol MusicProviding: Sendable {
    func search(_ keyword: String) async throws -> [MusicTrack]
    func resolve(_ track: MusicTrack, source: MusicSource) async throws -> URL
}

enum MusicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
