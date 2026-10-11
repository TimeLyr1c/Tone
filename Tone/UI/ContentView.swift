import SwiftUI
import UIKit

private enum ToneStyle {
    static let background = Color(red: 0.055, green: 0.07, blue: 0.075)
    static let surface = Color(red: 0.095, green: 0.12, blue: 0.13)
    static let mint = Color(red: 0.62, green: 0.94, blue: 0.76)
    static let muted = Color(red: 0.61, green: 0.67, blue: 0.65)
    static let amber = Color(red: 1, green: 0.76, blue: 0.43)
}

struct ContentView: View {
    @StateObject private var audio = AudioController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("trackingProfile") private var profileRaw = TrackingProfile.voice.rawValue
    private var profile: TrackingProfile { TrackingProfile(rawValue: profileRaw) ?? .voice }
    private var isInTune: Bool {
        audio.display.state == .tracking && audio.reading.map { abs($0.cents) <= profile.tolerance } == true
    }
    @State private var sungNoteRole = SungNoteRole.unknown

    var body: some View {
        ZStack {
            ToneStyle.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tone").font(.system(size: 36, weight: .semibold, design: .rounded))
                            Text("听见音高，找到你的音。").font(.subheadline).foregroundStyle(ToneStyle.muted)
                        }
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(ToneStyle.mint)
                            .accessibilityHidden(true)
                    }
                    Picker("功能", selection: $selectedTab) {
                        Text("音高 · 调音").tag(0)
                        Text("标准音").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if let error = audio.errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(ToneStyle.amber)
                            if audio.permissionDenied {
                                Button("打开系统设置") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .foregroundStyle(ToneStyle.mint)
                            } else {
                                Button("重试") { audio.retry() }.foregroundStyle(ToneStyle.mint)
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ToneStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if selectedTab == 0 { tuner } else { referencePad }

                    HStack {
                        Image(systemName: "lock.shield")
                        Text("本地处理音频，不录音、不上传。")
                    }
                    .font(.caption).foregroundStyle(ToneStyle.muted)
                    .frame(maxWidth: .infinity).padding(.bottom, 16)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .tint(ToneStyle.mint)
        .preferredColorScheme(.dark)
        .task {
            audio.setProfile(profile)
            updateActivity()
        }
        .onChange(of: profileRaw) { _, _ in audio.setProfile(profile) }
        .onChange(of: selectedTab) { _, _ in updateActivity() }
        .onChange(of: scenePhase) { _, _ in updateActivity() }
    }

    private func updateActivity() {
        // The system permission sheet temporarily makes the scene inactive.
        let active = scenePhase == .active || (scenePhase == .inactive && audio.isRequestingPermission)
        audio.setActivity(isActive: active, isTuner: selectedTab == 0)
    }

    private var tuner: some View {
        VStack(spacing: 20) {
            Picker("显示模式", selection: $profileRaw) {
                ForEach(TrackingProfile.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }.pickerStyle(.segmented)
            VStack(spacing: 12) {
                HStack {
                    Circle().fill(audio.isListening ? ToneStyle.mint : ToneStyle.muted).frame(width: 7, height: 7)
                    Text(audio.isRequestingPermission ? "等待麦克风授权" : audio.isListening ? "正在收音" : "收音暂停").font(.caption)
                    Spacer()
                    Text("A4 = 440 Hz").font(.caption.monospaced()).foregroundStyle(ToneStyle.muted)
                }
                Text(audio.reading?.note.label ?? "—")
                    .font(.system(size: 88, weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(isInTune ? ToneStyle.mint : .white)
                    .contentTransition(.numericText())
                    .accessibilityLabel(audio.reading.map { "最近音符 \($0.note.label)" } ?? "尚未检测到音高")
                Text(audio.reading.map { String(format: "%.1f Hz", $0.frequency) } ?? "唱一个音，或弹奏一个音")
                    .font(.system(.title3, design: .monospaced)).foregroundStyle(ToneStyle.muted)
                TuningGauge(cents: audio.reading?.cents ?? 0, visible: audio.display.needleVisible,
                            reliable: audio.display.state == .tracking, tolerance: profile.tolerance)
                    .animation(.linear(duration: 0.08), value: audio.reading?.cents)
                PitchHistory(history: audio.display.history, time: audio.display.time, tolerance: profile.tolerance)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tuningStatus).font(.title3.weight(.semibold))
                    if let pitch = audio.reading {
                        Text(String(format: "%+.1f 音分", pitch.cents)).font(.callout.monospaced())
                    }
                }
                .foregroundStyle(isInTune ? ToneStyle.mint : ToneStyle.muted)
                .accessibilityElement(children: .combine)
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.caption)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(ToneStyle.mint.opacity(0.7)).frame(width: proxy.size.width * audio.inputLevel)
                        }
                    }.frame(height: 4)
                    Text("输入").font(.caption2)
                }
                .foregroundStyle(ToneStyle.muted).padding(.top, 10).accessibilityHidden(true)
            }
            .padding(22)
            .background(ToneStyle.surface, in: RoundedRectangle(cornerRadius: 28))

            VStack(alignment: .leading, spacing: 12) {
                Text("我唱的是…").font(.headline)
                Picker("唱出的音在歌曲中的作用", selection: $sungNoteRole) {
                    ForEach(SungNoteRole.allCases) { role in Text(role.rawValue).tag(role) }
                }
                .pickerStyle(.segmented)
                if let note = audio.reading?.note,
                   let tonic = sungNoteRole.tonicCandidate(from: note) {
                    Text("主音线索：\(tonic.name)")
                        .font(.title3.weight(.semibold)).foregroundStyle(ToneStyle.mint)
                    Text(sungNoteRole == .tonic
                         ? "按你选择的主音判断。大小调仍需结合旋律确认。"
                         : "按你选择的属音判断：\(note.name) 向下纯五度为 \(tonic.name)。大小调仍需结合旋律确认。")
                        .font(.footnote).foregroundStyle(ToneStyle.muted)
                } else {
                    Text(sungNoteRole == .unknown
                         ? "如果你知道唱的是主音或属音，可以在这里换算主音。"
                         : "唱出你认为的主音或属音。")
                        .font(.footnote).foregroundStyle(ToneStyle.muted)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ToneStyle.surface, in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 9) {
                Text("从一个音开始").font(.headline)
                Text("持续唱或弹一个清晰的单音。指针向左表示偏低，向右表示偏高。人声档更稳，乐器档反应更快。当前绿色区域为 ±\(Int(profile.tolerance)) 音分。")
                Text("如果你已确定唱的是主音，音名可作为调性线索；若是属音，可向下推五度。单个音无法确定整首歌的调，也无法区分大小调。")
            }
            .font(.footnote).foregroundStyle(ToneStyle.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tuningStatus: String {
        guard audio.display.state == .tracking, let pitch = audio.reading else {
            return audio.isListening ? audio.inputStatus : "等待声音"
        }
        if abs(pitch.cents) <= profile.tolerance { return profile == .voice ? "接近标准音" : "已调准" }
        return pitch.cents < 0 ? "偏低 ↑" : "偏高 ↓"
    }

    private var referencePad: some View {
        ReferencePad(audio: audio)
    }
}

private struct TuningGauge: View, Animatable {
    var cents: Double
    let visible: Bool
    let reliable: Bool
    let tolerance: Double
    var animatableData: Double {
        get { cents }
        set { cents = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 22)
            // Leave room above the arc for the zero label; Canvas clips at its bounds.
            let radius = min(size.width * 0.46, size.height - 58)
            func point(_ value: Double, _ distance: Double) -> CGPoint {
                let angle = -Double.pi / 2 + value / 50 * Double.pi / 3
                return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            }
            for tick in stride(from: -50, through: 50, by: 5) {
                let major = tick % 25 == 0
                var path = Path()
                path.move(to: point(Double(tick), radius - (major ? 17 : 9)))
                path.addLine(to: point(Double(tick), radius))
                context.stroke(path, with: .color(abs(Double(tick)) <= tolerance ? ToneStyle.mint : .white.opacity(major ? 0.5 : 0.18)),
                               style: StrokeStyle(lineWidth: tick == 0 ? 3 : 1.5, lineCap: .round))
                if major {
                    let label = tick > 0 ? "+\(tick)" : "\(tick)"
                    context.draw(Text(label).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ToneStyle.muted), at: point(Double(tick), radius + 17))
                }
            }
            if visible {
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: point(max(-50, min(50, cents)), radius - 24))
                context.stroke(needle, with: .color(!reliable ? ToneStyle.muted : abs(cents) <= tolerance ? ToneStyle.mint : ToneStyle.amber),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                         with: .color(visible && reliable ? ToneStyle.mint : ToneStyle.muted))
        }
        .frame(height: 170).accessibilityHidden(true)
        HStack {
            Text("偏低").frame(maxWidth: .infinity, alignment: .leading)
            Text("偏高").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(ToneStyle.muted).accessibilityHidden(true)
    }
}

private struct PitchHistory: View {
    let history: [PitchHistoryPoint]
    let time: Double
    let tolerance: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("音高轨迹 · 最近 3 秒").font(.caption).foregroundStyle(ToneStyle.muted)
            Canvas { context, size in
                func point(_ sample: PitchHistoryPoint) -> CGPoint {
                    CGPoint(x: size.width * (1 - (time - sample.time) / 3),
                            y: size.height / 2 - max(-75, min(75, sample.cents)) / 150 * size.height)
                }
                let band = CGRect(x: 0, y: size.height / 2 - tolerance / 150 * size.height,
                                  width: size.width, height: tolerance / 75 * size.height)
                context.fill(Path(band), with: .color(ToneStyle.mint.opacity(0.08)))
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(ToneStyle.muted.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                var path = Path()
                var previous: PitchHistoryPoint?
                for sample in history where time - sample.time <= 3 {
                    if let previous, sample.time - previous.time < 0.18 {
                        path.addLine(to: point(sample))
                    } else { path.move(to: point(sample)) }
                    context.fill(Path(ellipseIn: CGRect(x: point(sample).x - 1.5, y: point(sample).y - 1.5,
                                                       width: 3, height: 3)), with: .color(ToneStyle.mint))
                    previous = sample
                }
                context.stroke(path, with: .color(ToneStyle.mint.opacity(0.85)), lineWidth: 1.5)
            }.frame(height: 65).clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近三秒音高轨迹，中心虚线为标准音")
    }
}

private struct ReferencePad: View {
    @ObservedObject var audio: AudioController
    @State private var octave = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("给耳朵一个参照。").font(.title2.weight(.semibold))
                Text("按住发声，松开停止。使用纯正弦波，标准为 A4 = 440 Hz。")
                    .font(.callout).foregroundStyle(ToneStyle.muted)
            }
            HStack(spacing: 12) {
                ReferenceKey(note: MusicalNote(midi: 60), subtitle: "中央 C", audio: audio)
                ReferenceKey(note: MusicalNote(midi: 69), subtitle: "标准 A", audio: audio)
            }
            HStack {
                Text("八度").font(.headline)
                Spacer()
                Button { changeOctave(-1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                    .disabled(octave <= 2).accessibilityLabel("降低一个八度")
                Text("C\(octave) – C\(octave + 1)").font(.callout.monospaced()).frame(minWidth: 86)
                Button { changeOctave(1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .disabled(octave >= 6).accessibilityLabel("升高一个八度")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach((0...12).map { MusicalNote(midi: (octave + 1) * 12 + $0) }) { note in
                    ReferenceKey(note: note, subtitle: nil, audio: audio)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: audio.playingNote == nil ? "hand.draw" : "speaker.wave.2.fill")
                Text(audio.playingNote.map { "正在播放 \($0.label) · " + String(format: "%.2f Hz", $0.frequency()) } ?? "按住任意音符试听")
            }
            .font(.footnote).foregroundStyle(ToneStyle.mint)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            Text("C4 为中央 C（261.63 Hz）。升号音也可写为相邻音的降号，例如 C♯ = D♭。调 Stylophone 或其他乐器时，回到调音页弹奏单音即可。")
                .font(.footnote).foregroundStyle(ToneStyle.muted)
        }
    }

    private func changeOctave(_ delta: Int) {
        audio.stopTone()
        octave = max(2, min(6, octave + delta))
    }
}

private struct ReferenceKey: View {
    let note: MusicalNote
    let subtitle: String?
    @ObservedObject var audio: AudioController
    private var active: Bool { audio.playingNote == note }

    var body: some View {
        VStack(spacing: 6) {
            if let subtitle { Text(subtitle).font(.caption.weight(.medium)) }
            Text(note.label).font(.system(size: subtitle == nil ? 25 : 30, weight: .medium, design: .rounded))
            Text(String(format: "%.1f Hz", note.frequency()))
                .font(.system(size: 11, design: .monospaced)).opacity(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 90 : 112)
        .foregroundStyle(active ? ToneStyle.background : note.isAccidental ? ToneStyle.muted : .white)
        .background(active ? ToneStyle.mint : ToneStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(note.isAccidental ? 0.04 : 0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .overlay(ImmediateTouchSurface(
            onPress: { audio.play(note) },
            onRelease: { if audio.playingNote == note { audio.stopTone() } }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subtitle.map { $0 + "，" } ?? "")\(note.label)，\(String(format: "%.1f", note.frequency())) 赫兹")
        .accessibilityValue(active ? "正在发声" : "未发声")
        .accessibilityHint("双击切换发声，再次双击停止")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if active { audio.stopTone() } else { audio.play(note) } }
        .onDisappear { if active { audio.stopTone() } }
    }
}

/// UIKit touch-down avoids SwiftUI drag recognition and ScrollView's delayed touches.
private struct ImmediateTouchSurface: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> TouchSurfaceView { TouchSurfaceView() }
    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onPress = onPress
        view.onRelease = onRelease
    }
    static func dismantleUIView(_ view: TouchSurfaceView, coordinator: ()) { view.release() }
}

private final class TouchSurfaceView: UIView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var held = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isAccessibilityElement = false
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                scroll.delaysContentTouches = false
                scroll.canCancelContentTouches = true
                break
            }
            ancestor = view.superview
        }
        if window == nil { release() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !held else { return }
        held = true
        onPress?()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, !bounds.contains(touch.location(in: self)) { release() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    func release() {
        guard held else { return }
        held = false
        onRelease?()
    }
}

#Preview { ContentView() }
