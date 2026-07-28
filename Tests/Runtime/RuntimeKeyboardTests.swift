import CoreGraphics
import XCTest
@testable import MojiPond

final class RuntimeKeyboardTests: XCTestCase {
    func testMapperProducesParserInputsWithoutTouchingTheOS() {
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: 0,
                    flags: [.maskShift],
                    characters: "F"
                )
            ),
            .character("F", modifiers: [.shift])
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.delete,
                    flags: [.maskAlternate]
                )
            ),
            .backspace(modifiers: [.option])
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.leftArrow
                )
            ),
            .reset(.cursorMoved)
        )
        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(
                for: snapshot(keyCode: 0)
            ),
            .reset(.deadKeyOrIME)
        )
    }

    func testMouseClickMapsToAnAggressiveReset() {
        let event = KeyboardEventSnapshot(
            typeRawValue: CGEventType.leftMouseDown.rawValue,
            keyCode: 0,
            flagsRawValue: 0,
            timestamp: 1,
            characters: nil
        )

        XCTAssertEqual(
            RuntimeKeyboardEventMapper.action(for: event),
            .reset(.mouseClick)
        )
    }

    func testGateOnlyOwnsVisibleUnmodifiedNavigation() {
        let gate = RuntimeInterceptionGate()
        let down = snapshot(
            keyCode: RuntimeKeyboardKeyCode.downArrow
        )

        XCTAssertEqual(gate.decision(for: down), .passThrough)
        gate.setCaptureEnabled(true)
        gate.setMode(
            .suggestions,
            acceptsTab: true,
            acceptsReturn: false
        )

        XCTAssertEqual(gate.decision(for: down), .intercept)
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.returnKey)
            ),
            .passThrough
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.downArrow,
                    flags: [.maskCommand]
                )
            ),
            .passThrough
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 0, characters: "a")
            ),
            .passThrough
        )
    }

    func testBrowserOwnsAcceptanceEvenWhenAutocompleteAcceptanceIsDisabled() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)
        gate.setMode(
            .browser,
            acceptsTab: false,
            acceptsReturn: false
        )

        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.tab)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.keypadEnter)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 3, characters: "f")
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.delete)
            ),
            .intercept
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: 49, characters: " ")
            ),
            .passThrough
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: 3,
                    flags: [.maskCommand],
                    characters: "f"
                )
            ),
            .passThrough
        )
    }

    func testMediaGridOwnsHorizontalAndVerticalNavigationOnlyWhileVisible() {
        let gate = RuntimeInterceptionGate()
        gate.setCaptureEnabled(true)

        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.leftArrow)
            ),
            .passThrough
        )

        gate.setMode(
            .media,
            acceptsTab: true,
            acceptsReturn: true
        )
        for keyCode in [
            RuntimeKeyboardKeyCode.leftArrow,
            RuntimeKeyboardKeyCode.rightArrow,
            RuntimeKeyboardKeyCode.upArrow,
            RuntimeKeyboardKeyCode.downArrow,
            RuntimeKeyboardKeyCode.tab,
            RuntimeKeyboardKeyCode.returnKey,
            RuntimeKeyboardKeyCode.escape
        ] {
            XCTAssertEqual(
                gate.decision(for: snapshot(keyCode: keyCode)),
                .intercept
            )
        }
        XCTAssertEqual(
            gate.decision(
                for: snapshot(
                    keyCode: RuntimeKeyboardKeyCode.rightArrow,
                    flags: [.maskCommand]
                )
            ),
            .passThrough
        )

        gate.setMode(
            .hidden,
            acceptsTab: true,
            acceptsReturn: true
        )
        XCTAssertEqual(
            gate.decision(
                for: snapshot(keyCode: RuntimeKeyboardKeyCode.rightArrow)
            ),
            .passThrough
        )
    }

    private func snapshot(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        characters: String? = nil
    ) -> KeyboardEventSnapshot {
        KeyboardEventSnapshot(
            typeRawValue: CGEventType.keyDown.rawValue,
            keyCode: keyCode,
            flagsRawValue: flags.rawValue,
            timestamp: 1,
            characters: characters
        )
    }
}
