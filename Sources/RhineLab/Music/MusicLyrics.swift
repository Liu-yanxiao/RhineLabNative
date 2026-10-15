import Foundation
import Combine

struct MusicLyrics: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        let time: Double?
        let text: String
        let translation: String?
    }
    let lines: [Line]
    var timed: Bool { lines.contains { $0.time != nil } }

    init(_ source: String, translation: String = "") {
        let main = Self.parse(source), translated = Self.parse(translation)
        lines = main.enumerated().map { index, entry in
            let secondary = entry.0.flatMap { time in translated.first { abs(($0.0 ?? -100) - time) < 0.05 }?.1 }
            return Line(id: index, time: entry.0, text: entry.1, translation: secondary == entry.1 ? nil : secondary)
        }
    }

    func activeLine(at time: Double) -> Int? {
        guard timed, time.isFinite else { return nil }
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if (lines[middle].time ?? .infinity) <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower == 0 ? nil : lines[lower - 1].id
    }

    private static func parse(_ source: String) -> [(Double?, String)] {
        let stamps = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:[.:]\d{1,3})?)\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let ns = source as NSString
        let offset = offsetPattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length))
            .flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var timed: [(Double, String)] = [], plain: [String] = []
        for raw in source.components(separatedBy: .newlines) {
            let raw = raw.replacingOccurrences(of: "\u{feff}", with: "").trimmingCharacters(in: .whitespaces)
            let ns = raw as NSString, matches = stamps.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
            guard let last = matches.last else {
                if !raw.isEmpty && !raw.hasPrefix("[") { plain.append(raw) }
                continue
            }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let minute = Double(ns.substring(with: match.range(at: 1))),
                      let second = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")), second < 60 else { continue }
                timed.append((max(0, minute * 60 + second + offset), text))
            }
        }
        guard !timed.isEmpty else { return plain.map { (nil, $0) } }
        // Stable grouping also supports sources with original/translation at identical timestamps.
        timed.sort { $0.0 < $1.0 }
        var grouped: [(Double?, String)] = []
        for entry in timed {
            if let last = grouped.last, last.0 == entry.0 {
                if !last.1.components(separatedBy: "\n").contains(entry.1) { grouped[grouped.count - 1].1 += "\n" + entry.1 }
            } else { grouped.append((entry.0, entry.1)) }
        }
        return grouped
    }
}

protocol MusicLyricsProviding: Sendable {
    func lyrics(_ track: MusicTrack) async throws -> MusicLyrics
}

@MainActor
final class MusicLyricsState: ObservableObject {
    @Published private(set) var document: MusicLyrics?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var request = UUID()

    func load(_ track: MusicTrack, service: any MusicLyricsProviding) async {
        let ticket = UUID(); request = ticket
        document = nil; error = nil; loading = true
        do {
            let result = try await service.lyrics(track)
            guard request == ticket, !Task.isCancelled else { return }
            document = result; loading = false
        } catch {
            guard request == ticket, !Task.isCancelled else { return }
            self.error = "歌词暂时没有加载成功"; loading = false
        }
    }
}
