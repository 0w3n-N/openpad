import AVFoundation
import OpenPadCore
import SwiftUI

/// Connect to the computer: scan its QR code, or type its address and PIN.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = true
    @State private var busy = false
    @State private var error: String?
    @State private var address = ""
    @State private var pin = ""
    @State private var cameraProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On the computer, switch OpenPad on and show its QR code (bar icon, or **Pair** in the OpenPad window). Then point the camera at it.")
                        .font(.callout)
                    if scanning && cameraProblem == nil {
                        QRScanner { text in
                            guard !busy, let code = PairingCode(text) else { return false }
                            connect { try await ServerLink.connect(host: code.host, key: code.key) }
                            return true
                        } failed: { problem in
                            cameraProblem = problem
                        }
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                    } else if let cameraProblem {
                        Text(cameraProblem).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView("Connecting…") }
                    if let error { Text(error).foregroundStyle(.red) }
                    if error != nil && !busy {
                        Button("Scan again") {
                            error = nil
                            scanning = true
                        }
                    }
                }
                Section("Or enter the address and PIN shown under the code") {
                    TextField("Address, e.g. 192.168.1.20:8770", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                    Button("Connect") {
                        connect { try await ServerLink.pair(address: address, pin: pin) }
                    }
                    .disabled(address.isEmpty || pin.count < 6 || busy)
                }
                Section {
                    Text("Both devices need to be on the same Wi-Fi. The first time, iPadOS asks to let OpenPad find devices on your local network: allow it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect to your computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func connect(_ attempt: @escaping () async throws -> ServerLink) {
        busy = true
        error = nil
        scanning = false
        Task {
            do {
                let link = try await attempt()
                model.setLink(link)
                model.say("Connected to \(link.displayName). Syncing…")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The back camera, reporting QR codes until `found` accepts one.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Bool
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        c.failed = failed
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String) -> Bool)?
    var failed: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok {
                        self.setUp()
                    } else {
                        self.failed?("Camera access was declined. Allow it in Settings › OpenPad, or enter the address and PIN below.")
                    }
                }
            }
        default:
            failed?("Camera access is off. Turn it on in Settings › OpenPad, or enter the address and PIN below.")
        }
    }

    private func setUp() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            failed?("No camera is available. Enter the address and PIN below.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            failed?("The camera can't scan codes. Enter the address and PIN below.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }

    private var rotationAngle: CGFloat {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    // Delivered on the main queue (see setMetadataObjectsDelegate).
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated { self.seen(texts) }
    }

    private func seen(_ texts: [String]) {
        guard !done else { return }
        for text in texts where found?(text) == true {
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
            return
        }
    }
}
