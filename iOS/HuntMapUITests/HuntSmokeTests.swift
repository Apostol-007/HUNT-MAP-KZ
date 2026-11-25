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
