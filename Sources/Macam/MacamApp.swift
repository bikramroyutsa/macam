import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var camera = CameraModel()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var prompter = TeleprompterModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(profiles)
                .environmentObject(prompter)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Camera") {
                Button(camera.mode == .video ? (camera.isRecording ? "Stop Recording" : "Record Video") : "Take Photo") { camera.shutter() }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                ForEach(Array(profiles.all.enumerated()), id: \.element.id) { i, p in
                    if i < 9 {
                        Button(p.name) { profiles.selectedID = p.id }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    } else {
                        Button(p.name) { profiles.selectedID = p.id }
                    }
                }
                Divider()
                Toggle("Mirror", isOn: $camera.mirrored)
            }

            CommandMenu("Teleprompter") {
                Button(prompter.isPresented ? "Hide from Notch" : "Show in Notch") {
                    prompter.isPresented.toggle()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button(prompter.isRunning ? "Pause" : "Start") { prompter.toggleRunning() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Back to Start") { prompter.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(prompter.showScript ? "Hide Script" : "Edit Script") { prompter.showScript.toggle() }
                    .keyboardShortcut("e", modifiers: .command)
                Picker("Mode", selection: $prompter.mode) {
                    ForEach(PromptMode.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
    }
}
