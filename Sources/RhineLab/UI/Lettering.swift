import SwiftUI
import Foundation

/// Fixed opening phrases drawn from authored glyph outlines (Novecento Sans Wide), as the web
/// version does when the licensed webfont is not installed. Each phrase is a list of letter cells
/// with an em width and an SVG path in a 1000-unit box whose baseline sits at 0.8 em.
struct LetteringArt: Decodable {
    struct Letter: Decodable { let width: Double; let path: String }
    let text: String
    let weight: String
    let units: Double
    let letters: [Letter]
}

enum Lettering {
    static let phrases: [String: LetteringArt] = {
        guard let url = Bundle.main.url(forResource: "boot-lettering", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LetteringArt].self, from: data) else { return [:] }
        return decoded
    }()

    private static var pathCache: [String: Path] = [:]
    private static let lock = NSLock()

    /// The phrase among `keys` whose text begins with `text`.
    static func phrase(for keys: [String], text: String) -> LetteringArt? {
        keys.compactMap { phrases[$0] }.first { $0.text.hasPrefix(text) }
    }

    static func width(_ art: LetteringArt, count: Int, size: CGFloat, tracking: CGFloat) -> CGFloat {
        let n = min(count, art.letters.count)
        guard n > 0 else { return 0 }
        let cells = art.letters.prefix(n).reduce(0.0) { $0 + $1.width }
        return CGFloat(cells) * size + tracking * CGFloat(n - 1)
    }

    /// Parses the absolute M / L / H / V / C / Z commands the artwork uses.
    static func path(_ d: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let hit = pathCache[d] { return hit }
        var p = Path()
        guard !d.isEmpty else { pathCache[d] = p; return p }
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
        var command: Character = "M"
        var current = CGPoint.zero
        func number() -> Double? { scanner.scanDouble() }
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacter(), letter.isLetter {
                command = letter
                if command == "Z" || command == "z" { p.closeSubpath(); continue }
            } else {
                scanner.currentIndex = d.index(before: scanner.currentIndex)
            }
            switch command {
            case "M":
                guard let x = number(), let y = number() else { return finish(p, d) }
                current = CGPoint(x: x, y: y); p.move(to: current); command = "L"
            case "L":
                guard let x = number(), let y = number() else { return finish(p, d) }
                current = CGPoint(x: x, y: y); p.addLine(to: current)
            case "H":
                guard let x = number() else { return finish(p, d) }
                current.x = x; p.addLine(to: current)
            case "V":
                guard let y = number() else { return finish(p, d) }
                current.y = y; p.addLine(to: current)
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return finish(p, d) }
                current = CGPoint(x: x, y: y)
                p.addCurve(to: current, control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            default:
                return finish(p, d)
            }
        }
        return finish(p, d)
    }

    private static func finish(_ p: Path, _ d: String) -> Path { pathCache[d] = p; return p }
}

/// One phrase, revealed up to `text`, at `size` points (the em box) with extra tracking.
struct LetteringText: View {
    let keys: [String]
    let text: String
    let size: CGFloat
    var tracking: CGFloat = 0
    var centeredIn: CGFloat? = nil      // draw centred inside a box this wide
    var color: Color

    private var art: LetteringArt? { Lettering.phrase(for: keys, text: text) }

    var body: some View {
        let art = art
        let count = text.count
        let width = art.map { Lettering.width($0, count: count, size: size, tracking: tracking) } ?? 0
        Canvas { context, area in
            guard let art else { return }
            var x = centeredIn.map { ($0 - width) / 2 } ?? 0
            let k = size / CGFloat(art.units)
            for letter in art.letters.prefix(count) {
                if !letter.path.isEmpty {
                    let glyph = Lettering.path(letter.path).applying(CGAffineTransform(translationX: x, y: 0).scaledBy(x: k, y: k))
                    context.fill(glyph, with: .color(color))
                }
                x += CGFloat(letter.width) * size + tracking
            }
        }
        .frame(width: centeredIn ?? max(1, width), height: size)
    }
}
