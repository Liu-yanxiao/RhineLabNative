import Foundation
import Combine

@MainActor
final class MusicLibrary: ObservableObject {
    private struct Removed: Codable { let collection: MusicCollection; let tracks: [MusicTrack]; let index: Int }
    private struct Snapshot: Codable {
        var collections: [MusicCollection]?
        var playlists: [String: [MusicTrack]]
        var removed: Removed? = nil
    }
    @Published private(set) var collections: [MusicCollection] = MusicCatalog.defaults
    @Published private(set) var playlists: [String: [MusicTrack]] = [:]
    @Published private(set) var storageError: String?
    var onChange: (() -> Void)?
    private let storageURL: URL?
    private var removed: Removed?
    var canUndoDeletion: Bool { removed != nil }

    init(storageURL: URL? = MusicLibrary.defaultStorage, migrate: Bool = true, includeBuiltins: Bool = false) {
        self.storageURL = storageURL
        var snapshot: Snapshot?
        if let storageURL, let data = try? Data(contentsOf: storageURL) { snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) }
        if snapshot == nil, migrate, storageURL != nil {
            let root = Self.defaultStorage?.deletingLastPathComponent()
            for file in [root?.appendingPathComponent("online-player/library.json"), root?.appendingPathComponent("MusicLibrary.json")] {
                if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    snapshot = decoded; break
                }
            }
        }
        if let snapshot {
            removed = snapshot.removed
            collections = snapshot.collections ?? MusicCatalog.defaults
            // Only explicit playlists/likes are migrated. Old generated channel caches stay in the old file.
            for item in collections { playlists[item.id] = Self.unique(snapshot.playlists[item.id] ?? []) }
        }
        if !collections.contains(where: { $0.id == "favorites" }) { collections.insert(MusicCatalog.defaults[0], at: 0) }
        if includeBuiltins {
            for seed in MusicBuiltin.load() {
                if !collections.contains(where: { $0.id == seed.collection.id }) { collections.append(seed.collection) }
                if playlists[seed.collection.id] == nil { playlists[seed.collection.id] = seed.tracks }
            }
        }
        MusicCatalog.install(collections, playlists: playlists)
    }

    nonisolated static var defaultStorage: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RhineLab/MusicLibrary-v4.json")
    }
    private static func unique(_ tracks: [MusicTrack]) -> [MusicTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
    func tracks(_ collection: MusicCollection) -> [MusicTrack] { playlists[collection.id] ?? [] }
    var liked: Set<String> { Set((playlists["favorites"] ?? []).map(\.id)) }
    var count: Int { Set(playlists.values.flatMap { $0 }.map(\.id)).count }
    var editable: [MusicCollection] { collections.filter { $0.kind == .custom } }

    @discardableResult
    func create(_ title: String) -> MusicCollection? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let item = MusicCollection(id: UUID().uuidString, title: String(title.prefix(60)), subtitle: "")
        collections.append(item); changed(); return item
    }
    func rename(_ collection: MusicCollection, to title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collection.kind == .custom, !text.isEmpty, let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].title = String(text.prefix(60)); changed()
    }
    func toggleLike(_ track: MusicTrack) {
        if liked.contains(track.id) { playlists["favorites"]?.removeAll { $0.id == track.id } }
        else { playlists["favorites", default: []].insert(track, at: 0) }
        changed()
    }
    func add(_ track: MusicTrack, to collection: MusicCollection) {
        guard !tracks(collection).contains(where: { $0.id == track.id }) else { return }
        playlists[collection.id, default: []].append(track); changed()
    }
    func remove(_ track: MusicTrack, from collection: MusicCollection) {
        playlists[collection.id]?.removeAll { $0.id == track.id }; changed()
    }
    func delete(_ collection: MusicCollection) {
        guard collection.kind == .custom, let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        removed = Removed(collection: collection, tracks: tracks(collection), index: index)
        collections.remove(at: index); playlists.removeValue(forKey: collection.id); changed()
    }
    func undoDeletion() {
        guard let removed else { return }
        collections.insert(removed.collection, at: min(removed.index, collections.count)); playlists[removed.collection.id] = removed.tracks
        self.removed = nil; changed()
    }
    private func changed() {
        MusicCatalog.install(collections, playlists: playlists)
        if let storageURL {
            do {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Snapshot(collections: collections, playlists: playlists, removed: removed)).write(to: storageURL, options: .atomic)
                storageError = nil
            } catch { storageError = "歌单保存失败：\(error.localizedDescription)" }
        }
        onChange?()
    }
}
