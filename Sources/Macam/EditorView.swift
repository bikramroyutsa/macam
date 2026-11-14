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
                Button("") { editor.split() }.keyboardShortcut("s", modifiers: [])
                Button("") { editor.toggleDeleteCurrent() }.keyboardShortcut(.delete, modifiers: [])
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
                    if editor.segments.count > 1 {
                        Text("Part \(editor.currentIndex + 1) of \(editor.segments.count)")
                        if editor.currentIsDeleted {
                            Text("· removed")
                        } else if editor.currentSpeed != 1 {
                            Text("· \(Self.speedLabel(editor.currentSpeed))")
                        }
                        Text("·")
                    }
                    Text("Result \(Self.clock(editor.outputDuration))")
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
        VStack(spacing: 10) {
            // Row 1: work on parts.
            HStack(spacing: 10) {
                ActionChip(title: "Split", system: "scissors", enabled: editor.canSplit) { editor.split() }
                    .help("Cut the video in two at the playhead (S)")
                ActionChip(title: editor.currentIsDeleted ? "Restore" : "Delete",
                           system: editor.currentIsDeleted ? "arrow.uturn.backward" : "trash",
                           enabled: editor.canDeleteCurrent) { editor.toggleDeleteCurrent() }
                    .help(editor.currentIsDeleted ? "Bring this part back" : "Remove this part (Delete key)")

                divider

                speedPicker
                if editor.segments.count > 1 {
                    Button { editor.setSpeed(editor.currentSpeed, applyToAll: true) } label: {
                        Text("All").font(.system(size: 12, weight: .medium)).padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Use this speed for the whole video")
                }

                Spacer(minLength: 0)

                BarButton(system: "arrow.uturn.backward", help: "Undo (⌘Z)") { editor.undo() }
                    .disabled(!editor.canUndo).opacity(editor.canUndo ? 1 : 0.35)
                BarButton(system: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { editor.redo() }
                    .disabled(!editor.canRedo).opacity(editor.canRedo ? 1 : 0.35)
            }

            // Row 2: whole-video options.
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    BarButton(system: "rotate.left", help: "Rotate left") { editor.rotate(by: -90) }
                    BarButton(system: "rotate.right", help: "Rotate right") { editor.rotate(by: 90) }
                    BarButton(system: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                              active: editor.flipped, help: "Flip horizontally") { editor.toggleFlip() }
                }

                divider

                HStack(spacing: 6) {
                    ToggleChip(title: "Fade in", system: "arrow.up.right", isOn: editor.fadeIn) { editor.toggleFadeIn() }
                    ToggleChip(title: "Fade out", system: "arrow.down.right", isOn: editor.fadeOut) { editor.toggleFadeOut() }
                }

                BarButton(system: editor.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          active: editor.muted, help: editor.hasAudio ? "Mute audio" : "No audio in this video") {
                    editor.toggleMute()
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
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.smooth(duration: 0.3), value: editor.hasEdits)
        .animation(.smooth(duration: 0.25), value: editor.segments.count)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)
    }

    /// Speed of the part under the playhead.
    private var speedPicker: some View {
        HStack(spacing: 2) {
            ForEach(VideoEditor.speeds, id: \.self) { s in
                let selected = editor.currentSpeed == s
                Button { editor.setSpeed(s) } label: {
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
                .help(s < 1 ? "Slow motion for this part" : (s > 1 ? "Fast forward this part" : "Normal speed for this part"))
            }
        }
        .animation(.smooth(duration: 0.3), value: editor.currentSpeed)
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

// MARK: - Timeline

/// The source video as a filmstrip, cut into parts. Click to move the playhead (the part under it is the
/// one Split, Delete and the speed buttons act on). Drag a cut to move it, double-click a cut to remove it,
/// and drag the yellow handles to trim the ends. Removed parts stay visible, dimmed, so they can be restored.
struct TrimTimeline: View {
    @ObservedObject var editor: VideoEditor

    private let height: CGFloat = 58
    private let handleWidth: CGFloat = 14
    private let yellow = Color(nsColor: .systemYellow)
    private let slowTint = Color(nsColor: .systemBlue)
    private let fastTint = Color(nsColor: .systemOrange)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(editor.duration, 0.001)
            let x0 = w * CGFloat(editor.trimStart / d)
            let x1 = w * CGFloat(editor.trimEnd / d)
            let xp = w * CGFloat(min(max(editor.playhead, 0), d) / d)
            let current = editor.currentIndex

            ZStack(alignment: .topLeading) {
                filmstrip(width: w)

                // Parts: removed ones dimmed, sped-up / slowed ones tinted and labelled, the current one outlined.
                ForEach(Array(editor.segments.enumerated()), id: \.element.id) { i, seg in
                    partOverlay(seg, isCurrent: i == current, width: w, duration: d)
                }

                // Outside the trim handles.
                Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, x0), height: height)
                Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, w - x1), height: height).offset(x: x1)
                Rectangle()
                    .strokeBorder(yellow, lineWidth: 3)
                    .frame(width: max(0, x1 - x0), height: height)
                    .offset(x: x0)
                    .allowsHitTesting(false)

                // Scrub on the strip.
                Color.clear
                    .frame(width: w, height: height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in editor.seek(toSource: Double(v.location.x / w) * d) })

                // Cuts between parts.
                ForEach(Array(editor.segments.indices.dropFirst()), id: \.self) { i in
                    if editor.segments.indices.contains(i) {
                        cutHandle(index: i, width: w, duration: d)
                    }
                }

                // Playhead.
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: height + 10)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: xp - 1.5, y: -5)
                    .allowsHitTesting(false)

                // Trim handles.
                trimHandle(leading: true)
                    .offset(x: x0 - handleWidth)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in
                            editor.beginEdit()
                            let t = Double((v.location.x + handleWidth / 2) / w) * d
                            let clamped = min(max(0, t), editor.trimEnd - VideoEditor.minLength)
                            editor.trimStart = clamped
                            editor.previewFrame(atSource: clamped)
                        }
                        .onEnded { _ in editor.endEdit() })
                trimHandle(leading: false)
                    .offset(x: x1)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { v in
                            editor.beginEdit()
                            let t = Double((v.location.x - handleWidth / 2) / w) * d
                            let clamped = max(min(d, t), editor.trimStart + VideoEditor.minLength)
                            editor.trimEnd = clamped
                            editor.previewFrame(atSource: max(0, clamped - 0.05))
                        }
                        .onEnded { _ in editor.endEdit() })
            }
            .coordinateSpace(name: "trim")
            .frame(width: w, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        .padding(.horizontal, handleWidth)
    }

    private func filmstrip(width w: CGFloat) -> some View {
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
    }

    @ViewBuilder
    private func partOverlay(_ seg: EditSegment, isCurrent: Bool, width w: CGFloat, duration d: Double) -> some View {
        let a = w * CGFloat(seg.start / d), b = w * CGFloat(seg.end / d)
        let partWidth = max(0, b - a)
        let tint = seg.speed < 1 ? slowTint : fastTint

        ZStack(alignment: .topLeading) {
            if seg.deleted {
                Rectangle().fill(.black.opacity(0.74))
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(partWidth > 26 ? 1 : 0)
            } else if seg.speed != 1 {
                Rectangle().fill(tint.opacity(0.22))
                Rectangle().fill(tint).frame(height: 4)
                if partWidth > 42 {
                    Text(EditorView.speedLabel(seg.speed))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tint))
                        .padding(.top, 8).padding(.leading, 5)
                }
            }
            if isCurrent {
                Rectangle().fill(.white.opacity(0.14))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.95), lineWidth: 2)
            }
        }
        .frame(width: partWidth, height: height)
        .offset(x: a)
        .allowsHitTesting(false)
    }

    private func cutHandle(index i: Int, width w: CGFloat, duration d: Double) -> some View {
        let bx = w * CGFloat(editor.segments[i].start / d)
        return ZStack {
            Rectangle().fill(.white.opacity(0.85)).frame(width: 2, height: height)
            Capsule().fill(.white).frame(width: 7, height: 16).shadow(color: .black.opacity(0.4), radius: 2)
        }
        .frame(width: 18, height: height)
        .contentShape(Rectangle())
        .offset(x: bx - 9)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("trim"))
            .onChanged { v in
                editor.beginEdit()
                let t = Double(v.location.x / w) * d
                editor.moveBoundary(i, to: t)
                editor.previewFrame(atSource: t)
            }
            .onEnded { _ in editor.endEdit() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { editor.joinBoundary(i) })
        .help("Drag to move this cut. Double-click to remove it.")
    }

    private func trimHandle(leading: Bool) -> some View {
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

/// A tappable pill with an icon, for actions (as opposed to ToggleChip, which holds a state).
struct ActionChip: View {
    let title: String
    let system: String
    var enabled = true
    let action: () -> Void
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hoverBox.value && enabled ? 0.20 : 0.11)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hoverBox.value = $0 }
        .animation(.smooth(duration: 0.2), value: enabled)
        .animation(.easeOut(duration: 0.15), value: hoverBox.value)
    }
}
