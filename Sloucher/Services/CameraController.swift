import AVFoundation
import CoreMedia
import Foundation

enum CameraAuthorization: Equatable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case unavailable
}

// A selectable capture device for the camera picker (built-in, external, or an
// iPhone via Continuity Camera). Identified by AVCaptureDevice.uniqueID.
struct CameraDevice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    // True for an iPhone (Continuity) or other external camera, as opposed to
    // the built-in one. Lets the UI cue when a better-angle camera is available.
    let isExternal: Bool
}

final class CameraController: NSObject {
    var sampleIntervalProvider: () -> TimeInterval = { 1.5 }
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAuthorizationChange: ((CameraAuthorization) -> Void)?
    var onAuthorizationRequestFinished: (() -> Void)?
    // Fired when capture devices are plugged/unplugged (incl. an iPhone becoming
    // available as a Continuity Camera) so the UI list and selection can refresh.
    var onDevicesChanged: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.sloucher.camera.session")
    private let videoQueue = DispatchQueue(label: "app.sloucher.camera.video", qos: .utility)

    private var videoOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false
    private var shouldRun = false
    private var lastFrameTime: CFTimeInterval = 0
    private var shouldForceNextFrame = false
    private var currentAuthorization: CameraAuthorization?
    // uniqueID of the user-chosen camera; nil means automatic (built-in front).
    private var preferredDeviceID: String?

    override init() {
        super.init()
        // Use the stable underlying notification-name strings: the typed
        // constants were renamed in macOS 15, but the names work across our 13+
        // target without an availability split or a deprecation warning.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleDeviceChange),
                           name: NSNotification.Name("AVCaptureDeviceWasConnected"), object: nil)
        center.addObserver(self, selector: #selector(handleDeviceChange),
                           name: NSNotification.Name("AVCaptureDeviceWasDisconnected"), object: nil)
    }

    @objc private func handleDeviceChange() {
        onDevicesChanged?()
    }

    // Cameras the user can pick from: built-in, external, and (macOS 14+) an
    // iPhone via Continuity Camera. Deduplicated by uniqueID.
    static func availableCameras() -> [CameraDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
            types.append(.external)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        var seen = Set<String>()
        return discovery.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isExternal: device.deviceType != .builtInWideAngleCamera
            )
        }
    }

    // Set the preferred camera (nil = automatic). Swaps the live input if the
    // session is already running and the resolved device actually changed.
    func setPreferredDeviceID(_ id: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.preferredDeviceID = id
            self.applyPreferredDeviceIfNeeded()
        }
    }

    func refreshAuthorizationAndConfigureIfAllowed() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            updateAuthorization(currentAuthorization == .requesting ? .requesting : .notDetermined)
        case .denied, .restricted:
            updateAuthorization(.denied)
        @unknown default:
            updateAuthorization(.denied)
        }
    }

    func requestAuthorizationAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            updateAuthorization(.requesting)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    // The native sheet can be dismissed without changing TCC;
                    // read the actual system status before changing UI state.
                    self.updateAuthorizationFromSystemStatus(preserveRequesting: false)
                }
                self.onAuthorizationRequestFinished?()
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
        NotificationCenter.default.removeObserver(self)
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

            guard let device = self.resolveVideoDevice() else {
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

    private func updateAuthorizationFromSystemStatus(preserveRequesting: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            updateAuthorization(preserveRequesting && currentAuthorization == .requesting ? .requesting : .notDetermined)
        case .denied, .restricted:
            updateAuthorization(.denied)
        @unknown default:
            updateAuthorization(.denied)
        }
    }

    private func updateAuthorization(_ authorization: CameraAuthorization) {
        if currentAuthorization == authorization {
            onAuthorizationChange?(authorization)
            return
        }

        currentAuthorization = authorization
        onAuthorizationChange?(authorization)
    }

    // Resolve the device to capture from: the user's pick if it's currently
    // connected, otherwise fall back to the built-in front camera. The fallback
    // keeps the app working when the chosen iPhone/external camera is unplugged.
    private func resolveVideoDevice() -> AVCaptureDevice? {
        if let preferredDeviceID, let device = AVCaptureDevice(uniqueID: preferredDeviceID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    // Swap the running session's input to the resolved device when it differs
    // from what's currently attached. Runs on sessionQueue. Restores the previous
    // input if the new one can't be added, so the session never ends up input-less.
    private func applyPreferredDeviceIfNeeded() {
        guard isConfigured else { return } // initial configureSession() uses resolveVideoDevice()
        guard let target = resolveVideoDevice() else { return }

        let currentID = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            .first
        guard currentID != target.uniqueID else { return }
        guard let newInput = try? AVCaptureDeviceInput(device: target) else { return }

        session.beginConfiguration()
        let previousInputs = session.inputs
        previousInputs.forEach { session.removeInput($0) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
        } else {
            previousInputs.forEach { session.addInput($0) }
        }
        // The input changed, so its connection is new — re-assert unmirrored
        // capture geometry for Vision.
        if let connection = videoOutput?.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        shouldForceNextFrame = true
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
