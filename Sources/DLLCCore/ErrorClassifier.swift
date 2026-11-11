import Foundation

public enum Redactor {
    public static func redact(_ text: String) -> String {
        func replace(_ input: String, _ pattern: String, _ replacement: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
            return regex.stringByReplacingMatches(in: input, range: NSRange(input.startIndex..., in: input), withTemplate: replacement)
        }
        var value = replace(text, #"(?im)\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#, "[redacted header]")
        // Reduce every URL to scheme + host: CDN URLs carry signatures, client IPs and tokens in the
        // path as well as the query (e.g. googlevideo …/ip/<addr>/sig/…).
        if let regex = try? NSRegularExpression(pattern: #"(?i)(https?://)(?:[^/\s<>\"'?#@]*@)?([^/\s<>\"'?#@]+)[^\s<>\"']*"#) {
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                   withTemplate: "$1$2/…")
        }
        // Client IP addresses (IPv4 and IPv6).
        value = replace(value, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[ip]")
        value = replace(value, #"(?i)\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b"#, "[ip]")
        // Compressed IPv6 ("2a00:1450::5e", "fe80::1").
        value = replace(value, #"(?i)\b(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?(?![0-9a-z:])"#, "[ip]")
        value = replace(value, #"(?i)\bbearer\s+[a-z0-9._~+/=-]+"#, "Bearer [redacted]")
        value = replace(value, #"(?i)\b(sig(?:nature)?|token|access_token|key|api_key|apikey|password|cookie)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s&,;]+)"#, "$1=[redacted]")
        value = replace(value, #"/Users/[^/\s]+|/home/[^/\s]+"#, "~")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if home != "/" { value = value.replacingOccurrences(of: home, with: "~") }
        return value
    }
}

public enum ErrorClassifier {
    public static func classify(stderr: String, exitCode: Int32) -> JobError {
        let text = stderr.lowercased()
        func contains(_ patterns: String...) -> Bool { patterns.contains { text.contains($0) } }
        let category: ErrorCategory
        let message: String
        let suggestion: String
        switch true {
        case contains("no space left on device", "disk full"):
            category = .diskFull; message = "There is not enough disk space."; suggestion = "Free some space and retry."
        case contains("permission denied", "operation not permitted"):
            category = .permissionDenied; message = "Access was denied."; suggestion = "Check folder or browser access permissions and retry."
        case contains("drm", "digital rights management"):
            category = .drmProtected; message = "This media is DRM protected."; suggestion = "Choose media that permits downloading."
        case contains("not available in your country", "geo-restricted", "geographic restriction", "not available from your location"):
            category = .geoBlocked; message = "This media is unavailable in your region."; suggestion = "Choose media available in your region."
        case contains("sign in", "login required", "log in", "login-required", "authentication", "private video", "private account", "rate-limit", "rate limit", "too many requests", "http error 429", "cookies", "requires login"):
            category = .authRequired; message = "This site requires access verification or has limited requests."; suggestion = "Select authorized browser cookies in Settings, or wait and retry."
        case contains("live event will begin", "live stream", "livestream", "is live", "premiere will begin"):
            category = .liveStream; message = "This live stream has not finished."; suggestion = "Retry after the broadcast ends."
        case contains("unsupported url", "no suitable extractor"):
            category = .unsupportedURL; message = "This URL is not supported."; suggestion = "Paste a direct media or supported post URL."
        case contains("is not a valid url", "invalid url", "url could be a direct video link"):
            category = .invalidURL; message = "This is not a valid URL."; suggestion = "Paste the complete https:// URL."
        case contains("http error 404", "404 not found", "video unavailable", "this video is unavailable", "video has been removed", "video does not exist", "not found", "no video could be found"):
            category = .notFound; message = "This media was removed or could not be found."; suggestion = "Open the link in a browser and check that it still exists."
        case contains("requested format is not available", "requested format not available"):
            category = .formatUnavailable; message = "The selected quality is no longer available."; suggestion = "Analyze the link again or choose Best quality."
        case contains("timed out", "timeout", "unable to download webpage", "unable to download", "urlerror", "connection reset", "network is unreachable", "name or service not known", "nodename nor servname", "certificate verify failed", "http error 5", "http error 403"):
            category = .network; message = "The site could not be reached."; suggestion = "Check your connection and retry."
        case contains("no video formats found"):
            category = .unsupportedURL; message = "No video was found at this link."; suggestion = "It may be an image or carousel post. If it plays as a video in a browser, update yt-dlp in Settings."
        case contains("unable to extract", "please report this issue", "extractorerror"):
            category = .extractorBroken; message = "The site extractor needs an update."; suggestion = "Update yt-dlp in Settings and retry."
        case contains("no such file or directory", "read-only file system", "device not configured"):
            category = .destinationUnavailable; message = "A required file or destination is unavailable."; suggestion = "Reconnect the destination drive or choose another folder."
        default:
            category = exitCode == 0 ? .unknown : .toolFailure
            message = "The media tool could not complete this job."; suggestion = "Retry and check the technical details if it fails again."
        }
        return JobError(category: category, message: message, suggestion: suggestion,
            technical: Redactor.redact(stderr.components(separatedBy: .newlines).suffix(40).joined(separator: "\n")),
            isRecoverable: category != .drmProtected && category != .unsupportedURL && category != .notFound)
    }
}
