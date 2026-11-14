import SwiftUI

/// A capture shape. Built-ins are fixed; custom ones are user-made and persisted.
struct AspectProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var width: Double
    var height: Double
    var isCustom: Bool

    var ratio: CGFloat { CGFloat(width / height) }

    static let builtIns: [AspectProfile] = [
        .init(id: "4:3", name: "4:3", width: 4, height: 3, isCustom: false),
        .init(id: "16:9", name: "16:9", width: 16, height: 9, isCustom: false),
        .init(id: "16:10", name: "16:10", width: 16, height: 10, isCustom: false),
        .init(id: "1:1", name: "1:1", width: 1, height: 1, isCustom: false),
        .init(id: "9:16", name: "9:16", width: 9, height: 16, isCustom: false),
    ]
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var custom: [AspectProfile] {
        didSet { persist() }
    }
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedProfileID") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "customProfiles"),
           let decoded = try? JSONDecoder().decode([AspectProfile].self, from: data) {
            custom = decoded
        } else {
            custom = []
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedProfileID") ?? "16:9"
    }

    var all: [AspectProfile] { AspectProfile.builtIns + custom }
    var selected: AspectProfile { all.first { $0.id == selectedID } ?? AspectProfile.builtIns[1] }

    func add(name: String, width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let profile = AspectProfile(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "\(Self.format(width))×\(Self.format(height))" : trimmed,
            width: width, height: height, isCustom: true)
        custom.append(profile)
        selectedID = profile.id
    }

    func delete(_ profile: AspectProfile) {
        guard profile.isCustom else { return }
        if selectedID == profile.id { selectedID = "16:9" }
        custom.removeAll { $0.id == profile.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: "customProfiles")
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
