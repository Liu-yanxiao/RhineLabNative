import Foundation

/// A bounded window keeps long search queues away from the adjacent playlist controls.
enum MusicRail {
    static func window(count: Int, selected: Int, limit: Int = 15) -> Range<Int> {
        let count = max(0, count), limit = max(1, limit)
        let start = min(max(0, selected - limit / 2), max(0, count - limit))
        return start..<min(count, start + limit)
    }
}
