import AVFoundation
import CoreMedia
import Foundation

enum CameraAuthorization: Equatable {
    case authorized
    case denied
    case unavailable
}

final class CameraController: NSObject {
    var sampleIntervalProvider: () -> TimeInterval = { 1.5 }
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAuthorizationChange: ((CameraAuthorization) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.sloucher.camera.session")
    private let videoQueue = DispatchQueue(label: "app.sloucher.camera.video", qos: .utility)

    private var videoOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false
    private var shouldRun = false
    private var lastFrameTime: CFTimeInterval = 0
    private var shouldForceNextFrame = false
    private var currentAuthorization: CameraAuthorization?

    func requestAuthorizationAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    self.updateAuthorization(.denied)
                }
            }
        case .denied, .restricted:
            updateAuthorization(.denied)
        @unknown default:
            updateAuthorization(.denied)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.startSessionIfNeeded()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func forceNextFrame() {
        videoQueue.async { [weak self] in
            self?.shouldForceNextFrame = true
        }
    }

    deinit {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.sync {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.isConfigured {
                self.updateAuthorization(.authorized)
                self.startSessionIfNeeded()
                return
            }

            guard let device = Self.preferredVideoDevice() else {
                self.updateAuthorization(.unavailable)
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                // Feed Vision the camera's native YUV-style buffers instead of
                // asking AVFoundation to convert every frame to BGRA for preview.
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
                output.setSampleBufferDelegate(self, queue: videoQueue)

                var didConfigure = false
                session.beginConfiguration()
                defer {
                    session.commitConfiguration()
                    if didConfigure {
                        self.videoOutput = output
                        self.isConfigured = true
                        self.updateAuthorization(.authorized)
                        self.startSessionIfNeeded()
                    }
                }

                // Vision body pose is much less reliable at the low preset in laptop
                // upper-body framing; 640x480 keeps shoulders usable without jumping to HD.
                if session.canSetSessionPreset(.vga640x480) {
                    session.sessionPreset = .vga640x480
                } else if session.canSetSessionPreset(.medium) {
                    session.sessionPreset = .medium
                } else if session.canSetSessionPreset(.low) {
                    session.sessionPreset = .low
                }

                guard session.canAddInput(input), session.canAddOutput(output) else {
                    self.updateAuthorization(.unavailable)
                    return
                }

                session.addInput(input)
                session.addOutput(output)

                if let connection = output.connection(with: .video),
                   connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    // Keep analysis buffers in camera-native geometry; the UI
                    // mirrors only its preview so Vision is not fed a display transform.
                    connection.isVideoMirrored = false
                }

                didConfigure = true
            } catch {
                self.updateAuthorization(.unavailable)
            }
        }
    }

    private func startSessionIfNeeded() {
        guard shouldRun, isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    private func updateAuthorization(_ authorization: CameraAuthorization) {
        if currentAuthorization == authorization {
            onAuthorizationChange?(authorization)
            return
        }

        currentAuthorization = authorization
        onAuthorizationChange?(authorization)
    }

    private static func preferredVideoDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        let interval = max(0, sampleIntervalProvider())

        guard shouldForceNextFrame || now - lastFrameTime >= interval else {
            return
        }

        shouldForceNextFrame = false
        lastFrameTime = now
        onFrame?(sampleBuffer)
    }
}
