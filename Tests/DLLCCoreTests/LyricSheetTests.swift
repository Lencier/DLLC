import Foundation
import Testing
@testable import DLLCCore

struct LyricSheetTests {
    let sheet = """
    [Verse 1] 01:31 - 01:40
    first line
    [Pre-hook] 1:41
    [01:44.50] an LRC line, not a section
    [Hook 1] 01:50.20 – 02:04
    words
    [Outro]
    """

    @Test func readsHeadings() {
        let h = LyricSheet.headings(sheet)
        #expect(h.map(\.name) == ["Verse 1", "Pre-hook", "Hook 1", "Outro"])
        #expect(h[2].start == 110.2 && h[2].end == 124)
        let s = LyricSheet.sections(sheet, duration: 200)
        #expect(s.map(\.name) == ["Verse 1", "Pre-hook", "Hook 1"])
        #expect(s[1].start == 101 && s[1].end == 110.2) // runs to the next heading
    }

    @Test func syncBothWays() {
        var song = Song(title: "S", path: "/x.mp3", duration: 200)
        song.lyrics = sheet
        song.syncSectionsFromLyrics()
        #expect(song.sections.map(\.name) == ["Verse 1", "Pre-hook", "Hook 1"])
        var hook = song.sections[2]; hook.end = 125.5
        song.update(hook)
        song.insert(SongSection(name: "Dance Break", start: 130, end: 140))
        song.writeTimesToLyrics()
        #expect(song.lyrics.contains("[Hook 1] 01:50.20 - 02:05.50\nwords"))
        #expect(song.lyrics.contains("first line"))
        #expect(song.lyrics.hasSuffix("[Dance Break] 02:10 - 02:20"))
    }

    @Test func stamps() {
        #expect(LyricSheet.stamp(91) == "01:31")
        #expect(LyricSheet.stamp(3723.5) == "1:02:03.50")
        #expect(LyricSheet.seconds("1:02:03") == 3723)
    }
}
