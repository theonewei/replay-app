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
}
