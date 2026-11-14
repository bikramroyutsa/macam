import AVFoundation

/// Container + codec combinations, used both for recording and for converting.
enum VideoFormat: String, CaseIterable, Identifiable {
    case movH264, movHEVC, mp4H264, mp4HEVC, proRes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .movH264: "MOV · H.264"
        case .movHEVC: "MOV · HEVC"
        case .mp4H264: "MP4 · H.264"
        case .mp4HEVC: "MP4 · HEVC"
        case .proRes: "MOV · ProRes 422"
        }
    }

    /// Short form for tight spaces such as the camera bar.
    var compactLabel: String {
        switch self {
        case .movH264: "MOV"
        case .movHEVC: "MOV·HEVC"
        case .mp4H264: "MP4"
        case .mp4HEVC: "MP4·HEVC"
        case .proRes: "ProRes"
        }
    }

    var detail: String {
        switch self {
        case .movH264: "Most compatible"
        case .movHEVC: "Smaller files"
        case .mp4H264: "Web and social"
        case .mp4HEVC: "Smaller files, web"
        case .proRes: "For editing. Very large files"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4H264, .mp4HEVC: .mp4
        default: .mov
        }
    }

    var fileExtension: String { fileType == .mp4 ? "mp4" : "mov" }

    var codec: AVVideoCodecType {
        switch self {
        case .movH264, .mp4H264: .h264
        case .movHEVC, .mp4HEVC: .hevc
        case .proRes: .proRes422
        }
    }

    /// Largest frame side the encoder accepts, if limited (H.264 tops out at 4096).
    var maxSide: Int? { codec == .h264 ? 4096 : nil }

    /// The export preset that produces this format when converting an existing video.
    var exportPreset: String {
        switch codec {
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        default: AVAssetExportPresetHighestQuality
        }
    }

    /// Video settings for recording live.
    func videoSettings(width: Int, height: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if codec == .h264 {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(6_000_000, width * height * 5),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        } else if codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 3),
            ]
        }
        return settings
    }
}

/// Everything the editor can convert to: a video format, audio only, or an animated GIF.
enum ExportFormat: Hashable, Identifiable {
    case video(VideoFormat)
    case audio
    case gif

    static let all: [ExportFormat] = VideoFormat.allCases.map { .video($0) } + [.audio, .gif]

    var id: String {
        switch self {
        case .video(let f): f.rawValue
        case .audio: "audio"
        case .gif: "gif"
        }
    }

    var label: String {
        switch self {
        case .video(let f): f.label
        case .audio: "Audio only · M4A"
        case .gif: "Animated GIF"
        }
    }

    var detail: String {
        switch self {
        case .video(let f): f.detail
        case .audio: "Just the sound"
        case .gif: "Short silent loop"
        }
    }

    var fileExtension: String {
        switch self {
        case .video(let f): f.fileExtension
        case .audio: "m4a"
        case .gif: "gif"
        }
    }

    var isVideo: Bool { if case .video = self { true } else { false } }
}
