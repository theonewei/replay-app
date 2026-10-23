import XCTest

final class LaunchTests: XCTestCase {
    func testLiveAudioWaveformStopsResetsAndHandlesBackground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture", "--fixture-waveform"]
        app.launch()
        let record = app.buttons["practice.record"]
        record.tap()
        let waveform = app.descendants(matching: .any).matching(identifier: "audio.waveform").firstMatch
        XCTAssertTrue(waveform.waitForExistence(timeout: 5))
        let sound = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Input level'"), object: waveform)
        XCTAssertEqual(XCTWaiter.wait(for: [sound], timeout: 5), .completed)
        record.tap()
        XCTAssertFalse(waveform.exists)
        let clear = app.buttons["practice.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        let clearReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [clearReady], timeout: 10), .completed)
        clear.tap()
        let recordReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [recordReady], timeout: 5), .completed)
        record.tap()
        let nextWaveform = app.descendants(matching: .any).matching(identifier: "audio.waveform").firstMatch
        XCTAssertTrue(nextWaveform.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertFalse(nextWaveform.exists)
        XCTAssertEqual(record.label, "Record new take")
    }

    func testClearAudioAndFullscreenVideoReturnsToReady() {
        continueAfterFailure = false
        for video in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--fixture-capture", video ? "--preview-video" : "--preview-audio"]
            app.launch()
            let clear = app.buttons[video ? "video.clear" : "practice.clear"]
            XCTAssertTrue(clear.waitForExistence(timeout: 15))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            clear.tap()
            let record = app.buttons["practice.record"]
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            XCTAssertTrue(record.isEnabled)
            XCTAssertEqual(record.label, "Record new take")
            XCTAssertFalse(app.sliders["playback.timeline"].exists)
            XCTAssertFalse(app.buttons["practice.save"].isEnabled)
            XCTAssertFalse(app.buttons["video.done"].exists)
            app.terminate()
        }
    }

    func testFrameRateSettingsPersistAcrossLaunches() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture"]
        app.launch()
        app.buttons["practice.settings"].tap()
        app.buttons["settings.frameRate"].tap()
        app.buttons["30 fps"].tap()
        app.terminate()
        app.launch()
        app.buttons["practice.settings"].tap()
        XCTAssertEqual(app.buttons["settings.frameRate"].value as? String, "30 fps")
        app.buttons["settings.frameRate"].tap()
        app.buttons["60 fps"].tap()
        app.terminate()
        app.launch()
        app.buttons["practice.settings"].tap()
        XCTAssertEqual(app.buttons["settings.frameRate"].value as? String, "60 fps")
        app.buttons["settings.done"].tap()
    }

    func testDelayedClipCanReviewSaveAndDiscard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture", "--fixture-stream", "--fast-stream"]
        app.launch()
        app.buttons["Video"].tap()
        app.buttons["Delayed stream"].tap()
        app.buttons["stream.startStop"].tap()
        let clip = app.buttons["stream.clip"]
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clip)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 20), .completed)
        XCTAssertEqual(clip.label, "Clip last 15 seconds viewed")
        clip.tap()
        let done = app.buttons["video.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["playback.duration"].label, "0:15")
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Play")
        app.sliders["playback.timeline"].adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertNotEqual(app.staticTexts["playback.elapsed"].label, "0:00")
        let save = app.buttons["video.save"]
        save.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Saved'"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Play")
        app.buttons["stream.discardClip"].tap()
        let start = app.buttons["stream.startStop"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Start stream")
        XCTAssertFalse(app.sliders["playback.timeline"].exists)
    }

    func testFullscreenVideoPreservesPlaybackAndRotates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview-video", "--preview-paused"]
        app.launch()
        let done = app.buttons["video.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Play")
        XCTAssertEqual(app.switches["playback.loop"].value as? String, "0")
        app.sliders["playback.timeline"].adjust(toNormalizedSliderPosition: 0.5)
        let elapsed = app.staticTexts["playback.elapsed"].label
        app.switches["playback.loop"].tap()
        done.tap()
        let fullscreen = app.buttons["video.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playback.elapsed"].label, elapsed)
        fullscreen.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["playback.loop"].value as? String, "1")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(done.isHittable)
        XCTAssertTrue(app.buttons["playback.playPause"].isHittable)
        XCTAssertEqual(app.staticTexts["playback.elapsed"].label, elapsed)
        done.tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertTrue(fullscreen.isHittable)
        fullscreen.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        app.buttons["playback.playPause"].tap()
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Pause")
        done.tap()
        XCTAssertEqual(app.buttons["playback.playPause"].label, "Pause")
    }

    func testDelayedVideoBuffersStopsAndRestarts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-capture", "--fixture-stream", "--fast-stream"]
        app.launch()
        app.buttons["Video"].tap()
        app.buttons["Delayed stream"].tap()
        let startStop = app.buttons["stream.startStop"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Delay: 15 seconds"].exists)
        let preview = app.staticTexts["stream.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(startStop.label, "Start stream")
        XCTAssertTrue(app.steppers["stream.delay"].isEnabled)
        XCTAssertFalse(app.buttons["stream.clip"].exists)
        startStop.tap()
        XCTAssertTrue(app.staticTexts["stream.viewfinder"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["stream.clip"].isEnabled)
        let status = app.staticTexts["stream.status"]
        let streaming = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Streaming'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [streaming], timeout: 10), .completed)
        XCTAssertFalse(app.steppers["stream.delay"].isEnabled)
        XCTAssertFalse(app.buttons["Audio"].isEnabled)
        startStop.tap()
        XCTAssertEqual(startStop.label, "Start stream")
        XCTAssertTrue(app.steppers["stream.delay"].isEnabled)
        XCTAssertFalse(app.images["Delayed camera video"].exists)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        startStop.tap()
        XCTAssertTrue(status.label.contains("Starting") || status.label.contains("Buffering"))
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Streaming'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 10), .completed)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(startStop.label, "Start stream")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.buttons["Audio"].tap()
        XCTAssertFalse(preview.exists)
    }

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
        print("End seek landed at \(app.staticTexts["playback.elapsed"].label)")
        play.tap()
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == '0:12'"), object: app.staticTexts["playback.elapsed"]
        )
        let endResult = XCTWaiter.wait(for: [ended], timeout: 5)
        if endResult != .completed {
            print("End check: elapsed=\(app.staticTexts["playback.elapsed"].label), control=\(play.label), status=\(app.staticTexts["practice.status"].label)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(endResult, .completed)
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
            app.navigationBars.buttons.matching(NSPredicate(format: "identifier != 'practice.settings'")).firstMatch.tap()
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
