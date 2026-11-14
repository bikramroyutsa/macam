import AVFoundation
import SwiftUI

// MARK: - Player surface

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: PlayerNSView, context: Context) {}
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var editor: VideoEditor
    var close: () -> Void
    @Namespace private var speedNamespace

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                header
                stage
                timelineCard
                toolsCard
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)

            // Space plays and pauses; Esc goes back to the camera.
            Group {
                Button("") { editor.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("") { close() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 62)   // room for the window's traffic lights
            Button(action: close) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Camera").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glass(Capsule())
            }
            .buttonStyle(.plain)

            Text(editor.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)

            saveControls
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private var saveControls: some View {
        HStack(spacing: 8) {
            if editor.isExporting {
                HStack(spacing: 8) {
                    ProgressView(value: editor.exportProgress)
                        .progressViewStyle(.linear).frame(width: 90)
                    Text("\(Int(editor.exportProgress * 100))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glass(Capsule())
                .transition(.opacity)
            } else if let saved = editor.savedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Saved. Show in Finder").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glass(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Menu {
                    Section("Format") {
                        ForEach(ExportFormat.all) { f in
                            let unavailable = f == .audio && (!editor.hasAudio || editor.muted)
                            Button {
                                editor.exportFormat = f
                            } label: {
                                if editor.exportFormat == f {
                                    Label("\(f.label)  —  \(f.detail)", systemImage: "checkmark")
                                } else {
                                    Text("\(f.label)  —  \(f.detail)")
                                }
                            }
                            .disabled(unavailable)
                        }
                    }
                    if editor.exportFormat.isVideo {
                        Section("Size") {
                            ForEach(ExportSize.allCases) { size in
                                Button {
                                    editor.exportSize = size
                                } label: {
                                    if editor.exportSize == size { Label(size.label, systemImage: "checkmark") }
                                    else { Text(size.label) }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.exportSummary(editor.exportFormat, editor.exportSize))
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glass(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help("Format and size to save as")

                Button {
                    Task { await editor.exportCopy() }
                } label: {
                    Text(editor.saveTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(editor.canSave ? 1 : 0.35)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!editor.canSave || editor.isLoading)
                .help(editor.canSave ? "Save as a new file. The original is not changed." : "Make an edit or pick another format first")
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: editor.isExporting)
        .animation(.smooth(duration: 0.3), value: editor.savedURL)
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { geo in
            let fit = ContentView.fit(ratio: editor.displayRatio, in: CGSize(width: geo.size.width, height: geo.size.height))
            ZStack {
                Color.black
                if let error = editor.loadError {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    PlayerView(player: editor.player)
                    if let scrub = editor.scrubImage {
                        Image(nsImage: scrub).resizable().scaledToFit()
                    }
                    if editor.isLoading { ProgressView().controlSize(.small) }
                }

                if !editor.isPlaying, !editor.isLoading, editor.loadError == nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 64, height: 64)
                        .glass(Circle())
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                VStack {
                    Spacer()
                    if let toast = editor.toast {
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glass(Capsule())
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .contentShape(Rectangle())
            .onTapGesture { editor.togglePlay() }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .animation(.smooth(duration: 0.4), value: editor.displayRatio)
            .animation(.smooth(duration: 0.25), value: editor.isPlaying)
            .animation(.smooth(duration: 0.3), value: editor.toast)
        }
    }

    // MARK: Timeline

    private var timelineCard: some View {
        VStack(spacing: 8) {
            TrimTimeline(editor: editor)
            HStack {
                Text(Self.clock(editor.playhead))
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 6) {
                    Text("Result \(Self.clock(editor.outputDuration))")
                    if editor.speed != 1 {
                        Text("· \(Self.speedLabel(editor.speed))")
                    }
                }
                Spacer()
                Text(Self.clock(editor.duration))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Tools

    private var toolsCard: some View {
        HStack(spacing: 10) {
            speedPicker

            divider

            HStack(spacing: 2) {
                BarButton(system: "rotate.left", help: "Rotate left") { editor.rotate(by: -90) }
                BarButton(system: "rotate.right", help: "Rotate right") { editor.rotate(by: 90) }
                BarButton(system: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                          active: editor.flipped, help: "Flip horizontally") { editor.flipped.toggle() }
            }

            divider

            HStack(spacing: 6) {
                ToggleChip(title: "Fade in", system: "arrow.up.right", isOn: editor.fadeIn) { editor.fadeIn.toggle() }
                ToggleChip(title: "Fade out", system: "arrow.down.right", isOn: editor.fadeOut) { editor.fadeOut.toggle() }
            }

            BarButton(system: editor.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      active: editor.muted, help: editor.hasAudio ? "Mute audio" : "No audio in this video") {
                editor.muted.toggle()
            }
            .disabled(!editor.hasAudio)
            .opacity(editor.hasAudio ? 1 : 0.35)

            Spacer(minLength: 0)

            Button {
                Task { _ = await editor.saveFrame() }
            } label: {
                Label("Save Frame", systemImage: "camera.viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Save the current frame as a photo")

            Button { editor.reset() } label: {
                Text("Reset").font(.system(size: 12, weight: .medium)).padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(editor.hasEdits ? Color.secondary : Color.secondary.opacity(0.35))
            .disabled(!editor.hasEdits)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.smooth(duration: 0.3), value: editor.hasEdits)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)
    }

    private var speedPicker: some View {
        HStack(spacing: 2) {
            ForEach(VideoEditor.speeds, id: \.self) { s in
                let selected = editor.speed == s
                Button { editor.speed = s } label: {
                    Text(Self.speedLabel(s))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "speed", in: speedNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(s < 1 ? "Slow motion" : (s > 1 ? "Fast forward" : "Normal speed"))
            }
        }
        .animation(.smooth(duration: 0.3), value: editor.speed)
    }

    // MARK: Formatting

    static func exportSummary(_ format: ExportFormat, _ size: ExportSize) -> String {
        switch format {
        case .audio: return "M4A"
        case .gif: return "GIF"
        case .video(let f):
            return size == .original ? f.label : "\(f.label) · \(size.label)"
        }
    }

    static func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }

    static func clock(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}

// MARK: - Small controls

struct ToggleChip: View {
    let title: String
    let system: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(isOn ? 0.18 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

// MARK: - Trim timeline

/// A filmstrip with yellow trim handles and a playhead. Drag the handles to trim; click or drag the
/// strip to scrub within the kept range.
struct TrimTimeline: View {
    @ObservedObject var editor: VideoEditor

    private let height: CGFloat = 54
    private let handleWidth: CGFloat = 14
    private let yellow = Color(nsColor: .systemYellow)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(editor.duration, 0.001)
            let x0 = w * editor.trimStart / d
            let x1 = w * editor.trimEnd / d
            let xp = w * min(max(editor.playhead, 0), d) / d

            ZStack(alignment: .topLeading) {
                // Filmstrip
                HStack(spacing: 0) {
                    if editor.frames.isEmpty {
                        Rectangle().fill(.white.opacity(0.08))
                    } else {
                        ForEach(editor.frames.indices, id: \.self) { i in
                            Image(nsImage: editor.frames[i])
                                .resizable().scaledToFill()
                                .frame(width: w / CGFloat(editor.frames.count), height: height)
                                .clipped()
                        }
                    }
                }
                .frame(width: w, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Dim what will be cut
                Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, x0), height: height)
                Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, w - x1), height: height).offset(x: x1)

                // Kept range outline
                Rectangle()
                    .strokeBorder(yellow, lineWidth: 3)
                    .frame(width: max(0, x1 - x0), height: height)
                    .offset(x: x0)
                    .allowsHitTesting(false)

                // Scrub on the strip
                Color.clear
                    .frame(width: w, height: height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in editor.seek(toSource: Double(v.location.x / w) * d) })

                // Playhead
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: height + 10)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: xp - 1.5, y: -5)
                    .allowsHitTesting(false)

                // Trim handles
                handle(leading: true)
                    .offset(x: x0 - handleWidth)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in
                            let t = Double((v.location.x + handleWidth / 2) / w) * d
                            let clamped = min(max(0, t), editor.trimEnd - VideoEditor.minLength)
                            editor.trimStart = clamped
                            editor.previewFrame(atSource: clamped)
                        })
                handle(leading: false)
                    .offset(x: x1)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in
                            let t = Double((v.location.x - handleWidth / 2) / w) * d
                            let clamped = max(min(d, t), editor.trimStart + VideoEditor.minLength)
                            editor.trimEnd = clamped
                            editor.previewFrame(atSource: max(0, clamped - 0.05))
                        })
            }
            .coordinateSpace(name: "trim")
            .frame(width: w, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        .padding(.horizontal, handleWidth)
    }

    private func handle(leading: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: leading ? 7 : 0, bottomLeadingRadius: leading ? 7 : 0,
                                   bottomTrailingRadius: leading ? 0 : 7, topTrailingRadius: leading ? 0 : 7,
                                   style: .continuous)
                .fill(yellow)
            Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 16)
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle())
    }
}
