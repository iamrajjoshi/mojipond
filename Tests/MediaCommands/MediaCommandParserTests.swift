import XCTest
@testable import MojiPond

final class MediaCommandParserTests: XCTestCase {
    func testRecognizesStickerQueryOnlyInMessages() {
        var parser = MediaCommandParser()

        let action = parser.consume(
            event(text: "/sticker frog", app: "com.apple.MobileSMS")
        )

        XCTAssertEqual(action, .queryChanged(.sticker, "frog"))
        XCTAssertEqual(parser.state, .query(.sticker, "frog"))
    }

    func testRecognizesGIFQueryCaseInsensitively() {
        var parser = MediaCommandParser()

        let action = parser.consume(
            event(text: "/GIF celebration", app: "com.apple.MobileSMS")
        )

        XCTAssertEqual(action, .queryChanged(.gif, "celebration"))
        XCTAssertEqual(parser.state, .query(.gif, "celebration"))
    }

    func testOtherApplicationsCannotActivateAndChangingAppCancels() {
        var parser = MediaCommandParser()
        XCTAssertEqual(
            parser.consume(event(text: "/gif frog", app: "com.apple.TextEdit")),
            .none
        )
        XCTAssertEqual(parser.state, .idle)

        _ = parser.consume(event(text: "/sticker frog", app: "com.apple.MobileSMS"))
        XCTAssertEqual(
            parser.consume(event(text: "x", app: "com.apple.TextEdit", time: 1)),
            .cancelled
        )
        XCTAssertEqual(parser.state, .idle)
    }

    func testRejectsLookalikeCommand() {
        var parser = MediaCommandParser()

        XCTAssertEqual(
            parser.consume(event(text: "/gift frog", app: "com.apple.MobileSMS")),
            .cancelled
        )
        XCTAssertEqual(parser.state, .idle)
    }

    func testQueryIsBoundedForEachCommand() {
        var parser = MediaCommandParser()
        let overlong = String(repeating: "x", count: 51)

        XCTAssertEqual(
            parser.consume(event(text: "/gif \(overlong)", app: "com.apple.MobileSMS")),
            .limitReached(.gif, 50)
        )
        XCTAssertEqual(
            parser.state,
            .query(.gif, String(repeating: "x", count: 50))
        )
    }

    func testBackspaceEscapeModifierAndTimeoutResetState() {
        var parser = MediaCommandParser(inactivityTimeout: 2)
        _ = parser.consume(event(text: "/sticker frog", app: "com.apple.MobileSMS"))
        XCTAssertEqual(
            parser.consume(
                MediaCommandParserEvent(
                    input: .backspace,
                    bundleIdentifier: "com.apple.MobileSMS",
                    timestamp: 1
                )
            ),
            .queryChanged(.sticker, "fro")
        )
        XCTAssertEqual(
            parser.consume(
                MediaCommandParserEvent(
                    input: .escape,
                    bundleIdentifier: "com.apple.MobileSMS",
                    timestamp: 1.5
                )
            ),
            .cancelled
        )

        _ = parser.consume(event(text: "/gif ", app: "com.apple.MobileSMS", time: 2))
        XCTAssertEqual(
            parser.consume(
                MediaCommandParserEvent(
                    input: .text("x"),
                    bundleIdentifier: "com.apple.MobileSMS",
                    timestamp: 2.1,
                    modifiers: .command
                )
            ),
            .cancelled
        )

        _ = parser.consume(event(text: "/", app: "com.apple.MobileSMS", time: 3))
        XCTAssertEqual(
            parser.consume(event(text: "g", app: "com.apple.MobileSMS", time: 6)),
            .none
        )
        XCTAssertEqual(parser.state, .idle)
    }

    private func event(
        text: String,
        app: String,
        time: TimeInterval = 0
    ) -> MediaCommandParserEvent {
        MediaCommandParserEvent(
            input: .text(text),
            bundleIdentifier: app,
            timestamp: time
        )
    }
}
