import Foundation

struct ArchiveRecord: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let en: String
    let department: String
    let category: String
    let date: String
    let lead: String
    let clearance: String
    let abstract: String
    let findings: [String]
    let source: String
}

private struct ArchiveContent: Codable {
    let categories: [String]
    let columns: [String]
    let records: [ArchiveRecord]
}

/// A position in the unbounded, looping archive grid.
struct Cell: Hashable {
    var lane: Int
    var row: Int
}

/// Static archive data plus the lane / row mapping used by the array.
enum Archive {
    private static let content: ArchiveContent = {
        guard let url = Bundle.main.url(forResource: "archives", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ArchiveContent.self, from: data)
        else { fatalError("archives.json missing from bundle") }
        return decoded
    }()

    static var records: [ArchiveRecord] { content.records }
    static var categories: [String] { ["全部档案"] + content.categories }
    static var columns: [String] { content.columns }

    static func columnFiles(_ lane: Int) -> [Int] {
        records.enumerated()
            .filter { $0.element.category == columns[lane] }
            .map(\.offset)
    }

    /// Canonical lane and row; real files occupy rows 12...19 of each lane.
    static func location(of index: Int) -> (lane: Int, row: Int) {
        let lane = columns.firstIndex(of: records[index].category) ?? 0
        let row = 12 + (columnFiles(lane).firstIndex(of: index) ?? 0)
        return (lane, row)
    }

    static func wrap(_ value: Int, _ count: Int) -> Int {
        ((value % count) + count) % count
    }

    static func file(at cell: Cell) -> Int {
        let files = columnFiles(wrap(cell.lane, columns.count))
        return files[wrap(cell.row - 12, files.count)]
    }
}

enum ArchiveNavigation {
    case row(Int)
    case lane(Int)
    case cell(Cell)
}

enum Loop {
    static let columns = 9
    static let rows = 32
    static let columnSpacing: Float = 5.2
    static let rowSpacing: Float = 0.62
    static let poolLanes = [0, 1, 2, 3, 4, -2, -1, 5, 6]

    static func poolCell(_ index: Int) -> Cell {
        Cell(lane: poolLanes[index / rows], row: index % rows)
    }

    static func visibleCell(_ index: Int, centerLane: Double, centerRow: Double) -> Cell {
        Cell(
            lane: nearest(poolLanes[index / rows], centerLane, columns),
            row: nearest(index % rows, centerRow, rows)
        )
    }

    /// The occurrence of `value` (repeating every `period`) closest to `center`.
    static func nearest(_ value: Int, _ center: Double, _ period: Int) -> Int {
        value + Int(floor((center - Double(value) + Double(period) / 2) / Double(period))) * period
    }

    static func selectionCell(for index: Int, current: Cell, navigation: ArchiveNavigation?) -> Cell {
        if case .cell(let cell) = navigation { return cell }
        let next = Archive.location(of: index)
        let files = Archive.columnFiles(next.lane).count
        let row = nearest(next.row, Double(current.row), files)
        switch navigation {
        case .row(let direction):
            return Cell(lane: current.lane, row: current.row + direction)
        case .lane(let direction):
            return Cell(lane: current.lane + direction, row: row)
        default:
            return Cell(lane: nearest(next.lane, Double(current.lane), Archive.columns.count), row: row)
        }
    }
}
