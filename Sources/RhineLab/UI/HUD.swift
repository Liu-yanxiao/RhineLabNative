import SwiftUI

extension View {
    /// Place a view relative to the edges of the 1920 × 1080 stage.
    func place(left: CGFloat? = nil, right: CGFloat? = nil, top: CGFloat? = nil, bottom: CGFloat? = nil) -> some View {
        let h: HorizontalAlignment = right != nil && left == nil ? .trailing : .leading
        let v: VerticalAlignment = bottom != nil && top == nil ? .bottom : .top
        return self
            .padding(.leading, left ?? 0).padding(.trailing, right ?? 0)
            .padding(.top, top ?? 0).padding(.bottom, bottom ?? 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: h, vertical: v))
    }
}

struct BrandHeader: View {
    private let positions: [CGFloat] = [2, 28, 55, 81, 103, 129, 154, 166]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RHINE LAB").font(Theme.font(44, .bold)).tracking(2.5).frame(height: 48, alignment: .leading)
            Text("SYNTHESIZE INFORMATION").font(Theme.font(19, .semibold)).tracking(0.65).frame(height: 23, alignment: .leading)
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array("ANALYSIS".enumerated()), id: \.offset) { i, ch in
                        Text(String(ch)).font(Theme.font(35, .regular)).offset(x: positions[i])
                    }
                }.frame(width: 189, height: 40, alignment: .topLeading)
                Spacer(minLength: 0)
                Text("OS").font(Theme.font(35, .bold)).tracking(3)
            }.frame(width: 270, height: 40)
        }
        .foregroundStyle(Theme.ink)
        .frame(width: 270, alignment: .leading)
    }
}

struct SystemNav: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 43) {
            NavButton(action: { model.present(.search) }) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .regular))
                    Text("ARCHIVE INDEX")
                    Text("/").font(Theme.font(11)).frame(minWidth: 19, minHeight: 21)
                        .overlay(Rectangle().stroke(Theme.faint.opacity(0.6), lineWidth: 1)).padding(.leading, 6)
                }
            }
            NavButton(action: { model.present(.saved) }) {
                HStack(spacing: 8) {
                    Text("＋ SAVED")
                    Text(String(format: "%02d", model.saved.count)).contentTransition(.numericText())
                }
            }
            NavButton(action: { model.present(.settings) }) { Text("◷").font(.system(size: 18)) }
        }
        .font(Theme.font(14)).tracking(0.7)
        .foregroundStyle(Theme.ink)
    }
}

struct NavButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    var body: some View {
        Button(action: action) { label.frame(minHeight: 28) }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Theme.accent : Theme.ink)
            .onHover { hovering = $0 }
    }
}

/// Everything shown over the archive array.
struct ArchiveHUD: View {
    @EnvironmentObject var model: AppModel
    @State private var hoverTitle = false

    var body: some View {
        let r = model.record
        let files = model.columnFiles
        let animate = !model.reduced
        ZStack(alignment: .topLeading) {
            // Selection callout, right of the extracted card.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text("INTERNAL DATABASE").tracking(1.3)
                    Text("／").tracking(1.3)
                    RollingText(text: r.category, animated: animate)
                }
                .font(Theme.font(12)).foregroundStyle(Theme.muted).padding(.bottom, 22)

                Button { model.open() } label: {
                    HStack(spacing: 10) {
                        Text("FILE NUMBER:")
                        HStack(spacing: 0) {
                            Text("X-")
                            Text(String(format: "%03d", Int(r.id.dropFirst(2)) ?? 0)).contentTransition(.numericText())
                        }
                        Text("↗").font(Theme.font(25, .regular)).padding(.leading, 38)
                            .opacity(hoverTitle ? 1 : 0).offset(x: hoverTitle ? 3 : 0, y: hoverTitle ? -3 : 0)
                    }
                    .font(Theme.font(28, .bold)).tracking(0.2)
                }
                .buttonStyle(.plain).onHover { hoverTitle = $0 }
                .animation(.easeOut(duration: 0.3), value: hoverTitle)

                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(red: 0.31, green: 0.29, blue: 0.255)).frame(height: 1)
                    Rectangle().fill(Theme.dark).frame(width: 6, height: 6).offset(x: -61)
                }.padding(.leading, 57).padding(.top, 55)

                HStack {
                    RollingText(text: r.title, animated: animate)
                    Spacer()
                    RollingText(text: r.clearance, animated: animate)
                }
                .font(Theme.font(16)).frame(width: 652).padding(.leading, 58).padding(.top, 22)

                Button { model.open() } label: {
                    HStack(spacing: 70) { Text("ACCESS FILE").tracking(1); Text("→") }.font(Theme.font(14))
                }
                .buttonStyle(.plain).padding(.leading, 58).padding(.top, 58)
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 950, alignment: .leading)
            .offset(x: 970, y: 471)

            if let h = model.hover {
                Text("X-\(Archive.records[h].id.dropFirst(2)) / \(Archive.records[h].title)")
                    .font(Theme.font(13)).tracking(1).foregroundStyle(Color(red: 0.435, green: 0.404, blue: 0.357))
                    .place(left: 60, bottom: 264)
            }

            // Counter
            VStack(alignment: .leading, spacing: 16) {
                Text("ARCHIVE / SELECT").font(Theme.font(11)).tracking(1.7)
                HStack(alignment: .firstTextBaseline, spacing: 21) {
                    Text(String(format: "%02d", (files.firstIndex(of: model.selected) ?? 0) + 1))
                        .font(Theme.font(58)).contentTransition(.numericText())
                    Text("/").font(Theme.font(32, .light)).foregroundStyle(Color(red: 0.56, green: 0.54, blue: 0.5))
                    Text(String(format: "%02d", files.count)).font(Theme.font(58))
                }
            }
            .foregroundStyle(Theme.ink).place(left: 60, bottom: 115)

            // ↑ ticks ↓
            HStack(spacing: 33) {
                Button { model.stepFile(-1) } label: { Text("↑").font(Theme.font(22)) }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    ForEach(files, id: \.self) { index in
                        Button { model.select(index, navigation: .row(files.firstIndex(of: index)! > (files.firstIndex(of: model.selected) ?? 0) ? 1 : -1)) } label: {
                            Rectangle().fill(index == model.selected ? Theme.dark : Color(red: 0.667, green: 0.647, blue: 0.604))
                                .frame(width: 2, height: index == model.selected ? 33 : 12)
                                .frame(width: 14, height: 40)
                        }.buttonStyle(.plain)
                    }
                }.animation(.easeOut(duration: 0.4), value: model.selected)
                Button { model.stepFile(1) } label: { Text("↓").font(Theme.font(22)) }.buttonStyle(.plain)
            }
            .foregroundStyle(Theme.ink).place(left: 504, bottom: 131)

            // Key hints
            HStack(spacing: 6) {
                Text("← →"); Text("切换列"); Text("／"); Text("↑ ↓"); Text("前后档案"); Text("／"); Text("ENTER"); Text("读取")
            }
            .font(Theme.font(10)).tracking(0.9).foregroundStyle(Theme.faint)
            .place(left: 505, bottom: 60)
        }
    }
}

struct SystemFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 44) {
                HStack(spacing: 10) {
                    Rectangle().fill(Color(red: 0.467, green: 0.482, blue: 0.376)).frame(width: 5, height: 5)
                    Text("SESSION AUTHORIZED")
                }
                Spacer()
                Text("JOYCE MOORE ／ \(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))")
                Button { model.replay() } label: { Text("REINITIALIZE ↗") }.buttonStyle(.plain)
            }
            .font(Theme.font(10)).tracking(0.9).foregroundStyle(Color(red: 0.47, green: 0.467, blue: 0.431))
        }
        .padding(.horizontal, 59).place(bottom: 35)
    }
}

struct PoweredBy: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("POWERED BY"); Text("RHINE LAB").font(Theme.font(19, .bold))
            Rectangle().fill(Theme.ink).frame(width: 18, height: 3).padding(.leading, 6)
        }
        .font(Theme.font(19)).foregroundStyle(Theme.ink)
        .place(right: 59, bottom: 108)
    }
}
