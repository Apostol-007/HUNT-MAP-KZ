import XCTest

final class HuntSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Открыть приложение без ожидания"]
        let home = app.buttons["tab_Главная"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !home.isHittable {
            if skip.exists && skip.isHittable { skip.tap() }
            else { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Main navigation missing")
        XCTAssertTrue(home.isHittable, "Startup gate blocks navigation")
        return app
    }

    func testFieldAndEmergencyScreens() throws {
        let app = openApp()
        app.buttons["tab_Главная"].tap()
        let field = app.buttons["field_mode_home"]
        for _ in 0..<4 {
            if field.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(field.isHittable)
        field.tap()
        XCTAssertTrue(app.buttons["field_close"].waitForExistence(timeout: 15))
        capture("07-field-mode", app: app)
        let backtrack = app.buttons["field_return"]
        for _ in 0..<4 {
            if backtrack.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(backtrack.exists)
        XCTAssertFalse(backtrack.isEnabled, "Empty recording must not start backtracking")
        let sos = app.buttons["field_sos"]
        for _ in 0..<5 {
            if sos.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(sos.isHittable)
        sos.tap()
        XCTAssertTrue(app.buttons["sos_call"].waitForExistence(timeout: 15))
        capture("08-emergency", app: app)
        app.buttons["sos_close"].tap()
        app.buttons["field_close"].tap()
        XCTAssertTrue(app.buttons["tab_Главная"].waitForExistence(timeout: 10))
    }

    func testLaunchAndPrimaryNavigation() throws {
        let app = openApp()
        let tabs = [("Главная", "01-home"), ("Карта", "02-map"),
                    ("Данные", "03-data"), ("Сервисы", "04-services"),
                    ("Ещё", "05-more")]
        for (title, screenshot) in tabs {
            let tab = app.buttons["tab_" + title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), title)
            XCTAssertTrue(tab.isHittable, title)
            tab.tap()
            XCTAssertEqual(app.state, .runningForeground)
            capture(screenshot, app: app)
        }
        app.buttons["tab_Главная"].tap()
        let grounds = app.buttons["grounds_home"]
        XCTAssertTrue(grounds.waitForExistence(timeout: 10))
        grounds.tap()
        XCTAssertEqual(app.state, .runningForeground)
        capture("06-grounds", app: app)
    }
}
