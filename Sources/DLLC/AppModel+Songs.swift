import AppKit
import AVFoundation
import DLLCCore
import UniformTypeIdentifiers

enum AppMode: String { case download, songs }

extension AppModel {
    static func isSongFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    func moveSong(_ id: UUID, toProject projectID: UUID?) {
        guard var s = songs.first(where: { $0.id == id }) else { return }
        s.projectID = projectID
        updateSong(s)
    }

    var selectedSong: Song? { selectedSongID.flatMap { id in songs.first { $0.id == id } } }

    /// Opens a song (or the audio of a video) for Song Cues. Opening the same file again selects it.
    func openSong(_ url: URL, projectID: UUID? = nil) async {
        let path = url.standardizedFileURL.path
        mode = .songs
        if let existing = songs.first(where: { $0.path == path && $0.projectID == (projectID ?? selectedProjectID) }) {
            selectedSongID = existing.id; return
        }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else {
            show(.error, "“\(url.lastPathComponent)” has no sound to work with.")
            return
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let song = Song(title: url.deletingPathExtension().lastPathComponent, path: path,
                        bookmark: try? url.bookmarkData(), projectID: projectID ?? selectedProjectID,
                        duration: duration.isFinite ? duration : 0)
        songs.append(song)
        selectedSongID = song.id
    }

    func chooseSongFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Choose a song (MP3, M4A, WAV…) or a video to use its sound."
        panel.prompt = "Open Song"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        mode = .songs
        let urls = panel.urls
        Task { for url in urls { await openSong(url) } }
    }

    func updateSong(_ song: Song) {
        guard let i = songs.firstIndex(where: { $0.id == song.id }) else { return }
        songs[i] = song
    }

    /// Forgets the song and its sections. The file itself is never touched.
    func removeSong(_ id: UUID) {
        songs.removeAll { $0.id == id }
        if selectedSongID == id { selectedSongID = nil }
    }

    /// The song's file now, following a move when the bookmark can; nil when it's gone.
    func songFileURL(_ song: Song) -> URL? {
        if FileManager.default.fileExists(atPath: song.path) { return URL(fileURLWithPath: song.path) }
        var stale = false
        if let data = song.bookmark, let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) {
            var s = song
            s.path = url.path
            if stale { s.bookmark = try? url.bookmarkData() }
            DispatchQueue.main.async { self.updateSong(s) }
            return url
        }
        return nil
    }

    func relocateSong(_ id: UUID) {
        guard var song = songs.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Find “\(song.title)”. Its sections are kept."
        panel.prompt = "Use This File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        song.path = url.standardizedFileURL.path
        song.bookmark = try? url.bookmarkData()
        updateSong(song)
    }

    /// A completed download's file, for "Open in Song Cues".
    func openSong(from job: Job) {
        guard let path = job.outputFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            show(.error, "The downloaded file isn’t there any more.")
            return
        }
        selectedProjectID = job.projectID
        Task { await openSong(URL(fileURLWithPath: path), projectID: job.projectID) }
    }
}
