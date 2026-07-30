import XCTest

@MainActor
final class IntegrationFixtureUITests: XCTestCase {
    func testOrdinaryAndSecureTextTargets() {
        continueAfterFailure = false
        let application = launchApplication()
        defer {
            application.terminate()
        }

        let plainTextField = application.textFields[
            "fixture.plainTextField"
        ]
        let plainTextFieldExists = plainTextField.waitForExistence(timeout: 5)
        XCTAssertTrue(plainTextFieldExists)
        XCTAssertTrue(
            application.textViews[
                "fixture.multiLineTextView"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            application.textViews[
                "fixture.richTextView.native"
            ].waitForExistence(timeout: 5)
        )
        let secureTextField = application.secureTextFields[
            "fixture.secureTextField"
        ]
        XCTAssertTrue(
            secureTextField.waitForExistence(timeout: 5)
        )
        attachScreen(
            named: "integration-fixture",
            element: application.windows.firstMatch
        )

        plainTextField.click()
        plainTextField.typeText("ordinary :wave:")
        let plainTextValue = plainTextField.value as? String
        XCTAssertEqual(
            plainTextValue,
            "ordinary :wave:"
        )

        let secureTextFieldExists = secureTextField.exists
        XCTAssertTrue(secureTextFieldExists)
        let initialSecureTextValue = secureTextField.value as? String
        secureTextField.click()
        secureTextField.typeText("private")
        let secureTextValue = secureTextField.value as? String
        XCTAssertFalse(
            secureTextValue?.isEmpty ?? true
        )
        XCTAssertNotEqual(secureTextValue, initialSecureTextValue)
    }

    func testMultilineAndAttachmentCapableTextTargets() {
        continueAfterFailure = false
        let application = launchApplication()
        defer {
            application.terminate()
        }

        let multilineTextView = application.textViews[
            "fixture.multiLineTextView"
        ]
        let multilineExists = multilineTextView.waitForExistence(timeout: 5)
        XCTAssertTrue(multilineExists)
        replaceText(in: multilineTextView, with: "Line one\n:wave:")
        let multilineValue = multilineTextView.value as? String
        XCTAssertEqual(
            multilineValue,
            "Line one\n:wave:"
        )

        let richTextView = application.textViews[
            "fixture.richTextView.native"
        ]
        let richTextViewExists = richTextView.exists
        XCTAssertTrue(richTextViewExists)
        replaceText(
            in: richTextView,
            with: "Attachment-capable :party_parrot:"
        )
        let richTextValue = richTextView.value as? String
        XCTAssertEqual(
            richTextValue,
            "Attachment-capable :party_parrot:"
        )
    }

    private func launchApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppleInterfaceStyle",
            "Light",
            "-AppleInterfaceStyleSwitchesAutomatically",
            "false",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        application.launch()
        return application
    }

    private func attachScreen(
        named name: String,
        element: XCUIElement
    ) {
        let attachment = XCTAttachment(
            screenshot: element.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replaceText(
        in element: XCUIElement,
        with replacement: String
    ) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(replacement)
    }
}
