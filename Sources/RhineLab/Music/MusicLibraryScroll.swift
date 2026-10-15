import AppKit

/// Lock one of the shelf’s two diagonal axes for the lifetime of a gesture.
struct MusicLibraryScroll {
    enum Action: Equatable { case none, song(Int), column(Int) }
    private enum Axis { case undecided, vertical, horizontal }
    private var axis = Axis.undecided
    private var travel = CGPoint.zero
    private var diagonal = false
    private var songTravel: CGFloat = 0
    private var committed = false
    private var lastEvent: TimeInterval = -1
    private var lastMouseColumn: TimeInterval = -1

    mutating func consume(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                          precise: Bool, time: TimeInterval) -> Action {
        if !momentum.isEmpty {
            // Vertical browsing retains its continuous scrolling; never infer a new axis from inertia.
            guard axis == .vertical else { return .none }
            return stepSong(diagonal ? (dx - dy) * 0.7071 : dy)
        }
        let phaseLess = phase.isEmpty
        if phase.contains(.began) || (phaseLess && (time - lastEvent > 0.25 || !precise)) {
            axis = .undecided; travel = .zero; songTravel = 0; committed = false; diagonal = false
        }
        lastEvent = time
        travel.x += dx; travel.y += dy
        if axis == .undecided {
            let x = abs(travel.x), y = abs(travel.y)
            guard !precise || max(x, y) >= 8 else { return .none }
            // Straight mouse/trackpad travel remains a useful fallback. Diagonal travel
            // projects onto ↖↘ (songs) and ↙↗ (columns), not the window’s X/Y axes.
            if x > y * 2.4 { axis = .horizontal }
            else if y > x * 2.4 { axis = .vertical }
            else {
                diagonal = true
                axis = abs(travel.y - travel.x) >= abs(travel.x + travel.y) ? .vertical : .horizontal
            }
            if axis == .vertical {
                songTravel = diagonal ? (travel.x - travel.y - dx + dy) * 0.7071 : travel.y - dy
            }
        }
        let songDelta = diagonal ? (dx - dy) * 0.7071 : dy
        let columnTravel = diagonal ? (travel.x + travel.y) * 0.7071 : travel.x
        if axis == .vertical {
            return precise ? stepSong(songDelta) : (dy == 0 ? .none : .song(dy > 0 ? 1 : -1))
        }
        guard !committed else { return .none }
        if precise {
            guard abs(columnTravel) >= 110 else { return .none }
        } else {
            guard dx != 0, time - lastMouseColumn >= 0.35 else { return .none }
            lastMouseColumn = time
        }
        committed = true
        return .column(columnTravel > 0 ? 1 : -1)
    }

    private mutating func stepSong(_ dy: CGFloat) -> Action {
        songTravel += dy
        guard abs(songTravel) >= 40 else { return .none }
        let direction = songTravel > 0 ? 1 : -1
        songTravel = 0
        return .song(direction)
    }
}

/// Deliberate single-song swipes in detail; inertia never skips additional tracks.
struct MusicDetailScroll {
    private var travel: CGFloat = 0
    private var horizontal: Bool?
    private var committed = false
    private var lastEvent: TimeInterval = -1
    private var lastMouseStep: TimeInterval = -1
    mutating func consume(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                          precise: Bool, time: TimeInterval) -> Int? {
        guard momentum.isEmpty else { return nil }
        if phase.contains(.began) || (phase.isEmpty && (time - lastEvent > 0.25 || !precise)) {
            travel = 0; horizontal = nil; committed = false
        }
        lastEvent = time
        if horizontal == nil, max(abs(dx), abs(dy)) > 0 { horizontal = abs(dx) > abs(dy) }
        let delta = horizontal == true ? dx : dy
        travel += delta
        guard !committed else { return nil }
        if precise { guard abs(travel) >= 110 else { return nil } }
        else { guard delta != 0, time - lastMouseStep >= 0.35 else { return nil }; lastMouseStep = time }
        committed = true
        return travel > 0 ? 1 : -1
    }
}
