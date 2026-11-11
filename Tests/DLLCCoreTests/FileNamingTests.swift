import Foundation
import Testing
@testable import DLLCCore

struct FileNamingTests {
    @Test func unicodeAndUnsafeNames() {
        #expect(FileNaming.sanitize(".. สวัสดี 👩🏽‍💻 /งาน:ทดสอบ  . ") == "สวัสดี 👩🏽‍💻 -งาน-ทดสอบ")
        #expect(FileNaming.sanitize("... /:\u{00} ") == "Untitled")
        #expect(FileNaming.sanitize(" A   B\tC ") == "A B C")
        #expect(FileNaming.sanitize("Part 1/2: Intro") == "Part 1-2- Intro")
        #expect(FileNaming.sanitize(".hidden") == "hidden")
        #expect(FileNaming.sanitize("hello", maxBytes: 0).isEmpty)
    }
    @Test func byteLimitPreservesGraphemes() {
        let unit = "ก้👩🏽‍💻"
        let long = String(repeating: unit, count: 200)
        let name = FileNaming.sanitize(long)
        #expect(name.utf8.count <= 180)
        #expect(long.hasPrefix(name))
        #expect(name.last == "ก้" || name.last == "👩🏽‍💻")
        #expect(FileNaming.sanitize("👩🏽‍💻", maxBytes: 2) == "Un")
        #expect(FileNaming.sanitize(String(repeating: "a", count: 500)).utf8.count == 180)
    }
    @Test func collisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for expected in ["ชื่อ 🎬.mp4", "ชื่อ 🎬 (2).mp4", "ชื่อ 🎬 (3).mp4"] {
            let url = FileNaming.uniqueURL(in: dir, baseName: "ชื่อ 🎬", ext: "mp4")
            #expect(url.lastPathComponent == expected)
            try Data().write(to: url)
        }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("dangling.mp4").path, withDestinationPath: "/nonexistent/dllc")
        #expect(FileNaming.uniqueURL(in: dir, baseName: "dangling", ext: "mp4").lastPathComponent == "dangling (2).mp4")
    }
    @Test func tags() {
        #expect(FileNaming.timeTag(83.456) == "01-23.456")
        #expect(FileNaming.timeTag(3723.5) == "1-02-03.500")
        #expect(!FileNaming.rangeTag(TimeRange(start: 12, end: 18.5)).contains(":"))
    }
}
struct TimecodeTests {
    @Test(arguments: [("83.5", 83.5), ("1:23.5", 83.5), ("01:23", 83.0), ("1:02:03.25", 3723.25), (" 0 ", 0.0)])
    func valid(text: String, expected: Double) { #expect(Timecode.parse(text) == expected) }
    @Test(arguments: ["", "-1", "1:60", "1:60:00", "1:02:03:12", "1::2", "nan", "inf", "1e3", "1.5:02", "1: 02", ":12", "abc", "+1"])
    func invalid(text: String) { #expect(Timecode.parse(text) == nil) }
    @Test func formatting() {
        #expect(Timecode.format(123.25) == "02:03.250")
        #expect(Timecode.format(3723.25) == "1:02:03.250")
        #expect(Timecode.format(59.9996) == "01:00.000")
        #expect(Timecode.format(0, alwaysHours: true) == "0:00:00.000")
        #expect(Timecode.format(.nan) == "00:00.000")
    }
}
struct RangeValidatorTests {
    @Test func validation() {
        #expect(RangeValidator.validate(start: nil, end: nil, duration: 10) == .empty)
        #expect(RangeValidator.validate(start: nil, end: 2, duration: 10) == .malformedStart)
        #expect(RangeValidator.validate(start: 0, end: nil, duration: 10) == .malformedEnd)
        #expect(RangeValidator.validate(start: .nan, end: 2, duration: 10) == .malformedStart)
        #expect(RangeValidator.validate(start: 0, end: .infinity, duration: 10) == .malformedEnd)
        #expect(RangeValidator.validate(start: -1, end: 2, duration: 10) == .negative)
        #expect(RangeValidator.validate(start: 2, end: 2, duration: 10) == .startNotBeforeEnd)
        #expect(RangeValidator.validate(start: 2, end: 11, duration: 10) == .beyondDuration)
        #expect(RangeValidator.validate(start: 2, end: 2.01, duration: 10) == .tooShort)
        #expect(RangeValidator.validate(start: 1, end: 1 + 1 / 59.94, duration: 10, minDuration: 1 / 59.94) == nil)
        #expect(RangeValidator.validate(start: 0, end: 10, duration: 10) == nil)
    }
}
