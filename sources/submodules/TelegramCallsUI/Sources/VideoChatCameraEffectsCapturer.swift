import Foundation
import UIKit
import AVFoundation
import CoreImage
import Vision
import AppBundle
import TelegramVoip

/// What the Camera sheet lets the user change before (and while) sending video.
public struct VideoChatCameraEffects: Equatable {
    public enum Background: Equatable {
        case original
        case blur
        case studio
        case custom(UIImage)

        public static func ==(lhs: Background, rhs: Background) -> Bool {
            switch lhs {
            case .original:
                if case .original = rhs {
                    return true
                }
                return false
            case .blur:
                if case .blur = rhs {
                    return true
                }
                return false
            case .studio:
                if case .studio = rhs {
                    return true
                }
                return false
            case let .custom(lhsImage):
                if case let .custom(rhsImage) = rhs {
                    return lhsImage === rhsImage
                }
                return false
            }
        }

        public var requiresPremium: Bool {
            if case .custom = self {
                return true
            }
            return false
        }

        /// Person segmentation is the expensive step; it runs only when the background changes.
        public var needsSegmentation: Bool {
            if case .original = self {
                return false
            }
            return true
        }
    }

    public var background: Background
    public var lighting: Bool
    public var touchUp: Bool

    public init(background: Background, lighting: Bool, touchUp: Bool) {
        self.background = background
        self.lighting = lighting
        self.touchUp = touchUp
    }

    public static let off = VideoChatCameraEffects(background: .original, lighting: false, touchUp: false)

    public var isEmpty: Bool {
        return !self.background.needsSegmentation && !self.lighting && !self.touchUp
    }
}

/// Camera source for a video chat that applies `VideoChatCameraEffects` on the device.
///
/// It owns its `AVCaptureSession` and feeds processed frames to a custom
/// `OngoingCallVideoCapturer` (`isCustom: true`) — the same external-buffer path screen sharing
/// uses — so the call engine and the server see an ordinary video stream and need no changes.
///
/// Pipeline per frame: Vision person segmentation (only when a background effect is on) →
/// Core Image (lighting, touch up, background blend) → pooled BGRA buffer → capturer.
/// On the Simulator, which has no camera, frames come from the selfie placeholder instead.
public final class VideoChatCameraEffectsCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let capturer: OngoingCallVideoCapturer

    /// Processed frames for the in-sheet preview; called on the main queue.
    public var previewFrame: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "org.telegram.VideoChatCameraEffects.session")
    private let videoQueue = DispatchQueue(label: "org.telegram.VideoChatCameraEffects.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    private let effectsLock = NSLock()
    private var currentEffects: VideoChatCameraEffects
    private var isFrontCamera = true

    private var outputPool: CVPixelBufferPool?
    private var outputPoolSize: CGSize?

    private var placeholderTimer: DispatchSourceTimer?
    private var placeholderPixelBuffer: CVPixelBuffer?

    public init(effects: VideoChatCameraEffects) {
        self.capturer = OngoingCallVideoCapturer(isCustom: true)
        self.currentEffects = effects

        super.init()
    }

    deinit {
        self.placeholderTimer?.cancel()
    }

    public var effects: VideoChatCameraEffects {
        get {
            self.effectsLock.lock()
            defer {
                self.effectsLock.unlock()
            }
            return self.currentEffects
        }
        set {
            self.effectsLock.lock()
            self.currentEffects = newValue
            self.effectsLock.unlock()
        }
    }

    public func start() {
        #if targetEnvironment(simulator)
        self.startPlaceholderFrames()
        #else
        self.sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            if !self.configureSession(front: self.isFrontCamera) {
                DispatchQueue.main.async { [weak self] in
                    self?.startPlaceholderFrames()
                }
                return
            }
            self.session.startRunning()
        }
        #endif
    }

    public func stop() {
        self.placeholderTimer?.cancel()
        self.placeholderTimer = nil
        self.sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    public func switchCamera() {
        self.sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.isFrontCamera = !self.isFrontCamera
            let _ = self.configureSession(front: self.isFrontCamera)
        }
    }

    private func configureSession(front: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else {
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }

        self.session.beginConfiguration()
        defer {
            self.session.commitConfiguration()
        }

        for existingInput in self.session.inputs {
            self.session.removeInput(existingInput)
        }
        if self.session.canSetSessionPreset(.hd1280x720) {
            self.session.sessionPreset = .hd1280x720
        }
        guard self.session.canAddInput(input) else {
            return false
        }
        self.session.addInput(input)

        if !self.session.outputs.contains(self.videoOutput) {
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            guard self.session.canAddOutput(self.videoOutput) else {
                return false
            }
            self.session.addOutput(self.videoOutput)
        }

        if let connection = self.videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90.0) {
                    connection.videoRotationAngle = 90.0
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // Video is sent unmirrored, as with the regular camera; the preview mirrors itself.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        return true
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        self.process(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func startPlaceholderFrames() {
        guard self.placeholderTimer == nil else {
            return
        }
        guard let image = UIImage(bundleImageName: "Camera/SelfiePlaceholder"), let pixelBuffer = makePixelBuffer(image: image, size: CGSize(width: 720.0, height: 1280.0)) else {
            return
        }
        self.placeholderPixelBuffer = pixelBuffer

        let timer = DispatchSource.makeTimerSource(queue: self.videoQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self, let pixelBuffer = self.placeholderPixelBuffer else {
                return
            }
            self.process(pixelBuffer: pixelBuffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        self.placeholderTimer = timer
        timer.resume()
    }

    private func process(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let effects = self.effects
        let outputPixelBuffer: CVPixelBuffer
        if effects.isEmpty {
            outputPixelBuffer = pixelBuffer
        } else if let processed = self.apply(effects: effects, to: pixelBuffer) {
            outputPixelBuffer = processed
        } else {
            outputPixelBuffer = pixelBuffer
        }

        guard let sampleBuffer = makeVideoSampleBuffer(pixelBuffer: outputPixelBuffer, presentationTime: presentationTime) else {
            return
        }
        self.capturer.injectSampleBuffer(sampleBuffer, rotation: .up, completion: {})

        if self.previewFrame != nil {
            DispatchQueue.main.async { [weak self] in
                self?.previewFrame?(sampleBuffer)
            }
        }
    }

    func apply(effects: VideoChatCameraEffects, to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        var image = source

        if effects.lighting {
            // Lifts shadows on the face and adds a touch of exposure, like a soft key light.
            image = image
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.75, "inputHighlightAmount": 0.95])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.3])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.06, kCIInputContrastKey: 1.02])
        }

        if effects.touchUp {
            // Softens skin texture: a light blur mixed back at 35%, then noise reduction.
            let softened = image.clampedToExtent().applyingGaussianBlur(sigma: 2.2).cropped(to: extent)
            image = softened
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.35)])
                .composited(over: image)
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, "inputSharpness": 0.35])
                .cropped(to: extent)
        }

        if effects.background.needsSegmentation, let mask = self.personMask(pixelBuffer: pixelBuffer, extent: extent) {
            let background: CIImage
            switch effects.background {
            case .original:
                background = image
            case .blur:
                background = image.clampedToExtent().applyingGaussianBlur(sigma: 22.0).cropped(to: extent)
            case .studio:
                background = studioBackground(extent: extent)
            case let .custom(customImage):
                background = aspectFilledImage(customImage, extent: extent) ?? image
            }
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ])
        }

        guard let outputPixelBuffer = self.makeOutputPixelBuffer(size: extent.size) else {
            return nil
        }
        self.ciContext.render(image.cropped(to: extent), to: outputPixelBuffer)
        return outputPixelBuffer
    }

    private func personMask(pixelBuffer: CVPixelBuffer, extent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([self.segmentationRequest])
        } catch {
            return nil
        }
        guard let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer else {
            return nil
        }
        let mask = CIImage(cvPixelBuffer: maskPixelBuffer)
        let scaleX = extent.width / mask.extent.width
        let scaleY = extent.height / mask.extent.height
        // A slightly blurred edge hides the stair-steps of the low-resolution mask.
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: extent)
    }

    private func makeOutputPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if self.outputPoolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attributes as CFDictionary, &pool)
            self.outputPool = pool
            self.outputPoolSize = size
        }
        guard let outputPool = self.outputPool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &pixelBuffer)
        return pixelBuffer
    }
}

/// A soft, evenly lit backdrop — the "Studio" background.
private func studioBackground(extent: CGRect) -> CIImage {
    let center = CIVector(x: extent.midX, y: extent.midY + extent.height * 0.15)
    let gradient = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": center,
        "inputRadius0": extent.width * 0.1,
        "inputRadius1": max(extent.width, extent.height) * 0.85,
        "inputColor0": CIColor(red: 0.42, green: 0.45, blue: 0.53),
        "inputColor1": CIColor(red: 0.12, green: 0.13, blue: 0.17)
    ])?.outputImage
    return (gradient ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.24))).cropped(to: extent)
}

private func aspectFilledImage(_ image: UIImage, extent: CGRect) -> CIImage? {
    guard let ciImage = CIImage(image: image) else {
        return nil
    }
    let scale = max(extent.width / ciImage.extent.width, extent.height / ciImage.extent.height)
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let offsetX = extent.midX - scaled.extent.midX
    let offsetY = extent.midY - scaled.extent.midY
    return scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY)).cropped(to: extent)
}

private func makePixelBuffer(image: UIImage, size: CGSize) -> CVPixelBuffer? {
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ]
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    guard let pixelBuffer, let cgImage = image.cgImage else {
        return nil
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return nil
    }
    let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
    let scale = max(size.width / imageSize.width, size.height / imageSize.height)
    let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    context.draw(cgImage, in: CGRect(origin: CGPoint(x: (size.width - drawSize.width) * 0.5, y: (size.height - drawSize.height) * 0.5), size: drawSize))
    return pixelBuffer
}

private func makeVideoSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
    guard let formatDescription else {
        return nil
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    guard let sampleBuffer else {
        return nil
    }
    // Lets `AVSampleBufferDisplayLayer` show the preview without a timebase.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let attachment = attachments.first {
        attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    return sampleBuffer
}
