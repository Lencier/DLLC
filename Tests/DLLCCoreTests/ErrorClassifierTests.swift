import Foundation
import Testing
@testable import DLLCCore

struct ErrorClassifierTests {
    @Test(arguments: [
        ("ERROR: Unsupported URL: https://example.com/", ErrorCategory.unsupportedURL),
        ("ERROR: [generic] 'not-a-url' is not a valid URL", .invalidURL),
        ("ERROR: [youtube] xxxxxxxxxxx: This video is unavailable", .notFound),
        ("ERROR: [twitter] 1387284264997924864: No video could be found in this tweet", .notFound),
        ("ERROR: HTTP Error 404: Not Found", .notFound),
        ("ERROR: This video has been removed by the uploader", .notFound),
        ("ERROR: Sign in to confirm you're not a bot. Use --cookies-from-browser", .authRequired),
        ("ERROR: Login required. This is a private video", .authRequired),
        ("ERROR: HTTP Error 429: Too Many Requests (rate-limit)", .authRequired),
        ("ERROR: This video is not available in your country", .geoBlocked),
        ("ERROR: This video is DRM protected", .drmProtected),
        ("ERROR: The live stream is not finished", .liveStream),
        ("ERROR: Unable to download webpage: <urlopen error timed out>", .network),
        ("ERROR: [Errno 28] No space left on device", .diskFull),
        ("ERROR: [Errno 13] Permission denied: '/Volumes/Media'", .permissionDenied),
        ("ERROR: Operation not permitted", .permissionDenied),
        ("ERROR: Requested format is not available. Use --list-formats", .formatUnavailable),
        ("ERROR: Unable to extract video data; please report this issue", .extractorBroken),
        ("ERROR: [Pinterest] No video formats found!; please report this issue", .unsupportedURL),
        ("ERROR: Read-only file system", .destinationUnavailable),
        ("ERROR: unexpected subprocess failure", .toolFailure)
    ])
    func table(stderr: String, expected: ErrorCategory) {
        let error = ErrorClassifier.classify(stderr: stderr, exitCode: 1)
        #expect(error.category == expected)
        #expect(error.suggestion?.isEmpty == false)
        if expected == .extractorBroken { #expect(error.suggestion?.contains("Settings") == true) }
    }
    @Test func redactedTail() {
        let log = Array(repeating: "old log", count: 50).joined(separator: "\n") + "\nERROR token=secret /Users/alice/movie"
        let error = ErrorClassifier.classify(stderr: log, exitCode: 1)
        #expect(error.technical?.components(separatedBy: "\n").count == 40)
        #expect(error.technical?.contains("secret") == false)
        #expect(error.technical?.contains("~/movie") == true)
    }
}
struct RedactorTests {
    @Test func secrets() {
        let input = """
        Authorization: Bearer sensitive
        Cookie: session=private; auth=private
        https://rr1.googlevideo.com/videoplayback?ip=1.2.3.4&sig=secret
        https://cdn.example.com/video.mp4?token=other
        sig=secret token=other key=hidden /Users/alice/Downloads /home/bob/video
        """
        let result = Redactor.redact(input)
        for secret in ["sensitive", "private", "1.2.3.4", "secret", "other", "hidden", "alice", "bob"] {
            #expect(!result.contains(secret))
        }
        #expect(result.contains("https://rr1.googlevideo.com/…") && !result.contains("videoplayback"))
        #expect(result.contains("~/Downloads"))
    }
}

@Suite struct RedactorPathSecretsTests {
    @Test func pathStyleSignaturesAndIPs() {
        let s = Redactor.redact("Error opening https://manifest.googlevideo.com/api/manifest/ip/2001:db8:85a3:8d3:1319:8a2e:370:7348/sig/AE0s2J/index.m3u8 from 192.168.1.20 at 00:01:23.500")
        #expect(!s.contains("2001:db8"))
        #expect(!s.contains("AE0s2J"))
        #expect(!s.contains("192.168.1.20"))
        #expect(s.contains("https://manifest.googlevideo.com/…"))
        #expect(s.contains("00:01:23.500"))
    }

    @Test func compressedIPv6AndBearer() {
        let s = Redactor.redact("connect to 2a00:1450::5e failed; via fe80::1; Authorization-less Bearer abc.DEF_123 ; time 12:34:56 and 01:02")
        #expect(!s.contains("2a00:1450"))
        #expect(!s.contains("fe80::1"))
        #expect(!s.contains("abc.DEF_123"))
        #expect(s.contains("12:34:56"))
        #expect(s.contains("01:02"))
    }

    @Test func postWithoutVideoIsNotReportedAsABrokenExtractor() {
        let log = "ERROR: [Pinterest] 750904937913106472: No video formats found!; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template."
        let error = ErrorClassifier.classify(stderr: log, exitCode: 1)
        #expect(error.category == .unsupportedURL)
        #expect(error.message == "No video was found at this link.")
    }
}
