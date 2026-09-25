import AVFoundation
import ServiceManagement
import SwiftUI
import Vision

// MARK: - Camera preview

final class PreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) // mirror like a selfie camera
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(session: session) }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

/// Circular camera view with an iPhone-style ring of ticks that fill in as progress grows.
struct FaceRing: View {
    let session: AVCaptureSession
    var progress: Double
    var tint: Color = .green

    var body: some View {
        ZStack {
            CameraPreview(session: session)
                .clipShape(Circle())
                .frame(width: 210, height: 210)
            ForEach(0..<60, id: \.self) { i in
                let lit = Double(i) / 60 < progress
                Capsule()
                    .fill(lit ? tint : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: lit ? 16 : 11)
                    .offset(y: -124)
                    .rotationEffect(.degrees(Double(i) * 6))
                    .animation(.easeOut(duration: 0.2), value: lit)
            }
        }
        .frame(width: 270, height: 270)
    }
}

// MARK: - Enrollment

final class EnrollModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var hint = "Position your face in the circle"
    @Published var done = false
    @Published var captured: [VNFeaturePrintObservation] = []

    let camera = Camera()
    private let engine = FaceEngine()
    private var samples: [VNFeaturePrintObservation] = []
    private var lastCapture = Date.distantPast
    private var lastHint = ""
    let target = 30

    func start() {
        camera.onFrame = { [weak self] pb in self?.handle(pb) }
        camera.start()
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
    }

    private func setHint(_ h: String) {
        guard h != lastHint else { return }
        lastHint = h
        DispatchQueue.main.async { self.hint = h }
    }

    private func handle(_ pb: CVPixelBuffer) {
        guard samples.count < target, Date().timeIntervalSince(lastCapture) > 0.15 else { return }
        guard let s = engine.analyze(pb, wantPrint: true, wantQuality: true) else {
            return setHint("Position your face in the circle")
        }
        if s.faceCount > 1 { return setHint("Only one face at a time") }
        if s.boundingBox.width < 0.14 { return setHint("Move a little closer") }
        if abs(s.boundingBox.midX - 0.5) > 0.22 || abs(s.boundingBox.midY - 0.5) > 0.25 { return setHint("Center your face") }
        if s.quality < 0.25 { return setHint("Hold still — more light helps") }
        guard let p = s.print else { return }

        samples.append(p)
        lastCapture = Date()
        let progress = Double(samples.count) / Double(target)
        let finished = samples.count >= target
        let copy = samples
        setHint(finished ? "Face captured" : "Slowly move your head in a circle")
        DispatchQueue.main.async {
            self.progress = progress
            if finished {
                self.captured = copy
                self.done = true
                self.stop()
            }
        }
    }
}

struct EnrollView: View {
    var existing: FaceProfile?
    var onClose: () -> Void

    @StateObject private var model = EnrollModel()
    @State private var name = ""
    @State private var started = false

    var body: some View {
        VStack(spacing: 18) {
            Text(existing == nil ? "Set Up a Face" : "Add Samples to \(existing!.name)")
                .font(.title2.weight(.semibold))

            if !started {
                VStack(spacing: 14) {
                    Image(systemName: "faceid").font(.system(size: 70, weight: .light)).foregroundStyle(.tint)
                    Text("Glimpse will take about 30 photos of your face while you slowly move your head. Everything stays on this Mac.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
                    if existing == nil {
                        TextField("Name (e.g. Me)", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                    }
                }
                .frame(height: 270)
            } else {
                FaceRing(session: model.camera.session, progress: model.progress)
                Text(model.hint).font(.headline).foregroundStyle(model.done ? .green : .primary)
            }

            HStack {
                Button("Cancel") { model.stop(); onClose() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !started {
                    Button("Get Started") { started = true; model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(existing == nil && name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Save") {
                        FaceStore.shared.save(name: name.trimmingCharacters(in: .whitespaces),
                                              samples: model.captured, existing: existing)
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.done)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onDisappear { model.stop() }
    }
}

// MARK: - Faces tab

struct FacesTab: View {
    @ObservedObject var store = FaceStore.shared
    @State private var enrolling = false
    @State private var improving: FaceProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Only faces you set up here can unlock this Mac. Nothing is added automatically.")
                .foregroundStyle(.secondary)

            if store.profiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("No faces set up yet").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.profiles) { p in
                        HStack {
                            Image(systemName: "faceid").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(p.name).font(.headline)
                                Text("\(p.sampleCount) samples · added \(p.created.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add Samples") { improving = p }
                                .help("Scan again in different lighting, with/without glasses, etc.")
                            Button(role: .destructive) { store.delete(p) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Button { enrolling = true } label: { Label("Set Up a Face…", systemImage: "plus") }
                .controlSize(.large)
        }
        .sheet(isPresented: $enrolling) { EnrollView(existing: nil) { enrolling = false } }
        .sheet(item: $improving) { p in EnrollView(existing: p) { improving = nil } }
    }
}

// MARK: - Test tab

final class TestModel: ObservableObject {
    @Published var info = ScanInfo()
    @Published var running = false
    let scanner = FaceScanner()

    func start() {
        scanner.onUpdate = { [weak self] in self?.info = $0 }
        scanner.start(timeout: nil, requireBlink: false, stopOnMatch: false)
        running = true
    }
    func stop() { scanner.stop(); running = false; info = ScanInfo() }
}

struct TestTab: View {
    @StateObject private var model = TestModel()
    @AppStorage(Prefs.strictness) private var strictness = 1.6

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            FaceRing(session: model.scanner.session, progress: model.info.isMatch ? 1 : 0,
                     tint: .green)
            VStack(alignment: .leading, spacing: 10) {
                Text("Try it out").font(.title3.weight(.semibold))
                Text("Check that you're recognized, then have someone else (or a photo of you) try. Their score should stay above the limit.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                row("Face", model.info.faceFound ? "Detected" : "—")
                row("Best match", model.info.match?.profile.name ?? "—")
                row("Score", model.info.match.map { String(format: "%.2f", $0.ratio) } ?? "—")
                row("Limit", String(format: "≤ %.2f", strictness))
                row("Blink", model.info.blinked ? "Seen ✓" : "Not yet")
                HStack {
                    Image(systemName: model.info.isMatch ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.info.isMatch ? .green : .secondary)
                    Text(model.info.isMatch ? "Would unlock" : "Would not unlock").font(.headline)
                }
                .padding(.top, 4)
                Spacer()
                Button(model.running ? "Stop Camera" : "Start Camera") { model.running ? model.stop() : model.start() }
                    .controlSize(.large)
            }
        }
        .onDisappear { model.stop() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); Text(v).monospacedDigit() }
    }
}

// MARK: - Password tab

struct PasswordTab: View {
    @State private var password = ""
    @State private var stored = Keychain.exists
    @State private var readable = Keychain.readableWithoutPrompt
    @State private var message = ""
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(!stored ? "No password stored yet."
                     : readable ? "Your password is stored in your login Keychain."
                     : "Please enter your password again (it was saved by an older version).")
                    .font(.headline)
            } icon: {
                Image(systemName: stored && readable ? "lock.shield.fill" : "lock.open")
                    .foregroundStyle(stored && readable ? .green : .orange)
            }

            Text("macOS doesn't let any app unlock the screen by itself — apps like this unlock by typing your password for you once your face is recognized. Glimpse keeps it only in your own Keychain on this Mac, never writes it to disk or sends it anywhere, and only uses it at the lock screen.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                SecureField("Mac login password", text: $password).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit(save)
                Button(stored ? "Replace" : "Save", action: save).disabled(password.isEmpty)
            }
            if !message.isEmpty {
                Text(message).foregroundStyle(error ? .red : .green)
            }
            if stored {
                Button("Remove Password", role: .destructive) {
                    Keychain.delete(); stored = false; readable = false; message = "Password removed."; error = false
                }
            }
            Text("If you change your Mac password, update it here too.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func save() {
        guard !password.isEmpty else { return }
        guard PasswordVerifier.verify(password) else {
            message = "That isn't the password for \(NSUserName())."; error = true; return
        }
        stored = Keychain.save(password)
        readable = Keychain.readableWithoutPrompt
        password = ""
        message = stored ? "Saved to Keychain." : "Couldn't save to Keychain."
        error = !stored
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @AppStorage(Prefs.enabled) private var enabled = true
    @AppStorage(Prefs.strictness) private var strictness = 1.6
    @AppStorage(Prefs.requireBlink) private var requireBlink = false
    @AppStorage(Prefs.minLockSeconds) private var minLock = 3.0
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var cameraOK = Camera.authorization == .authorized
    @State private var axOK = Unlocker.hasAccessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Unlock with my face at the lock screen", isOn: $enabled)
                Toggle("Open Glimpse at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { loginItem = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Security") {
                VStack(alignment: .leading) {
                    Slider(value: $strictness, in: 1.1...2.4) {
                        Text("Match limit")
                    } minimumValueLabel: { Text("Strict") } maximumValueLabel: { Text("Lenient") }
                    Text(String(format: "Current limit: %.2f — use the Test tab to tune it.", strictness))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: $minLock, in: 0...30, step: 1) {
                    Text("Start scanning \(Int(minLock))s after the lock screen appears")
                }
                Toggle("Also require a blink (optional — harder to fool with a photo)", isOn: $requireBlink)
            }
            Section("Permissions") {
                HStack {
                    status(cameraOK, "Camera")
                    Spacer()
                    if !cameraOK {
                        Button("Allow") {
                            if Camera.authorization == .notDetermined {
                                AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { cameraOK = ok } }
                            } else {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        status(axOK, "Accessibility (to type your password at the lock screen)")
                        Spacer()
                        if !axOK {
                            Button("Fix & Allow") {
                                Unlocker.resetAndRequestAccessibility()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                    if !axOK {
                        Text("If Glimpse already looks switched on in System Settings, that switch belongs to an older copy of the app. Click Fix & Allow to clear it, then turn Glimpse on again in the list.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            cameraOK = Camera.authorization == .authorized
            axOK = Unlocker.hasAccessibility
        }
    }

    private func status(_ ok: Bool, _ label: String) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? Color.primary : Color.orange)
    }
}

// MARK: - Root

struct SettingsView: View {
    var body: some View {
        TabView {
            FacesTab().padding(20).tabItem { Label("Faces", systemImage: "faceid") }
            TestTab().padding(20).tabItem { Label("Test", systemImage: "camera.viewfinder") }
            PasswordTab().padding(20).tabItem { Label("Password", systemImage: "key") }
            GeneralTab().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 480)
    }
}
