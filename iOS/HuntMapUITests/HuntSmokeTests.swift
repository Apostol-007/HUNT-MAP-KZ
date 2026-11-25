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
        let skip = app.buttons["startup_skip"]
        let home = app.buttons["tab_Главная"]
        let deadline = Date().addingTimeInterval(90)
        var ready = false
        while Date() < deadline {
            // A visible startup gate always takes precedence over underlying controls.
            if skip.exists {
                if skip.isHittable { skip.tap() }
            } else if home.exists && home.isHittable && home.isEnabled {
                ready = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(ready, "Startup gate did not release navigation")
        XCTAssertFalse(skip.exists, "Startup screen still covers the application")
        XCTAssertTrue(home.isHittable && home.isEnabled)
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
        XCTAssertFalse(app.buttons["startup_skip"].exists, "Startup gate reappeared")
        XCTAssertTrue(field.isEnabled, "Field entry disabled")
        field.tap()
        let ready = app.staticTexts["field_screen_ready"]
        if !ready.waitForExistence(timeout: 15) {
            capture("failure-field-open", app: app)
            XCTFail("Field screen did not open: " + app.debugDescription)
            return
        }
        XCTAssertTrue(app.buttons["field_close"].waitForExistence(timeout: 10), "Field close control missing")
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
        XCTAssertTrue(app.staticTexts["sos_screen_ready"].waitForExistence(timeout: 15), "SOS screen did not open")
        XCTAssertTrue(app.buttons["sos_call"].waitForExistence(timeout: 15))
        capture("08-emergency", app: app)
        app.buttons["sos_close"].tap()
        app.buttons["field_close"].tap()
        XCTAssertTrue(app.buttons["tab_Главная"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["field_screen_ready"].exists, "Field overlay did not close")
        let directSOS = app.buttons["sos_home"]
        XCTAssertTrue(directSOS.waitForExistence(timeout: 10))
        directSOS.tap()
        XCTAssertTrue(app.staticTexts["sos_screen_ready"].waitForExistence(timeout: 15), "Direct SOS entry did not open")
        app.buttons["sos_close"].tap()
    }

    func testAstronomyNavigation() throws {
        let app = openApp()
        app.buttons["tab_Сервисы"].tap()
        let astronomy = app.buttons["service_astronomy"]
        XCTAssertTrue(astronomy.waitForExistence(timeout: 15))
        astronomy.tap()
        XCTAssertTrue(app.staticTexts["astronomy_ready"].waitForExistence(timeout: 15))
        capture("09-astronomy", app: app)
    }

    func testObservationJournalNavigation() throws {
        let app = openApp()
        app.buttons["tab_Сервисы"].tap()
        let wildlife = app.buttons["service_wildlife"]
        XCTAssertTrue(wildlife.waitForExistence(timeout: 15))
        wildlife.tap()
        let journal = app.buttons["wildlife_Дневник"]
        XCTAssertTrue(journal.waitForExistence(timeout: 10))
        journal.tap()
        let add = app.buttons["observation_add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        capture("10-observation-journal", app: app)
        add.tap()
        XCTAssertTrue(app.textFields["observation_species"].waitForExistence(timeout: 15))
        capture("11-observation-editor", app: app)
        app.buttons["observation_cancel"].tap()
    }

    func testObservationPersistence() throws {
        var app = openApp()
        let species = "CI-" + UUID().uuidString.prefix(8)
        func openJournal(_ app: XCUIApplication) {
            app.buttons["tab_Сервисы"].tap()
            let wildlife = app.buttons["service_wildlife"]
            XCTAssertTrue(wildlife.waitForExistence(timeout: 15))
            wildlife.tap()
            let journal = app.buttons["wildlife_Дневник"]
            XCTAssertTrue(journal.waitForExistence(timeout: 10))
            journal.tap()
        }
        openJournal(app)
        app.buttons["observation_add"].tap()
        let name=app.textFields["observation_species"]
        XCTAssertTrue(name.waitForExistence(timeout:15))
        name.tap();name.typeText(species)
        app.buttons["observation_save"].tap()
        let id="observation_record_"+species
        XCTAssertTrue(app.staticTexts[id].waitForExistence(timeout:15))
        app.terminate()
        app=openApp()
        openJournal(app)
        XCTAssertTrue(app.staticTexts[id].waitForExistence(timeout:15),"Saved observation missing after relaunch")
        capture("14-observation-persisted",app:app)
    }

    func testSettingsNavigation() throws {
        let app = openApp()
        app.buttons["tab_Ещё"].tap()
        let settings = app.buttons["settings_open"]
        for _ in 0..<4 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 15))
        capture("12-settings", app: app)
        let backup = app.buttons["backup_create"]
        for _ in 0..<6 { if backup.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(backup.isHittable)
        backup.tap()
        let share = app.buttons["backup_share"]
        for _ in 0..<5 { if share.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(share.exists, "Backup creation did not expose a shareable file")
        capture("13-backup", app: app)
    }

    func testOfflineManagerRepeatedOpen() throws {
        let app = openApp()
        app.buttons["tab_Ещё"].tap()
        let entry = app.buttons["offline_manager_open"]
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        for iteration in 0..<3 {
            entry.tap()
            XCTAssertTrue(app.staticTexts["offline_manager_ready"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["offline_manager_close"].isHittable)
            if iteration == 0 { capture("16-offline-manager", app: app) }
            app.buttons["offline_manager_close"].tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
        }
    }

    func testIconSettingsNavigation() throws {
        let app = openApp()
        app.buttons["tab_Ещё"].tap()
        let entry = app.buttons["icon_settings_open"]
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Значок приложения"].waitForExistence(timeout:15))
        capture("15-icon-settings", app:app)
    }

    func testRepeatedColdLaunch() throws {
        for iteration in 0..<3 {
            let app = openApp()
            XCTAssertEqual(app.state, .runningForeground)
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertEqual(app.state, .runningForeground, "Cold launch crashed")
            capture("cold-launch-\(iteration)", app: app)
            app.terminate()
        }
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
