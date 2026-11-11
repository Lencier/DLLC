import Darwin
import Foundation

/// Guards for files that arrive from the internet: only media is saved, and saved files carry the
/// macOS quarantine mark so Gatekeeper checks anything that is opened as more than a document.
public enum FileSafety {
    /// Video, audio, image and subtitle types DLLC produces or yt-dlp delivers.
    public static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "flv", "3gp",
        "mp3", "m4a", "aac", "wav", "flac", "opus", "ogg", "oga", "alac", "aiff", "aif",
        "gif", "jpg", "jpeg", "png", "webp", "heic",
        "srt", "vtt", "ass", "ssa", "lrc",
    ]

    public static func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

    /// Marks a downloaded file as coming from the internet (like Safari does). Best effort.
    public static func quarantine(_ url: URL, agent: String = "DLLC") {
        let value = String(format: "0081;%08x;%@;", Int(Date().timeIntervalSince1970), agent)
        _ = value.withCString { ptr in
            setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }
}
