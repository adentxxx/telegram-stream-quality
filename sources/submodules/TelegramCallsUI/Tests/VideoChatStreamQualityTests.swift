import Foundation
import UIKit
import XCTest
import TelegramVoip
@testable import TelegramCallsUI

/// Pins the Share Screen quality rules: what each resolution sends, how the frame-rate cap
/// behaves on a ReplayKit-like stream, and which options are Premium-only.
final class VideoChatStreamQualityTests: XCTestCase {
    func testPortraitPhoneScreenIsCappedOnTheShortSide() {
        let iPhoneScreen = CGSize(width: 1179.0, height: 2556.0)
        XCTAssertEqual(screencastTargetSize(sourceSize: iPhoneScreen, resolution: .p720), CGSize(width: 720.0, height: 1560.0))
        XCTAssertEqual(screencastTargetSize(sourceSize: iPhoneScreen, resolution: .p1080), CGSize(width: 1080.0, height: 2340.0))
    }

    func testLandscapeIsCappedOnTheShortSideToo() {
        let landscape = CGSize(width: 2556.0, height: 1179.0)
        XCTAssertEqual(screencastTargetSize(sourceSize: landscape, resolution: .p720), CGSize(width: 1560.0, height: 720.0))
    }

    func testSmallerSourceIsNeverUpscaled() {
        let source = CGSize(width: 1179.0, height: 2556.0)
        XCTAssertEqual(screencastTargetSize(sourceSize: source, resolution: .p1440), source)
    }

    func testTargetSidesAreEven() {
        let size = screencastTargetSize(sourceSize: CGSize(width: 1125.0, height: 2437.0), resolution: .p720)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
    }

    func testSixtyHertzStreamIsHalvedAtThirtyFPS() {
        var gate = ScreencastFrameRateGate(frameRate: .fps30)
        var passed = 0
        for i in 0 ..< 120 {
            if gate.shouldPass(timestamp: Double(i) / 60.0) {
                passed += 1
            }
        }
        XCTAssertEqual(passed, 60)
    }

    func testFifteenFPSKeepsAQuarterOfASixtyHertzStream() {
        var gate = ScreencastFrameRateGate(frameRate: .fps15)
        var passed = 0
        for i in 0 ..< 240 {
            if gate.shouldPass(timestamp: Double(i) / 60.0) {
                passed += 1
            }
        }
        // 4 seconds at 15 FPS, give or take the first frame.
        XCTAssertTrue((59 ... 61).contains(passed), "\(passed)")
    }

    func testFirstFrameAfterAStillScreenIsSentRightAway() {
        var gate = ScreencastFrameRateGate(frameRate: .fps30)
        XCTAssertTrue(gate.shouldPass(timestamp: 0.0))
        XCTAssertTrue(gate.shouldPass(timestamp: 5.0))
        XCTAssertFalse(gate.shouldPass(timestamp: 5.01))
    }

    func testPremiumValuesAreDroppedWithoutPremium() {
        let premium = ScreencastQualitySettings(resolution: .p1440, frameRate: .fps60, includesDeviceAudio: false)
        let clamped = premium.clamped(isPremium: false)
        XCTAssertEqual(clamped.resolution, .p1080)
        XCTAssertEqual(clamped.frameRate, .fps30)
        XCTAssertFalse(clamped.includesDeviceAudio)
        XCTAssertEqual(premium.clamped(isPremium: true), premium)
    }

    func testOptionsLockPremiumValuesOnlyForNonPremiumUsers() {
        let settings = ScreencastQualitySettings.default
        let free = videoChatShareScreenResolutionOptions(settings: settings, isPremium: false)
        XCTAssertEqual(free.map(\.title), ["720p", "1080p", "1440p"])
        XCTAssertEqual(free.map(\.isLocked), [false, false, true])
        XCTAssertEqual(free.map(\.isSelected), [false, true, false])

        let premium = videoChatShareScreenFrameRateOptions(settings: settings, isPremium: true)
        XCTAssertEqual(premium.map(\.isLocked), [false, false, false])
        XCTAssertEqual(premium.map(\.title), ["15 FPS", "30 FPS", "60 FPS"])
    }

    func testSettingsRoundTripThroughTheSharedContainer() throws {
        let directory = NSTemporaryDirectory() + "screencast-quality-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        XCTAssertEqual(ScreencastQualitySettings.load(basePath: directory), .default)

        let settings = ScreencastQualitySettings(resolution: .p720, frameRate: .fps15, includesDeviceAudio: false)
        settings.store(basePath: directory)
        XCTAssertEqual(ScreencastQualitySettings.load(basePath: directory), settings)
    }

    func testCameraEffectsKnowWhenSegmentationIsNeeded() {
        XCTAssertTrue(VideoChatCameraEffects.off.isEmpty)
        XCTAssertFalse(VideoChatCameraEffects(background: .original, lighting: true, touchUp: false).isEmpty)
        XCTAssertFalse(VideoChatCameraEffects.Background.original.needsSegmentation)
        XCTAssertTrue(VideoChatCameraEffects.Background.blur.needsSegmentation)
        XCTAssertTrue(VideoChatCameraEffects.Background.custom(UIImage()).requiresPremium)
        XCTAssertFalse(VideoChatCameraEffects.Background.studio.requiresPremium)
    }
}
