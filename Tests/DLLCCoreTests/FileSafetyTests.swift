import Foundation
import Testing
@testable import DLLCCore

struct FileSafetyTests {
    @Test func onlyMediaIsAllowed() {
        for ok in ["a.mp4", "b.M4A", "c.webm", "d.gif", "e.srt", "f.mp3"] { #expect(FileSafety.isMedia(URL(fileURLWithPath: "/x/" + ok))) }
        for bad in ["a.app", "b.command", "c.sh", "d.pkg", "e.dmg", "f.zip", "g.exe", "h", "i.scpt"] {
            #expect(!FileSafety.isMedia(URL(fileURLWithPath: "/x/" + bad)))
        }
    }

    @Test func quarantineIsSet() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-q-\(UUID()).mp4")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        FileSafety.quarantine(url)
        #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }

    @Test func cueInputsAreLocalOnly() {
        let args = CueCommand.audio(song: URL(fileURLWithPath: "/tmp/s.mp3"), padded: TimeRange(start: 0, end: 1),
                                    options: CueOptions(), countIn: nil, output: URL(fileURLWithPath: "/tmp/o.mp3"))
        let i = args.firstIndex(of: "-i")!
        #expect(args[i - 2] == "-protocol_whitelist" && args[i - 1] == "file")
    }
}
