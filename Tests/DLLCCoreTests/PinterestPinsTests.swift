import Foundation
import Testing
@testable import DLLCCore

struct PinterestPinsTests {
    func fixture() throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: "pinterest-carousel", withExtension: "json", subdirectory: "Fixtures")!)
    }

    @Test func pinIDsFromLinks() {
        #expect(PinterestPins.pinID(from: URL(string: "https://www.pinterest.com/pin/750904937913106472/")!) == "750904937913106472")
        #expect(PinterestPins.pinID(from: URL(string: "https://th.pinterest.com/pin/cute-cat--12345/")!) == "12345")
        #expect(PinterestPins.pinID(from: URL(string: "https://www.pinterest.com/someone/board/")!) == nil)
        #expect(PinterestPins.isPinterest("https://th.pinterest.com/pin/1/"))
        #expect(PinterestPins.isPinterest("https://pin.it/abc"))
        #expect(!PinterestPins.isPinterest("https://notpinterest.com/pin/1/"))
    }

    @Test func carouselKeepsVideosAndOriginalImages() throws {
        let p = try PinterestPins.parse(fixture(), id: "111")
        #expect(p.items.count == 2)                       // the slot on a foreign / insecure host is dropped
        #expect(p.items[0].isVideo && p.items[0].url.hasSuffix("one_720w.mp4"))
        #expect(!p.items[1].isVideo)
        #expect(p.items[1].url == "https://i.pinimg.com/originals/44/55/66/two.jpg")
        #expect(p.items[1].fallbackURL == "https://i.pinimg.com/736x/44/55/66/two.jpg")
        #expect(p.title == "Moodboard ideas")
        #expect(p.creator == "Sample Creator")
        #expect(PinterestPins.summary(p.items) == "1 image · 1 video")
    }

    @Test func singleImagePinUsesTheOriginal() throws {
        let json = #"{"resource_response":{"data":{"images":{"orig":{"url":"https://i.pinimg.com/originals/9/9/9/a.png","width":800,"height":600},"736x":{"url":"https://i.pinimg.com/736x/9/9/9/a.png"}}}}}"#
        let p = try PinterestPins.parse(Data(json.utf8), id: "5")
        #expect(p.items == [DirectItem(url: "https://i.pinimg.com/originals/9/9/9/a.png", fallbackURL: "https://i.pinimg.com/736x/9/9/9/a.png",
                                       isVideo: false, width: 800, height: 600)])
        #expect(p.items[0].fileExtension == "png")
        #expect(p.title == "Pinterest pin 5")
    }
}
