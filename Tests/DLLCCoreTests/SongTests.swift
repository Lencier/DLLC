import Foundation
import Testing
@testable import DLLCCore

struct SongTests {
    private func sec(_ name: String, _ s: Double, _ e: Double) -> SongSection { SongSection(name: name, start: s, end: e) }

    @Test func namingRules() {
        let r = TimeRange(start: 102, end: 151)
        #expect(CueNaming.baseName(sections: [sec("Hook 2", 0, 1)], range: r, songTitle: "TOP 5", prefix: "", speed: .x1) == "TOP 5 - Hook 2")
        #expect(CueNaming.baseName(sections: [sec("Verse 1", 5, 6), sec("Intro", 0, 5)], range: r, songTitle: "S", prefix: "", speed: .x1) == "S - Intro+Verse 1")
        let four = [sec("Intro", 0, 1), sec("Verse 1", 1, 2), sec("Pre-hook", 2, 3), sec("Hook 1", 3, 4)]
        #expect(CueNaming.baseName(sections: four, range: r, songTitle: "S", prefix: "", speed: .x1) == "S - Intro→Hook 1")
        #expect(CueNaming.baseName(sections: [], range: r, songTitle: "Song", prefix: "", speed: .x1) == "Song - 1m42s-2m31s")
        #expect(CueNaming.baseName(sections: [sec("Hook 2", 0, 1)], range: r, songTitle: "S", prefix: "S5Sh4", speed: .x2) == "S5Sh4 S - Hook 2 (fast x2)")
        #expect(CueNaming.baseName(sections: [sec("Hook 2", 0, 1)], range: r, songTitle: "TOP 5", prefix: "", speed: .half) == "TOP 5 - Hook 2 (slow 2x)")
    }

    @Test func unsafeNamesAreCleaned() {
        let n = CueNaming.baseName(sections: [sec("Verse 1/2", 0, 1)], range: TimeRange(start: 0, end: 1),
                                   songTitle: "", prefix: "", speed: .x1)
        #expect(n == "Verse 1-2")
        #expect(CueNaming.clean("..:") == "-")
    }

    @Test func uniqueNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-song-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CueNaming.uniqueURL(in: dir, base: "Hook 2", ext: "mp3").lastPathComponent == "Hook 2.mp3")
        try Data().write(to: dir.appendingPathComponent("Hook 2.mp3"))
        #expect(CueNaming.uniqueURL(in: dir, base: "Hook 2", ext: "mp3").lastPathComponent == "Hook 2 (2).mp3")
    }

    @Test func paddedRangeClampsToSong() {
        var o = CueOptions(); o.padBefore = 3; o.padAfter = 5
        #expect(CueMath.padded(TimeRange(start: 1, end: 10), options: o, duration: 12) == TimeRange(start: 0, end: 12))
        #expect(CueMath.padded(TimeRange(start: 20, end: 30), options: o, duration: 100) == TimeRange(start: 17, end: 35))
    }

    @Test func outputDurationWithSpeedAndCountIn() {
        var o = CueOptions(); o.speed = .x2; o.countIn = CountIn(count: 4, interval: 0.5)
        #expect(abs(CueMath.outputDuration(range: TimeRange(start: 0, end: 10), options: o) - 7) < 1e-9)
    }

    @Test func sectionsStayOrderedWithoutOverlap() {
        var song = Song(title: "S", path: "/x.mp3", duration: 100)
        song.insert(sec("B", 50, 60))
        song.insert(sec("A", 10, 70)) // clipped to end where B starts
        #expect(song.sections.map(\.name) == ["A", "B"])
        #expect(song.sections[0].end == 50)
        #expect(song.insert(sec("C", 55, 58)) == nil) // starts inside B
        var b = song.sections[1]; b.start = 30 // can't reach into A
        song.update(b)
        #expect(song.sections[1].start == 50)
        #expect(CueMath.range(of: song.sections) == TimeRange(start: 10, end: 60))
    }

    @Test func storeRoundTripsAndKeepsMissingFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dllc-songs-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SongStore(url: url)
        let song = Song(title: "Gone", path: "/no/such/file.mp3", duration: 200, sections: [sec("Hook 1", 60, 80)])
        store.save([song])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].sections.map(\.name) == ["Hook 1"])
    }

    @Test func speedLabels() {
        #expect(CueSpeed.half.label == "÷2")
        #expect(CueSpeed.x1.label == "NM")
        #expect(CueSpeed.third.fileSuffix == "(slow 3x)")
        #expect(CueSpeed.x3.fileSuffix == "(fast x3)")
        #expect(CueSpeed.slowToFast.first == .quarter && CueSpeed.slowToFast.last == .x4)
        #expect(CueSpeed.allCases.count == 7)
    }

    @Test func moveSplitAndMarkers() {
        var song = Song(title: "S", path: "/x.mp3", duration: 100, sections: [sec("A", 10, 20), sec("B", 30, 40)])
        let a = song.sections[0].id, b = song.sections[1].id
        song.move(a, toStart: 25) // stopped by B, keeps length 10
        #expect(song.sections[0].start == 20 && song.sections[0].end == 30)
        song.move(b, toStart: 95)
        #expect(song.sections[1].end == 100 && song.sections[1].start == 90)
        let second = song.split(a, at: 24)
        #expect(second?.name == "A (2)" && song.sections.count == 3 && song.sections[0].end == 24)
        song.addMarker(50); song.addMarker(5); song.addMarker(50.001)
        #expect(song.markers == [5, 50])
    }

    @Test func oldSongsFileStillLoads() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"T","path":"/a.mp3","duration":10,"sections":[],"prefix":"","addedAt":0}]"#
        let songs = try JSONDecoder().decode([Song].self, from: Data(json.utf8))
        #expect(songs[0].lyrics == "" && songs[0].markers.isEmpty)
    }
}
