import Foundation

/// Bridges playback to the displayed archive. The transient queue never writes to the library.
@MainActor
final class MusicPresentation {
    private let library: MusicLibrary
    private let player: MusicPlayer
    private var selectedID = "favorites"
    var onSelection: ((Int, Bool) -> Void)?
    private(set) var selectedIndex = 0

    init(library: MusicLibrary, player: MusicPlayer) {
        self.library = library; self.player = player
        selectedIndex = MusicCatalog.items.firstIndex { $0.collection?.id == "builtin-arknights" && $0.track != nil }
            ?? MusicCatalog.items.firstIndex { $0.track != nil } ?? 0
        selectedID = MusicCatalog.items[selectedIndex].id
        player.onTrackChanged = { [weak self] track in
            guard let self, let track else { return }
            let previous = MusicCatalog.items.map(\.id)
            if self.player.collectionID == nil || self.player.collectionID == MusicCatalog.searchCollection.id {
                MusicCatalog.presentQueue(self.player.contextTracks)
            }
            let id = self.player.collectionID ?? MusicCatalog.searchCollection.id
            self.selectedID = MusicCatalog.items.first { $0.collection?.id == id && $0.track?.id == track.id }?.id ?? self.selectedID
            self.refresh(catalogueChanged: previous != MusicCatalog.items.map(\.id))
        }
        library.onChange = { [weak self] in self?.refresh(catalogueChanged: true) }
    }

    func select(_ index: Int) {
        let items = MusicCatalog.items
        guard items.indices.contains(index) else { return }
        selectedIndex = index; selectedID = items[index].id
    }

    func locatePlaying() {
        guard let track = player.current else { return }
        let id = player.collectionID ?? MusicCatalog.searchCollection.id
        selectedID = MusicCatalog.items.first { $0.collection?.id == id && $0.track?.id == track.id }?.id ?? selectedID
        refresh(catalogueChanged: false)
    }

    private func refresh(catalogueChanged: Bool) {
        selectedIndex = MusicCatalog.items.firstIndex { $0.id == selectedID } ?? 0
        onSelection?(selectedIndex, catalogueChanged)
    }
}
