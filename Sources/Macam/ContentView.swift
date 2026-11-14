import AVFoundation
import SwiftUI

// MARK: - Helpers

extension View {
    @ViewBuilder
    func glass<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 720, height: 520)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var camera: CameraModel
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var prompter: TeleprompterModel
    private var showScript: Bool { prompter.showScript }

    private let topInset: CGFloat = 58
    private let bottomInset: CGFloat = 118
    private let panelWidth: CGFloat = 300

    var body: some View {
        ZStack {
            VisualEffect().ignoresSafeArea()
            WindowConfigurator().frame(width: 0, height: 0)

            GeometryReader { geo in
                let rightReserve: CGFloat = showScript ? panelWidth + 16 : 0
                let avail = CGSize(width: max(100, geo.size.width - 48 - rightReserve),
                                   height: max(100, geo.size.height - topInset - bottomInset))
                let fit = Self.fit(ratio: profiles.selected.ratio, in: avail)

                cameraStage
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    .position(x: 24 + avail.width / 2, y: topInset + avail.height / 2)
            }

            VStack {
                ProfilePicker()
                    .padding(.top, 12)
                Spacer()
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
            }

            if showScript {
                HStack {
                    Spacer()
                    ScriptPanel(close: { prompter.showScript = false })
                        .frame(width: panelWidth)
                        .padding(.trailing, 16)
                        .padding(.top, topInset)
                        .padding(.bottom, bottomInset - 8)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.55), value: profiles.selectedID)
        .animation(.smooth(duration: 0.5), value: showScript)
        .animation(.smooth(duration: 0.35), value: camera.mode)
        .onAppear {
            camera.start()
            prompter.installNotch()
        }
        .onChange(of: profiles.selected.ratio, initial: true) { _, new in camera.captureRatio = new }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func fit(ratio: CGFloat, in size: CGSize) -> CGSize {
        var w = size.width, h = w / ratio
        if h > size.height { h = size.height; w = h * ratio }
        return CGSize(width: w, height: h)
    }

    // MARK: Stage

    @ViewBuilder
    private var cameraStage: some View {
        ZStack {
            Color.black
            switch camera.authorization {
            case .authorized:
                CameraPreview(session: camera.session, mirrored: camera.mirrored, deviceID: camera.currentDeviceID)
                Color.white.opacity(camera.flash ? 1 : 0).allowsHitTesting(false)
                if camera.isRecording {
                    VStack {
                        HStack(spacing: 7) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text(Self.clock(camera.elapsed))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glass(Capsule())
                        .padding(.top, 14)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let n = camera.countdown {
                    Text("\(n)")
                        .font(.system(size: 120, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 12)
                        .contentTransition(.numericText(countsDown: true))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            case .notDetermined:
                ProgressView().controlSize(.small)
            default:
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.system(size: 28, weight: .light))
                    Text("Camera access is off").font(.headline)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center) {
            HStack {
                if let image = camera.lastPhoto {
                    Button { camera.revealLastPhoto() } label: {
                        Image(nsImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                    .id(camera.lastPhotoURL)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                ModeToggle()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            Button { camera.shutter() } label: { Color.clear }
                .buttonStyle(ShutterStyle(video: camera.mode == .video,
                                          active: camera.countdown != nil || camera.isRecording))
                .disabled(camera.authorization != .authorized)

            HStack(spacing: 2) {
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if camera.devices.count > 1 { deviceMenu }
                    timerMenu
                    if camera.mode == .video { resolutionMenu }
                    BarButton(system: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                              active: camera.mirrored, help: "Mirror") {
                        withAnimation(.smooth) { camera.mirrored.toggle() }
                    }
                    BarButton(system: "rectangle.topthird.inset.filled",
                              active: prompter.isPresented, help: "Notch teleprompter (⌘T)") {
                        prompter.isPresented.toggle()
                    }
                    BarButton(system: "doc.text", active: showScript, help: "Script (⌘E)") {
                        prompter.showScript.toggle()
                    }
                }
                .padding(4)
                .glass(Capsule())
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(camera.devices, id: \.uniqueID) { d in
                Button {
                    camera.select(d)
                } label: {
                    if d.uniqueID == camera.currentDeviceID { Label(d.localizedName, systemImage: "checkmark") }
                    else { Text(d.localizedName) }
                }
            }
        } label: {
            Image(systemName: "video").font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Camera")
    }

    private var resolutionMenu: some View {
        Menu {
            Picker("Resolution", selection: $camera.resolution) {
                ForEach(VideoResolution.allCases) { r in
                    Text("\(r.label)  —  \(r.detail)").tag(r)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(camera.resolution.label)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, 4)
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(camera.isRecording)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .help("Video resolution")
    }

    private var timerMenu: some View {
        Menu {
            Picker("Timer", selection: $camera.timerSeconds) {
                Text("Off").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: camera.timerSeconds > 0 ? "timer.circle.fill" : "timer")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(camera.timerSeconds > 0 ? Color.accentColor : .primary)
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help("Timer")
    }
}

// MARK: - Controls

struct BarButton: View {
    let system: String
    var active = false
    var help = ""
    let action: () -> Void
    @StateObject private var hoverBox = Box(false)
    private var hover: Bool { get { hoverBox.value } nonmutating set { hoverBox.value = newValue } }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .help(help)
    }
}

struct ShutterStyle: ButtonStyle {
    var video: Bool
    var active: Bool   // counting down, or recording
    func makeBody(configuration: Configuration) -> some View {
        let red = video || active
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 3.5).frame(width: 64, height: 64)
            RoundedRectangle(cornerRadius: active ? 8 : 25, style: .continuous)
                .fill(red ? Color.red : .white)
                .frame(width: active ? 26 : 50, height: active ? 26 : 50)
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
        .animation(.smooth(duration: 0.3), value: active)
        .animation(.smooth(duration: 0.3), value: video)
    }
}

struct ModeToggle: View {
    @EnvironmentObject var camera: CameraModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach([CaptureMode.photo, .video], id: \.self) { m in
                let selected = camera.mode == m
                Button { camera.mode = m } label: {
                    Image(systemName: m == .photo ? "camera.fill" : "video.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(width: 34, height: 30)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(m == .photo ? "Photo" : "Video")
            }
        }
        .padding(3)
        .glass(Capsule())
        .disabled(camera.isRecording)
        .animation(.smooth(duration: 0.3), value: camera.mode)
    }
}

// MARK: - Profile picker

struct ProfilePicker: View {
    @EnvironmentObject var profiles: ProfileStore
    @Namespace private var ns
    @StateObject private var addingBox = Box(false)
    private var adding: Bool { get { addingBox.value } nonmutating set { addingBox.value = newValue } }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(profiles.all) { p in
                let selected = p.id == profiles.selectedID
                Button { profiles.selectedID = p.id } label: {
                    Text(p.name)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if p.isCustom {
                        Button("Delete “\(p.name)”", role: .destructive) { profiles.delete(p) }
                    }
                }
                .help(p.isCustom ? "\(ProfileStore.format(p.width)) × \(ProfileStore.format(p.height))" : "")
            }

            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 4)

            Button { adding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New custom size")
            .popover(isPresented: $addingBox.value, arrowEdge: .bottom) {
                NewProfileForm(done: { adding = false })
            }
        }
        .padding(4)
        .glass(Capsule())
        .animation(.smooth(duration: 0.4), value: profiles.selectedID)
        .animation(.smooth(duration: 0.4), value: profiles.custom.count)
    }
}

struct NewProfileForm: View {
    @EnvironmentObject var profiles: ProfileStore
    var done: () -> Void
    @StateObject private var nameBox = Box("")
    @StateObject private var widthBox = Box(3.0)
    @StateObject private var heightBox = Box(2.0)
    private var name: String { nameBox.value }
    private var width: Double { widthBox.value }
    private var height: Double { heightBox.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom size").font(.headline)
            TextField("Name (optional)", text: $nameBox.value).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Width", value: $widthBox.value, format: .number).textFieldStyle(.roundedBorder)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", value: $heightBox.value, format: .number).textFieldStyle(.roundedBorder)
            }
            Text(width > 0 && height > 0 ? "Ratio \(String(format: "%.2f", width / height)) : 1" : "Enter positive numbers")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    profiles.add(name: name, width: width, height: height)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(width > 0 && height > 0))
            }
        }
        .padding(16)
        .frame(width: 250)
    }
}

// MARK: - Script panel

struct ScriptPanel: View {
    @EnvironmentObject var prompter: TeleprompterModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Script").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: $prompter.script)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.25)))

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $prompter.mode) {
                    ForEach(PromptMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(prompter.mode.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary).frame(width: 18)
                Slider(value: $prompter.fontSize, in: 18...48)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary).frame(width: 18)
                    Slider(value: $prompter.panelWidth, in: TeleprompterModel.minWidth...prompter.maxPanelWidth)
                }
                .help("Notch width")
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.and.down").foregroundStyle(.secondary).frame(width: 18)
                    Stepper("\(prompter.visibleLines) \(prompter.visibleLines == 1 ? "line" : "lines")",
                            value: $prompter.visibleLines, in: 1...TeleprompterModel.maxLines)
                    Button("Reset") { prompter.resetSize() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                .help("Notch height")
            }

            if prompter.mode == .scroll {
                HStack(spacing: 10) {
                    Image(systemName: "speedometer").foregroundStyle(.secondary).frame(width: 18)
                    Slider(value: $prompter.speed, in: 0.5...6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button {
                    if !prompter.isPresented { prompter.isPresented = true }
                    prompter.toggleRunning()
                } label: {
                    Label(prompter.isRunning ? "Pause" : "Start",
                          systemImage: prompter.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { prompter.reset() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered).controlSize(.large)
                .help("Back to start")
            }

            if !prompter.status.isEmpty {
                Text(prompter.status).font(.caption).foregroundStyle(.orange)
            }
            if prompter.mode != .scroll {
                VStack(alignment: .leading, spacing: 4) {
                    if prompter.isRunning {
                        Text(prompter.heard.isEmpty ? "Listening…" : "Heard: \(prompter.heard)")
                            .lineLimit(2)
                    }
                    if !prompter.vocabStatus.isEmpty { Text(prompter.vocabStatus) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth(duration: 0.3), value: prompter.mode)
    }
}
