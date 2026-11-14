import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension URL {
    var isVideoFile: Bool { ["mov", "mp4", "m4v"].contains(pathExtension.lowercased()) }
}

// MARK: - Editor host

/// Owns the video editor that is open (if any), so the whole window can switch between camera and editor.
@MainActor
final class EditorHost: ObservableObject {
    @Published private(set) var editor: VideoEditor?
    var isEditing: Bool { editor != nil }
    var onSaved: ((URL) -> Void)?

    func open(_ url: URL) {
        let e = VideoEditor(url: url)
        e.onSaved = { [weak self] saved in self?.onSaved?(saved) }
        editor?.close()
        withAnimation(.smooth(duration: 0.45)) { editor = e }
    }

    func close() {
        editor?.close()
        withAnimation(.smooth(duration: 0.45)) { editor = nil }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.message = "Choose a video to edit"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

// MARK: - Library model

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let date: Date
    var isVideo: Bool { url.isVideoFile }
    var id: URL { url }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var loaded = false

    func reload() {
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            items = found
            loaded = true
        }
    }

    func trash(_ item: MediaItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }

    nonisolated private static func scan() -> [MediaItem] {
        let fm = FileManager.default
        let dirs = [
            fm.urls(for: .moviesDirectory, in: .userDomainMask).first?.appendingPathComponent("Macam"),
            fm.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Macam"),
        ].compactMap { $0 }
        let allowed: Set<String> = ["mov", "mp4", "m4v", "jpg", "jpeg", "png", "heic", "gif"]
        var out: [MediaItem] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for f in files where allowed.contains(f.pathExtension.lowercased()) {
                let values = try? f.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                out.append(MediaItem(url: f, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast))
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(90))
    }
}

// MARK: - Thumbnails

@MainActor
final class TileLoader: ObservableObject {
    private static let cache = NSCache<NSURL, NSImage>()
    @Published private(set) var image: NSImage?
    @Published private(set) var duration: Double?
    private let item: MediaItem

    init(item: MediaItem) {
        self.item = item
        image = Self.cache.object(forKey: item.url as NSURL)
    }

    func load() async {
        if image == nil {
            let url = item.url
            let img: NSImage?
            if item.isVideo {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 360, height: 360)
                if let r = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)) {
                    img = NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
                } else { img = nil }
            } else {
                img = await Task.detached { () -> NSImage? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: 360,
                                                 kCGImageSourceCreateThumbnailWithTransform: true]
                    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
            }
            if let img {
                Self.cache.setObject(img, forKey: item.url as NSURL)
                withAnimation(.easeOut(duration: 0.25)) { image = img }
            }
        }
        if item.isVideo, duration == nil {
            duration = try? await AVURLAsset(url: item.url).load(.duration).seconds
        }
    }
}

// MARK: - Library UI

struct LibraryButton: View {
    @EnvironmentObject var host: EditorHost
    @StateObject private var openBox = Box(false)
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        Button { openBox.value.toggle() } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hoverBox.value ? 0.12 : 0)))
                .glass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoverBox.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hoverBox.value)
        .help("Library")
        .popover(isPresented: $openBox.value, arrowEdge: .top) {
            LibraryPopover(dismiss: { openBox.value = false })
                .environmentObject(host)
        }
    }
}

struct LibraryPopover: View {
    @EnvironmentObject var host: EditorHost
    @StateObject private var library = Library()
    var dismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(116), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                    host.openPanel()
                } label: {
                    Label("Open…", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Edit any video on your Mac")
            }

            if library.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: library.loaded ? "photo.on.rectangle.angled" : "hourglass")
                        .font(.system(size: 24, weight: .light))
                    Text(library.loaded ? "Photos and videos you take appear here" : "Loading…")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(library.items) { item in
                            LibraryTile(item: item)
                                .onTapGesture {
                                    if item.isVideo {
                                        dismiss()
                                        host.open(item.url)
                                    } else {
                                        NSWorkspace.shared.open(item.url)
                                    }
                                }
                                .contextMenu {
                                    if item.isVideo { Button("Edit") { dismiss(); host.open(item.url) } }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { library.trash(item) }
                                }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(height: 330)
            }
        }
        .padding(14)
        .frame(width: 388)
        .onAppear { library.reload() }
    }
}

struct LibraryTile: View {
    let item: MediaItem
    @StateObject private var loader: TileLoader
    @StateObject private var hoverBox = Box(false)

    init(item: MediaItem) {
        self.item = item
        _loader = StateObject(wrappedValue: TileLoader(item: item))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.white.opacity(0.07))
            if let image = loader.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            }
            if item.isVideo {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    if let d = loader.duration {
                        Text(Self.clock(d)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
        }
        .frame(width: 116, height: 116)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(hoverBox.value ? 0.5 : 0.1), lineWidth: hoverBox.value ? 2 : 1))
        .scaleEffect(hoverBox.value ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hoverBox.value)
        .onHover { hoverBox.value = $0 }
        .task { await loader.load() }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
