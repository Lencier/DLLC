import Foundation
import Testing
@testable import DLLCCore

struct YouTubeClientsTests {
    @Test func recognisesYouTubeLinks() {
        #expect(YouTubeClients.isYouTube("https://youtu.be/GIvkL5UjqaU"))
        #expect(YouTubeClients.isYouTube("https://www.youtube.com/watch?v=O8XIv1UBg5U"))
        #expect(YouTubeClients.isYouTube("https://m.youtube.com/shorts/abc"))
        #expect(!YouTubeClients.isYouTube("https://www.pinterest.com/pin/1/"))
        #expect(!YouTubeClients.isYouTube("https://notyoutube.com/watch"))
    }

    @Test func switchesOnRefusalsOnly() {
        #expect(YouTubeClients.shouldSwitch(stderr: "WARNING: YouTube may have enabled the SABR-only streaming experiment"))
        #expect(YouTubeClients.shouldSwitch(stderr: "ERROR: The page needs to be reloaded."))
        #expect(YouTubeClients.shouldSwitch(stderr: "ERROR: unable to download video data: HTTP Error 403: Forbidden"))
        #expect(YouTubeClients.shouldSwitch(stderr: "WARNING: Only images are available for download."))
        #expect(!YouTubeClients.shouldSwitch(stderr: "ERROR: HTTP Error 429: Too Many Requests"))
        #expect(!YouTubeClients.shouldSwitch(stderr: "ERROR: Private video. Sign in if you've been granted access"))
    }

    @Test func walksTheCascadeOnce() {
        var seen: [String] = []
        var c: String? = nil
        while let n = YouTubeClients.next(after: c) { seen.append(n); c = n }
        #expect(seen == ["tv_downgraded", "web_safari", "ios", "android"])
        #expect(YouTubeClients.next(after: "unknown") == nil)
    }

    @Test func clientArgumentsGoBeforeTheURL() {
        let t = URL(fileURLWithPath: "/tmp/tools")
        let tools = ToolPaths(ytdlp: t, ffmpeg: t, ffprobe: t, deno: t)
        let args = YTDLPCommand.analyzeArguments(url: "https://youtu.be/x", flatPlaylist: false, playlistItems: nil,
                                                 tools: tools, cookies: .none, cookiesDirectory: nil, youtubeClient: "tv_downgraded")
        let i = args.firstIndex(of: "--extractor-args")!
        #expect(args[i + 1] == "youtube:player_client=tv_downgraded")
        #expect(i < args.firstIndex(of: "--")!)
        #expect(YouTubeClients.arguments("; rm -rf") == [])
    }
}
