import AppKit
import Combine
import SwiftUI

// MARK: - Geometry

struct NotchGeometry {
    var screen: NSScreen?
    var width: CGFloat
    var height: CGFloat

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NotchGeometry(screen: nil, width: 190, height: 0) }
        let h = screen.safeAreaInsets.top
        if h > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(screen: screen, width: screen.frame.width - l.width - r.width, height: h)
        }
        // No notch: a small pill hanging from the top edge.
        return NotchGeometry(screen: screen, width: 190, height: 0)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Allow the panel to sit over the menu bar / notch region.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class NotchController {
    private unowned let model: TeleprompterModel
    private var panel: NotchPanel?
    private var cancellables = Set<AnyCancellable>()

    init(model: TeleprompterModel) {
        self.model = model
        model.$isPresented.removeDuplicates().dropFirst().sink { [weak self] presented in
            self?.setPresented(presented)
        }.store(in: &cancellables)

        // Keep the panel sized to the pill when font size, width or line count change.
        // (@Published emits before the value lands, so hop a runloop turn.)
        model.$fontSize.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFrame() }
        }.store(in: &cancellables)
        model.$panelWidth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFrame() }
        }.store(in: &cancellables)
        model.$visibleLines.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFrame() }
        }.store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateFrame() }
            .store(in: &cancellables)
    }

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.level = .statusBar + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchTeleprompterView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func frame() -> NSRect {
        let g = model.notch
        let size = model.pillSize
        let screenFrame = g.screen?.frame ?? NSScreen.main?.frame ?? .zero
        return NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func updateFrame() {
        guard model.isPresented, let panel else { return }
        model.notch = NotchGeometry.current()
        panel.setFrame(frame(), display: true)
    }

    private func setPresented(_ presented: Bool) {
        if presented {
            model.notch = NotchGeometry.current()
            let panel = ensurePanel()
            panel.setFrame(frame(), display: true)
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.expanded = true }
        } else {
            model.stop()
            model.expanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, !self.model.isPresented else { return }
                self.panel?.orderOut(nil)
            }
        }
    }
}

// MARK: - Shape

private struct NotchShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                               bottomTrailingRadius: radius, topTrailingRadius: 0,
                               style: .continuous).path(in: rect)
    }
}

// MARK: - View

struct NotchTeleprompterView: View {
    @ObservedObject var model: TeleprompterModel
    @StateObject private var hoverBox = Box(false)
    private var hovering: Bool { hoverBox.value }

    var body: some View {
        let size = model.pillSize
        let notch = model.notch
        let open = model.expanded

        ZStack(alignment: .top) {
            NotchShape(radius: open ? 26 : 12)
                .fill(.black)

            VStack(spacing: 0) {
                Color.clear.frame(height: notch.height + 2)
                LinesView(model: model)
                    .frame(height: model.lineHeight * CGFloat(model.visibleLines))
                ControlsRow(model: model, hovering: hovering)
                    .frame(height: TeleprompterModel.controlsHeight)
            }
            .padding(.horizontal, 28)
            .frame(width: size.width, height: size.height, alignment: .top)
            .opacity(open ? 1 : 0)
            .blur(radius: open ? 0 : 8)
            .animation(open ? .easeOut(duration: 0.35).delay(0.18) : .easeIn(duration: 0.15), value: open)

            // Voice indicator in the band level with the physical notch, one cluster either side of it.
            if open, notch.height > 0, model.isRunning, model.mode != .scroll {
                let side = (size.width - notch.width) / 2
                HStack(spacing: 0) {
                    VoiceWave(amount: model.voiceAmount, mirrored: true)
                        .frame(width: max(0, side - 24))
                        .padding(.trailing, 10).padding(.leading, 14)
                    Color.clear.frame(width: notch.width)
                    VoiceWave(amount: model.voiceAmount, mirrored: false)
                        .frame(width: max(0, side - 24))
                        .padding(.leading, 10).padding(.trailing, 14)
                }
                .frame(width: size.width, height: notch.height)
                .animation(.linear(duration: 0.06), value: model.voiceAmount)
                .transition(.opacity)
            }

            if open {
                ResizeHandle(model: model, axis: .width, visible: hovering)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                ResizeHandle(model: model, axis: .height, visible: hovering)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: open ? size.width : notch.width,
               height: open ? size.height : max(notch.height, 1),
               alignment: .top)
        .clipShape(NotchShape(radius: open ? 26 : 12))
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: open)
        .animation(.smooth(duration: 0.3), value: model.fontSize)
        .onHover { hoverBox.value = $0 }
        .preferredColorScheme(.dark)
    }
}

// MARK: Lines

private struct LinesView: View {
    @ObservedObject var model: TeleprompterModel

    var body: some View {
        let current = model.currentLine
        let lineH = model.lineHeight
        let rows = model.visibleLines
        // Row the current line sits on: the first row at the very start (nothing above it yet),
        // then the second row so the line you just read stays visible above.
        let anchor = rows >= 3 && current > 0 ? 1 : 0
        let range = max(0, current - 2)..<min(model.lines.count, current + rows + 2)
        let fade = rows >= 3 ? 0.84 / Double(rows) : 0.06
        let topFade = anchor == 0 ? 0 : fade

        ZStack(alignment: .top) {
            ForEach(Array(range), id: \.self) { i in
                LineText(model: model, line: i)
                    .frame(height: lineH)
                    .offset(y: CGFloat(i - current + anchor) * lineH)
                    .onTapGesture { model.jump(toLine: i) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: lineH * CGFloat(rows), alignment: .top)
        .clipped()
        .mask(
            LinearGradient(stops: [
                .init(color: topFade == 0 ? .black : .clear, location: 0),
                .init(color: .black, location: topFade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .animation(.smooth(duration: 0.3), value: current)
    }
}

private struct LineText: View {
    @ObservedObject var model: TeleprompterModel
    let line: Int

    var body: some View {
        Text(attributed)
            .font(.system(size: model.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: model.currentIndex)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let indices = model.lines[line]
        for (n, idx) in indices.enumerated() {
            var piece = AttributedString(model.words[idx].text + (n < indices.count - 1 ? " " : ""))
            if idx < model.currentIndex {
                piece.foregroundColor = Color.white.opacity(0.28)
            } else if idx == model.currentIndex {
                piece.foregroundColor = Color.white
            } else {
                piece.foregroundColor = Color.white.opacity(0.62)
            }
            result += piece
        }
        return result
    }
}

// MARK: Voice indicator

/// A soft wave that radiates out of the notch. Silent: a faint, almost-flat line with a slow ripple.
/// Speaking: three layered waves swell with your voice and fade out towards the edge.
/// `amount` (0…1) is animatable, so it glides between the two states.
private struct VoiceWave: View, Animatable {
    var amount: Double
    var mirrored: Bool

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let midY = size.height / 2
                let layers: [(freq: Double, speed: Double, phase: Double, scale: Double, width: CGFloat, opacity: Double)] = [
                    (1.5, 2.6, 0.0, 1.00, 1.8, 1.00),
                    (2.3, 3.4, 1.9, 0.62, 1.3, 0.55),
                    (3.4, 4.6, 4.1, 0.38, 1.0, 0.35),
                ]
                let maxAmp = Double(size.height) * 0.5
                for layer in layers {
                    var path = Path()
                    var x = 0.0
                    while x <= size.width {
                        let u = x / size.width                                  // 0 at the notch, 1 at the outer edge
                        let envelope = sin(min(1, u * 5) * .pi / 2) * pow(1 - u, 0.8)
                        let amp = 0.7 + amount * maxAmp * layer.scale
                        let y = midY + sin(u * layer.freq * 2 * .pi - t * layer.speed + layer.phase) * amp * envelope
                        let px = mirrored ? size.width - x : x
                        if x == 0 { path.move(to: CGPoint(x: px, y: y)) } else { path.addLine(to: CGPoint(x: px, y: y)) }
                        x += 1.5
                    }
                    let near = mirrored ? CGPoint(x: size.width, y: 0) : .zero
                    let far = mirrored ? .zero : CGPoint(x: size.width, y: 0)
                    let strength = layer.opacity * (0.30 + 0.70 * amount)
                    ctx.stroke(path,
                               with: .linearGradient(Gradient(colors: [.white.opacity(strength), .white.opacity(0)]),
                                                     startPoint: near, endPoint: far),
                               style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 24)
    }
}

// MARK: Resize handles

private struct ResizeHandle: View {
    @ObservedObject var model: TeleprompterModel
    let axis: TeleprompterModel.ResizeAxis
    let visible: Bool
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        let horizontal = axis == .height   // bottom handle is a horizontal bar
        Capsule()
            .fill(.white.opacity(hoverBox.value ? 0.8 : 0.35))
            .frame(width: horizontal ? 44 : 4, height: horizontal ? 4 : 44)
            .padding(horizontal ? .vertical : .horizontal, 8)
            .contentShape(Rectangle())
            .opacity(visible || hoverBox.value ? 1 : 0)
            .animation(.smooth(duration: 0.25), value: visible)
            .animation(.easeOut(duration: 0.15), value: hoverBox.value)
            .onHover { inside in
                hoverBox.value = inside
                if inside { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in model.resize(axis) })
            .help(horizontal ? "Drag to change height" : "Drag to change width")
    }
}

// MARK: Controls

private struct ControlsRow: View {
    @ObservedObject var model: TeleprompterModel
    let hovering: Bool

    var body: some View {
        ZStack {
            // Idle: a hairline progress bar, quiet and out of the way.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(.white.opacity(0.5))
                        .frame(width: max(3, geo.size.width * model.progress))
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 60)
            .opacity(hovering ? 0 : 1)

            HStack(spacing: 18) {
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                } else {
                    PlayButton(model: model)
                    NotchIcon(system: "backward.end.fill") { model.reset() }
                    Menu {
                        Picker("Mode", selection: $model.mode) {
                            ForEach(PromptMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(model.mode.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    NotchIcon(system: "textformat.size.smaller") { model.fontSize = max(18, model.fontSize - 2) }
                    NotchIcon(system: "textformat.size.larger") { model.fontSize = min(48, model.fontSize + 2) }
                    NotchIcon(system: "chevron.up") { model.isPresented = false }
                }
            }
            .opacity(hovering || !model.status.isEmpty ? 1 : 0)
        }
        .animation(.smooth(duration: 0.25), value: hovering)
    }
}

private struct PlayButton: View {
    @ObservedObject var model: TeleprompterModel

    var body: some View {
        Button { model.toggleRunning() } label: {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                if model.isRunning && model.mode != .scroll {
                    Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
                        .scaleEffect(1 + CGFloat(model.level) * 0.35)
                        .opacity(0.9 - Double(model.level) * 0.5)
                        .animation(.easeOut(duration: 0.12), value: model.level)
                }
                Image(systemName: model.isRunning ? "pause.fill"
                      : (model.mode == .scroll ? "play.fill" : "mic.fill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

private struct NotchIcon: View {
    let system: String
    let action: () -> Void
    @StateObject private var hoverBox = Box(false)
    private var hover: Bool { hoverBox.value }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.65))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .onHover { hoverBox.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
