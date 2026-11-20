import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Quality the host picked for a screen broadcast.
///
/// The app writes it right before the system broadcast picker starts the `BroadcastUpload`
/// extension; the extension reads it once in `broadcastStarted` and applies it to every frame.
/// Both processes share the app group container, so a small JSON file next to the existing
/// `broadcast-coordination` files is enough — no new IPC channel is needed.
public struct ScreencastQualitySettings: Codable, Equatable {
    public enum Resolution: Int32, Codable, CaseIterable {
        case p720 = 720
        case p1080 = 1080
        case p1440 = 1440

        /// Higher-than-default quality is a Telegram Premium perk.
        public var requiresPremium: Bool {
            return self == .p1440
        }

        public var title: String {
            return "\(self.rawValue)p"
        }
    }

    public enum FrameRate: Int32, Codable, CaseIterable {
        case fps15 = 15
        case fps30 = 30
        case fps60 = 60

        public var requiresPremium: Bool {
            return self == .fps60
        }

        public var title: String {
            return "\(self.rawValue) FPS"
        }
    }

    public var resolution: Resolution
    public var frameRate: FrameRate
    public var includesDeviceAudio: Bool

    public init(resolution: Resolution, frameRate: FrameRate, includesDeviceAudio: Bool) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.includesDeviceAudio = includesDeviceAudio
    }

    /// Matches what screen sharing sent before this setting existed.
    public static let `default` = ScreencastQualitySettings(resolution: .p1080, frameRate: .fps30, includesDeviceAudio: true)

    /// Drops Premium-only values for a user without Premium, so a downgraded account can't keep them.
    public func clamped(isPremium: Bool) -> ScreencastQualitySettings {
        var result = self
        if !isPremium {
            if result.resolution.requiresPremium {
                result.resolution = .p1080
            }
            if result.frameRate.requiresPremium {
                result.frameRate = .fps30
            }
        }
        return result
    }

    public var requiresPremium: Bool {
        return self.resolution.requiresPremium || self.frameRate.requiresPremium
    }

    private static func path(basePath: String) -> String {
        return basePath + "/broadcast-quality-settings-v1.json"
    }

    /// `basePath` is `SharedAccountContext.basePath` in the app and the extension's `rootPath`:
    /// both point at `<app group>/telegram-data`.
    public static func load(basePath: String) -> ScreencastQualitySettings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ScreencastQualitySettings.path(basePath: basePath))) else {
            return .default
        }
        guard let value = try? JSONDecoder().decode(ScreencastQualitySettings.self, from: data) else {
            return .default
        }
        return value
    }

    public func store(basePath: String) {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        let _ = try? data.write(to: URL(fileURLWithPath: ScreencastQualitySettings.path(basePath: basePath)), options: .atomic)
    }
}

/// Size of an outgoing frame for a resolution limit: the SHORT side is capped at the limit
/// (a portrait iPhone screen is 1179×2556, so "1080p" means 1080 px wide), the aspect is kept,
/// both sides stay even for the encoder, and a frame is never upscaled.
public func screencastTargetSize(sourceSize: CGSize, resolution: ScreencastQualitySettings.Resolution) -> CGSize {
    let shortSide = min(sourceSize.width, sourceSize.height)
    let limit = CGFloat(resolution.rawValue)
    if shortSide <= limit || shortSide <= 0.0 {
        return sourceSize
    }
    let scale = limit / shortSide
    func even(_ value: CGFloat) -> CGFloat {
        let rounded = Int(value.rounded())
        return CGFloat(rounded - rounded % 2)
    }
    return CGSize(width: even(sourceSize.width * scale), height: even(sourceSize.height * scale))
}

/// Lets through at most `frameRate` frames per second, by presentation time.
///
/// ReplayKit delivers frames only when the screen changes, so the gate keeps a running
/// "next allowed" time instead of counting frames: a still screen costs nothing, a busy one
/// is capped. A small tolerance keeps a 60 Hz source from beating against a 30 FPS cap.
public struct ScreencastFrameRateGate {
    private let minimumInterval: Double
    private var nextAllowedTimestamp: Double?

    public init(frameRate: ScreencastQualitySettings.FrameRate) {
        self.minimumInterval = 1.0 / Double(frameRate.rawValue)
    }

    public mutating func shouldPass(timestamp: Double) -> Bool {
        if let nextAllowedTimestamp = self.nextAllowedTimestamp, timestamp + self.minimumInterval * 0.3 < nextAllowedTimestamp {
            return false
        }
        if let nextAllowedTimestamp = self.nextAllowedTimestamp, timestamp - nextAllowedTimestamp < self.minimumInterval {
            // Steady stream: advance on the grid so the average rate doesn't drift down with jitter.
            self.nextAllowedTimestamp = nextAllowedTimestamp + self.minimumInterval
        } else {
            // First frame or the screen was still for a while: restart the grid from this frame.
            self.nextAllowedTimestamp = timestamp + self.minimumInterval
        }
        return true
    }
}

/// Applies `ScreencastQualitySettings` to ReplayKit frames inside the broadcast extension.
public final class ScreencastFrameProcessor {
    public let settings: ScreencastQualitySettings
    private var gate: ScreencastFrameRateGate
    /// `ScreencastFrameScaler` on iOS 16+; frames are sent at source size on iOS 15.
    private var scaler: AnyObject?

    public init(settings: ScreencastQualitySettings) {
        self.settings = settings
        self.gate = ScreencastFrameRateGate(frameRate: settings.frameRate)
    }

    /// Returns the frame to send, or `nil` to drop it.
    public func process(sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if timestamp.isFinite {
            if !self.gate.shouldPass(timestamp: timestamp) {
                return nil
            }
        }
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return sampleBuffer
        }
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(sourcePixelBuffer), height: CVPixelBufferGetHeight(sourcePixelBuffer))
        let targetSize = screencastTargetSize(sourceSize: sourceSize, resolution: self.settings.resolution)
        if targetSize == sourceSize {
            return sampleBuffer
        }
        guard #available(iOS 16.0, *) else {
            return sampleBuffer
        }
        let scaler: ScreencastFrameScaler
        if let current = self.scaler as? ScreencastFrameScaler {
            scaler = current
        } else {
            scaler = ScreencastFrameScaler()
            self.scaler = scaler
        }
        guard let scaledPixelBuffer = scaler.scale(pixelBuffer: sourcePixelBuffer, to: targetSize) else {
            return sampleBuffer
        }
        return makeSampleBuffer(pixelBuffer: scaledPixelBuffer, copyingTimingAndAttachmentsFrom: sampleBuffer) ?? sampleBuffer
    }
}

/// The broadcast extension runs under a hard 50 MB memory limit, so scaling goes through a single
/// `VTPixelTransferSession` and a small `CVPixelBufferPool` sized for the target frame:
/// no Core Image context, no intermediate copies.
@available(iOS 16.0, *)
private final class ScreencastFrameScaler {
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolFormat: OSType = 0

    init() {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
        self.transferSession = session
    }

    deinit {
        if let transferSession = self.transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
    }

    func scale(pixelBuffer: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if self.pool == nil || self.poolWidth != width || self.poolHeight != height || self.poolFormat != format {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
            self.pool = pool
            self.poolWidth = width
            self.poolHeight = height
            self.poolFormat = format
        }

        guard let pool = self.pool, let transferSession = self.transferSession else {
            return nil
        }
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard let outputPixelBuffer else {
            return nil
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: pixelBuffer, to: outputPixelBuffer)
        if status != noErr {
            return nil
        }
        return outputPixelBuffer
    }
}

private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, copyingTimingAndAttachmentsFrom source: CMSampleBuffer) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
    guard let formatDescription else {
        return nil
    }
    var timing = CMSampleTimingInfo(
        duration: CMSampleBufferGetDuration(source),
        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source)
    )
    var result: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &result)
    guard let result else {
        return nil
    }
    // ReplayKit puts the screen orientation on the sample buffer (RPVideoSampleOrientationKey);
    // the extension reads it from there, so it has to survive the scaling.
    CMPropagateAttachments(source, destination: result)
    return result
}
