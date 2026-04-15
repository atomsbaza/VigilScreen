@preconcurrency import AVFoundation
import AppKit

/// Captures a still photo from the front-facing (FaceTime) camera when an
/// unauthorised unlock attempt is detected. Photos are saved as JPEG files in
/// the app's Captures directory and linked to a LockHistoryStore event.
@MainActor
class IntruderCaptureManager: NSObject, AVCapturePhotoCaptureDelegate {
    static let shared = IntruderCaptureManager()

    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var captureCompletion: ((String?) -> Void)?

    // MARK: - Public API

    /// Returns true if the camera is accessible (permission granted + hardware present).
    var isAvailable: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized &&
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    /// Requests camera permission if needed, then captures a photo.
    /// Calls `completion` on the main actor with the saved filename, or nil on failure.
    func capturePhoto(completion: @MainActor @escaping (String?) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            performCapture(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.performCapture(completion: completion)
                    } else {
                        completion(nil)
                    }
                }
            }
        default:
            // Denied or restricted — record event without photo
            completion(nil)
        }
    }

    // MARK: - Private

    private func performCapture(completion: @MainActor @escaping (String?) -> Void) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            completion(nil)
            return
        }

        captureCompletion = completion

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { completion(nil); return }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { completion(nil); return }
        session.addOutput(output)

        self.session = session
        self.photoOutput = output

        // startRunning() must NOT be called on the main thread — it blocks until the
        // session is ready and will cause a runtime warning (or silent failure) if
        // invoked from a @MainActor context. Dispatch to a background queue instead.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            // Brief delay so the sensor can adjust exposure before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, session.isRunning else {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        // Extract Data here in the nonisolated context — AVCapturePhoto is not Sendable
        // and cannot be captured by the @MainActor closure below. Data IS Sendable.
        let photoData: Data? = error == nil ? photo.fileDataRepresentation() : nil

        Task { @MainActor in
            defer {
                self.session?.stopRunning()
                self.session = nil
                self.photoOutput = nil
            }

            guard let data = photoData else {
                self.captureCompletion?(nil)
                self.captureCompletion = nil
                return
            }

            let filename = "\(UUID().uuidString).jpg"
            let url = LockHistoryStore.capturesDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                self.captureCompletion?(filename)
            } catch {
                self.captureCompletion?(nil)
            }
            self.captureCompletion = nil
        }
    }
}
