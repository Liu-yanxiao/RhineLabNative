import SwiftUI
import QuartzCore

/// A restrained, audio-driven strip integrated with the reading rules of the player.
struct MusicRhythmView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    let trackID: String?
    @State private var waveform = false
    @State private var pointer: CGPoint?
    private var active: Bool {
        model.rhythmEnabled && !model.reduced && !systemReduced && player.status == .playing && player.current?.id == trackID
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            let frame = active ? player.rhythm.snapshot() : MusicRhythmFrame()
            VStack(spacing: 7) {
                HStack {
                    Text("AUDIO / RHYTHM").tracking(1.4)
                    Text(active ? (frame.received ? "音频响应" : "等待音频…") : (model.rhythmEnabled ? "播放时响应" : "律动已关闭"))
                        .foregroundStyle(pal.muted)
                    Spacer()
                    Button(waveform ? "波形 ↗" : "频谱 ↗") { waveform.toggle() }
                        .buttonStyle(RhineButtonStyle()).help("点击切换频谱与波形；移入可聚焦")
                }.font(Theme.font(9)).foregroundStyle(pal.body)
                Canvas { context, size in
                    let mid = size.height * 0.5
                    var guide = Path(); guide.move(to: CGPoint(x: 0, y: mid)); guide.addLine(to: CGPoint(x: size.width, y: mid))
                    context.stroke(guide, with: .color(pal.line.opacity(0.35)), lineWidth: 0.5)
                    if waveform {
                        var path = Path()
                        for index in 0..<64 {
                            let x = CGFloat(index) / 63 * size.width
                            let amplitude = max(-1, min(1, frame.waveform[index] * 2))
                            let y = mid + CGFloat(amplitude) * mid * 0.9
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(pal.ink.opacity(0.75)), lineWidth: 1)
                    } else {
                        for index in 0..<48 {
                            let x = (CGFloat(index) + 0.5) / 48 * size.width
                            let position = Float(index) / 47 * 7
                            let lower = Int(position), upper = min(7, lower + 1), fraction = position - Float(lower)
                            let energy = frame.bands[lower] * (1 - fraction) + frame.bands[upper] * fraction
                            let focus = pointer.map { abs($0.x - x) < 32 } ?? false
                            let height = max(1.5, CGFloat(energy) * size.height * (0.65 + CGFloat(frame.beat) * 0.35))
                            let rect = CGRect(x: x, y: mid - height / 2, width: focus ? 2 : 1, height: height)
                            context.fill(Path(rect), with: .color(focus ? pal.accent : pal.ink.opacity(0.62)))
                        }
                    }
                    if let pointer {
                        var cursor = Path(); cursor.move(to: CGPoint(x: pointer.x, y: 0)); cursor.addLine(to: CGPoint(x: pointer.x, y: size.height))
                        context.stroke(cursor, with: .color(pal.accent.opacity(0.6)), lineWidth: 0.7)
                        context.fill(Path(ellipseIn: CGRect(x: pointer.x - 2, y: mid - 2, width: 4, height: 4)), with: .color(pal.accent))
                    }
                }.frame(height: 39).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase { case .active(let point): pointer = point; case .ended: pointer = nil }
                    }
                    .onTapGesture { waveform.toggle() }
                    .accessibilityElement().accessibilityLabel("音频律动")
                    .accessibilityValue(waveform ? "波形" : "频谱")
                    .accessibilityAddTraits(.isButton).accessibilityAction { waveform.toggle() }
            }
        }
    }
}
