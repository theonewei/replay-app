import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchShowsPracticeControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.segmentedControls["practice.mode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Audio"].exists)
        XCTAssertTrue(app.buttons["Video"].exists)
        XCTAssertTrue(app.buttons["practice.record"].exists)
        XCTAssertEqual(app.buttons["practice.record"].label, "Record new take")
        XCTAssertTrue(app.buttons["practice.save"].exists)
        XCTAssertFalse(app.buttons["practice.save"].isEnabled)
    }

    func testTimelineAndLoopDefault() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-audio", "--preview-paused"]
        app.launch()
        let play = app.buttons["playback.playPause"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play' AND enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        XCTAssertEqual(play.label, "Play")
        let loop = app.switches["playback.loop"]
        XCTAssertEqual(loop.value as? String, "0")
        loop.tap()
        XCTAssertEqual(loop.value as? String, "1")
        loop.tap()
        XCTAssertEqual(loop.value as? String, "0")
        let timeline = app.sliders["playback.timeline"]
        XCTAssertTrue(timeline.exists)
        timeline.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertEqual(play.label, "Play")
        XCTAssertNotEqual(app.staticTexts["playback.elapsed"].label, "0:00")
        XCTAssertEqual(app.staticTexts["playback.duration"].label, "0:12")
        timeline.adjust(toNormalizedSliderPosition: 0.95)
        play.tap()
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == '0:12'"), object: app.staticTexts["playback.elapsed"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 5), .completed)
        XCTAssertEqual(play.label, "Play")
    }

    func testRecordingSaveCancellationAndFailedReplacement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture", "--fail-second-start"]
        app.launch()
        let record = app.buttons["practice.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Stop and replay'"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
        record.tap()
        let play = app.buttons["playback.playPause"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        if play.label == "Pause" { play.tap() }
        app.sliders["playback.timeline"].adjust(toNormalizedSliderPosition: 0.4)
        app.buttons["practice.save"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        if !cancel.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let saveReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["practice.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saveReady], timeout: 5), .completed)
        XCTAssertEqual(play.label, "Play")
        record.tap()
        XCTAssertTrue(app.alerts["Replay"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.sliders["playback.timeline"].exists)
        XCTAssertEqual(app.staticTexts["playback.duration"].label, "0:12")
        XCTAssertTrue(app.buttons["practice.save"].isEnabled)
    }

    func testRecordingCanSaveThroughFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture"]
        app.launch()
        let record = app.buttons["practice.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Stop and replay'"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
        record.tap()
        let save = app.buttons["practice.save"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        save.tap()
        let filesSave = app.navigationBars.buttons["Save"].firstMatch
        XCTAssertTrue(filesSave.waitForExistence(timeout: 10))
        filesSave.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Saved'"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.sliders["playback.timeline"].exists)
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Play")
    }
}
