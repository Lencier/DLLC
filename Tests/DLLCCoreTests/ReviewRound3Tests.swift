import Foundation
import Testing
@testable import DLLCCore

/// Fixes from the Song Cues review (round 3).
struct ReviewRound3Tests {
    private func song() -> Song {
        var s = Song(title: "T", path: "/x.mp3", duration: 60)
        s.insert(SongSection(name: "Verse 1", start: 10, end: 20))
        s.insert(SongSection(name: "Hook 1", start: 20, end: 30))
        return s
    }

    @Test func setStartPastNeighbourNeverMakesZeroLength() {
        var s = song()
        var v = s.sections[0]
        v.start = 25          // beyond its own end and the next section's start
        s.update(v)
        let after = s.sections.first { $0.id == v.id }!
        #expect(after.end - after.start >= 0.05)
        #expect(after.end <= s.sections[1].start)
    }

    @Test func renameKeepsTheHeadingAndItsLyrics() {
        var s = song()
        s.lyrics = "[Verse 1] 00:10 - 00:20\nla la\n\n[Hook 1] 00:20 - 00:30\noh oh"
        let before = s.sections
        var v = s.sections[0]; v.name = "Intro"; s.update(v)
        s.writeTimesToLyrics(previous: before)
        #expect(s.lyrics.hasPrefix("[Intro] 00:10 - 00:20\nla la"))
        #expect(!s.lyrics.contains("[Verse 1]"))
        #expect(LyricSheet.headings(s.lyrics).count == 2)
    }

    @Test func deletedSectionDoesNotComeBackFromTimes() {
        var s = song()
        s.lyrics = "[Verse 1] 00:10 - 00:20\nla la\n\n[Hook 1] 00:20 - 00:30\noh oh"
        let before = s.sections
        s.removeSection(s.sections[0].id)
        s.writeTimesToLyrics(previous: before)
        #expect(s.lyrics.contains("[Verse 1]\nla la"))   // lyrics kept, times gone
        s.syncSectionsFromLyrics()
        #expect(s.sections.map(\.name) == ["Hook 1"])
    }

    @Test func savingSoonCoalescesAndFlushWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-songs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SongStore(url: dir.appendingPathComponent("songs.json"))
        for i in 0..<20 { store.saveSoon([Song(title: "S\(i)", path: "/a.mp3", duration: 1)], delay: 5) }
        #expect(store.load().isEmpty)            // nothing written yet: still waiting
        store.flush()
        #expect(store.load().map(\.title) == ["S19"])
    }
}
