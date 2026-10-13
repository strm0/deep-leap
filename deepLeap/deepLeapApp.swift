//
//  deepLeapApp.swift
//  deepLeap
//
//  Created by Oscar Ström on 6.11.2025.
//

import SwiftUI
import AVFoundation
import Vision
import Combine
import Darwin

// MARK: - Connection Status

enum ConnectionStatus: String {
    case connected = "Connected ✓"
    case disconnected = "Disconnected"
    case noCamera = "No camera selected"
    case connecting = "Connecting…"
}

// MARK: - Preferences

enum PreferenceKeys {
    static func cameraId(for zone: Int) -> String {
        "zone\(zone).cameraDeviceId"
    }
    static func controlMode(for zone: Int) -> String {
        "zone\(zone).controlMode"
    }
static func zoneActive(for zone: Int) -> String {
        "zone\(zone).isActive"
    }
    static func viewMode(for zone: Int) -> String {
        "zone\(zone).viewMode"
    }
    static func responsiveness(for zone: Int) -> String {
        "zone\(zone).responsiveness"
    }
    static func useActiveZone(for zone: Int) -> String {
        "zone\(zone).useActiveZone"
    }
    static func activeZoneSize(for zone: Int) -> String {
        "zone\(zone).activeZoneSize"
    }
}

// MARK: - Camera Manager

final class CameraManager: ObservableObject {
    static let shared = CameraManager()

    @Published var discoveredDevices: [AVCaptureDevice] = []

    private init() {
        refreshDevices()
        observeDeviceChanges()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        discoveredDevices = discovery.devices
        print("[CameraManager] Found \(discoveredDevices.count) camera(s):")
        for device in discoveredDevices {
            print("  - \(device.localizedName) (\(device.uniqueID))")
        }
    }

    func device(for uniqueID: String) -> AVCaptureDevice? {
        discoveredDevices.first { $0.uniqueID == uniqueID }
    }

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
    }
}

// MARK: - Dancer State Model

struct DancerState {
    var dancerId: Int  // 1 or 2
    var bodyKeypoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    var leftMiddleTip: CGPoint? = nil
    var rightMiddleTip: CGPoint? = nil
    var bodyCenter: CGPoint? = nil  // For click detection & ID label placement

    // For persistence when leaving/returning
    var lastSeenTime: TimeInterval = 0
    var isActive: Bool = false

    // For matching across frames
    var lastKnownCenter: CGPoint? = nil
}

@main
struct DeepLeapApp: App {
    @StateObject private var zone1 = CameraModel(zoneId: 1)
    @StateObject private var zone2 = CameraModel(zoneId: 2)

    var body: some Scene {
        WindowGroup {
            ContentView(zone1: zone1, zone2: zone2)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

/// Minimal OSC sender for UDP messages with float arguments only.
/// Uses a plain BSD UDP socket to match typical OSC receivers (Max, SM OSC, etc.).
final class SimpleOSCSender {
    private let socketFD: Int32
    private var addr: sockaddr_in

    init(host: String, port: UInt16) {
        // Create UDP socket
        socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)

        var addrIn = sockaddr_in()
        addrIn.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addrIn.sin_family = sa_family_t(AF_INET)
        addrIn.sin_port = port.bigEndian
        addrIn.sin_addr = in_addr(s_addr: inet_addr(host))
        addrIn.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)
        self.addr = addrIn
    }

    deinit {
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    func send(address: String, floats: [Float]) {
        let data = makeOSCMessage(address: address, floats: floats)
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var addrCopy = addr
            let sent = withUnsafePointer(to: &addrCopy) { ptr -> ssize_t in
                let rawPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
                return Darwin.sendto(socketFD, baseAddress, buffer.count, 0, rawPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            if sent < 0 {
                perror("sendto")
            }
        }
    }

    private func makeOSCMessage(address: String, floats: [Float]) -> Data {
        var data = Data()

        func appendPaddedString(_ string: String) {
            var bytes = Array(string.utf8)
            bytes.append(0) // null terminator
            data.append(contentsOf: bytes)
            while data.count % 4 != 0 {
                data.append(0)
            }
        }

        // OSC address pattern
        appendPaddedString(address)

        // Type tag string: starts with ',' and then one 'f' per float
        let typeTag = "," + String(repeating: "f", count: floats.count)
        appendPaddedString(typeTag)

        // Arguments: 32-bit big-endian floats
        for f in floats {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        return data
    }
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum ControlMode: Int, CaseIterable {
        case lockedHand = 1
        case lockedHandVertical = 2

        var description: String {
            switch self {
            case .lockedHand: return "Center"
            case .lockedHandVertical: return "Top / Bottom"
            }
        }
    }

    enum ViewMode: String, CaseIterable {
        case cropToFit = "Crop"
        case fullFrame = "Full"
    }


    // MARK: - Zone Configuration
    let zoneId: Int
    @Published var connectionStatus: ConnectionStatus = .noCamera

    @Published var selectedCameraId: String? {
        didSet {
            if selectedCameraId != oldValue {
                savePreference(selectedCameraId, forKey: PreferenceKeys.cameraId(for: zoneId))
            }
        }
    }

    var oscPrefix: String {
        "/zone\(zoneId)"
    }

    // MARK: - Published State
    @Published var canvasSize: CGSize = .zero
    @Published var permissionDenied = false
    @Published var lastStatus: String = "Starting…"
    @Published var videoRect: CGRect = .zero
    @Published var controlMode: ControlMode = .lockedHand {
        didSet {
            if controlMode != oldValue {
                savePreference(controlMode.rawValue, forKey: PreferenceKeys.controlMode(for: zoneId))
                responsiveness = 0.5
                print("[Zone \(zoneId)] Reset responsiveness to default")
            }
        }
    }

    @Published var isZoneActive: Bool = true {
        didSet {
            if isZoneActive != oldValue {
                savePreference(isZoneActive, forKey: PreferenceKeys.zoneActive(for: zoneId))
            }
        }
    }

    @Published var viewMode: ViewMode = .cropToFit {
        didSet {
            if viewMode != oldValue {
                savePreference(viewMode.rawValue, forKey: PreferenceKeys.viewMode(for: zoneId))
                applyViewMode()
            }
        }
    }

    @Published var responsiveness: Double = 0.5 {
        didSet {
            if responsiveness != oldValue {
                savePreference(responsiveness, forKey: PreferenceKeys.responsiveness(for: zoneId))
            }
        }
    }

    @Published var useActiveZone: Bool = false {
        didSet {
            if useActiveZone != oldValue {
                savePreference(useActiveZone, forKey: PreferenceKeys.useActiveZone(for: zoneId))
            }
        }
    }

    @Published var activeZoneSize: Double = 1.0 {
        didSet {
            if activeZoneSize != oldValue {
                savePreference(activeZoneSize, forKey: PreferenceKeys.activeZoneSize(for: zoneId))
                updateActiveZoneRect()
            }
        }
    }

    @Published var activeZoneRect: CGRect = .zero

    @Published var lockedHandPosition: CGPoint? = nil
    @Published var isHandLocked: Bool = false
    @Published var lastLockedHandOSCValue: Float = 0.0
    private var relockRampStartValue: Float? = nil
    private var relockRampStartTime: TimeInterval? = nil
    private let RELOCK_RAMP_DURATION: TimeInterval = 3.0

    // Multi-dancer state
    @Published var dancers: [DancerState] = [
        DancerState(dancerId: 1),
        DancerState(dancerId: 2)
    ]

    // MARK: - Initializer
    init(zoneId: Int = 1) {
        self.zoneId = zoneId
        self.camQueue = DispatchQueue(label: "deepleap.cam.queue.\(zoneId)")
        super.init()
        loadPreferences()
    }

    // MARK: - Preferences
    private func loadPreferences() {
        let defaults = UserDefaults.standard

        // Load saved camera ID
        if let savedCameraId = defaults.string(forKey: PreferenceKeys.cameraId(for: zoneId)) {
            // Verify the camera still exists before using it
            if CameraManager.shared.device(for: savedCameraId) != nil {
                selectedCameraId = savedCameraId
                print("[Zone \(zoneId)] Loaded saved camera: \(savedCameraId)")
            } else {
                print("[Zone \(zoneId)] Saved camera no longer available: \(savedCameraId)")
            }
        }

        // Load saved control mode
        if let savedMode = defaults.object(forKey: PreferenceKeys.controlMode(for: zoneId)) as? Int,
           let mode = ControlMode(rawValue: savedMode) {
            controlMode = mode
            print("[Zone \(zoneId)] Loaded saved control mode: \(mode.description)")
        }

        // Load saved zone active state
        if let savedActive = defaults.object(forKey: PreferenceKeys.zoneActive(for: zoneId)) as? Bool {
            isZoneActive = savedActive
            print("[Zone \(zoneId)] Loaded saved zone active: \(savedActive)")
        }

        // Load saved view mode
        if let savedViewMode = defaults.string(forKey: PreferenceKeys.viewMode(for: zoneId)),
           let vm = ViewMode(rawValue: savedViewMode) {
            viewMode = vm
            print("[Zone \(zoneId)] Loaded saved view mode: \(vm.rawValue)")
        }

        // Load saved responsiveness
        if let savedResp = defaults.object(forKey: PreferenceKeys.responsiveness(for: zoneId)) as? Double {
            responsiveness = max(0.2, min(1.0, savedResp))
            print("[Zone \(zoneId)] Loaded saved responsiveness: \(savedResp)")
        }

        // Load saved active zone settings
        if let savedUseActiveZone = defaults.object(forKey: PreferenceKeys.useActiveZone(for: zoneId)) as? Bool {
            useActiveZone = savedUseActiveZone
            print("[Zone \(zoneId)] Loaded saved useActiveZone: \(savedUseActiveZone)")
        }
        if let savedActiveZoneSize = defaults.object(forKey: PreferenceKeys.activeZoneSize(for: zoneId)) as? Double {
            activeZoneSize = max(0.5, min(1.0, savedActiveZoneSize))
            print("[Zone \(zoneId)] Loaded saved activeZoneSize: \(savedActiveZoneSize)")
        }
    }

    private func savePreference<T>(_ value: T?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        print("[Zone \(zoneId)] Saved preference \(key): \(String(describing: value))")
    }

    // MARK: - Settings
    private let MIRROR_PREVIEW = true
    private let CONFIDENCE_THRESHOLD: Float = 0.05
    private var positionSmoothingAlpha: CGFloat { CGFloat(responsiveness) }
    private let DANCER_PERSISTENCE_TIMEOUT: TimeInterval = 1.0  // seconds before slot is "free"
    private let BODY_MATCH_THRESHOLD: CGFloat = 150.0  // max distance to match returning dancer
    @Published var useStrictMatching: Bool = true
    private var HAND_MATCH_THRESHOLD: CGFloat {
        useStrictMatching ? 100.0 : 200.0
    }

    // OSC + mapping settings
    private var oscSender = SimpleOSCSender(host: "127.0.0.1", port: 9000)
    private let useSmoothing = true
    private var oscSmoothingAlpha: Float { Float(responsiveness) }
    private let sendInterval: TimeInterval = 1.0 / 30.0
    private var lastSendTime: TimeInterval = 0

    // MARK: - Click to Assign
    func handleClick(at point: CGPoint) {
        guard !isHandLocked else { return }

        var closestHand: CGPoint? = nil
        var closestDist: CGFloat = 100  // click radius
        for dancer in dancers where dancer.isActive {
            if let lh = dancer.leftMiddleTip {
                let dist = hypot(point.x - lh.x, point.y - lh.y)
                if dist < closestDist { closestDist = dist; closestHand = lh }
            }
            if let rh = dancer.rightMiddleTip {
                let dist = hypot(point.x - rh.x, point.y - rh.y)
                if dist < closestDist { closestDist = dist; closestHand = rh }
            }
        }
        if let hand = closestHand {
            lockedHandPosition = hand
            isHandLocked = true
            if relockRampStartValue != nil && relockRampStartTime == nil {
                relockRampStartTime = Date().timeIntervalSince1970
                print("[Zone \(zoneId)] Hand relocked, ramping over \(RELOCK_RAMP_DURATION)s")
            }
            print("[Zone \(zoneId)] Hand locked at position \(hand)")
        }
    }

    func unlockHand() {
        relockRampStartValue = lastLockedHandOSCValue
        relockRampStartTime = nil
        isHandLocked = false
        lockedHandPosition = nil
        print("[Zone \(zoneId)] Hand unlocked, will ramp from \(lastLockedHandOSCValue)")
    }

    // MARK: - Capture
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let camQueue: DispatchQueue
    private var imageSize: CGSize = .zero
    private weak var hostLayer: CALayer?
    private var currentInput: AVCaptureDeviceInput?
    private var deviceObservers: [NSObjectProtocol] = []

    // Vision requests
    private let bodyRequest: VNDetectHumanBodyPoseRequest = {
        let r = VNDetectHumanBodyPoseRequest()
        if #available(macOS 12.0, *) {
            if let best = VNDetectHumanBodyPoseRequest.supportedRevisions.max() { r.revision = best }
        }
        return r
    }()

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 4  // Up to 4 hands for 2 people
        return r
    }()

    private var seq = VNSequenceRequestHandler()
    private var frameCounter: Int = 0
    private var oscRefreshCounter: Int = 0

    // MARK: - Public hooks
    func setCanvasSize(_ size: CGSize) {
        if canvasSize != size {
            canvasSize = size
            updateVideoRect()
            updatePreviewFrame()
        }
    }

    // MARK: - Start
    func start(on hostLayer: CALayer) {
        self.hostLayer = hostLayer
        observeDeviceChanges()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted { self.configureAndStartSession() }
                else { self.permissionDenied = true }
            }
        }
    }

    // MARK: - Camera Selection
    func selectCamera(deviceId: String?) {
        selectedCameraId = deviceId
        guard hostLayer != nil else { return }

        // Reconfigure with new camera
        connectionStatus = .connecting
        configureAndStartSession()
    }

    func stopSession() {
        session.stopRunning()
        connectionStatus = .disconnected
    }

    // MARK: - Hot-swap Detection
    private func observeDeviceChanges() {
        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.selectedCameraId else { return }
            print("[Zone \(self.zoneId)] Camera disconnected: \(device.localizedName)")
            self.session.stopRunning()
            self.connectionStatus = .disconnected
            self.lastStatus = "Camera disconnected — \(device.localizedName)"
            for i in self.dancers.indices { self.dancers[i].isActive = false }
        }

        let connectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.selectedCameraId,
                  self.connectionStatus == .disconnected else { return }
            print("[Zone \(self.zoneId)] Camera reconnected: \(device.localizedName)")
            self.connectionStatus = .connecting
            self.lastStatus = "Reconnecting…"
            self.configureAndStartSession()
        }

        deviceObservers = [disconnectObserver, connectObserver]
    }

    private func removeDeviceObservers() {
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        deviceObservers.removeAll()
    }

    // MARK: - Capture setup
    private func configureAndStartSession() {
        guard let hostLayer = hostLayer else {
            connectionStatus = .disconnected
            return
        }

        // Stop existing session if running
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        // Remove existing input if any
        if let existingInput = currentInput {
            session.removeInput(existingInput)
            currentInput = nil
        }

        // Find the camera device
        let devices = CameraManager.shared.discoveredDevices
        let selectedDevice: AVCaptureDevice?

        if let cameraId = selectedCameraId {
            // Use explicitly selected camera
            selectedDevice = CameraManager.shared.device(for: cameraId)
        } else {
            // Auto-select: prefer iPhone, then external, then built-in
            selectedDevice =
                devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("iphone") }) ??
                devices.first(where: { $0.deviceType == .externalUnknown }) ??
                devices.first
        }

        guard let device = selectedDevice else {
            lastStatus = "No camera device found"
            connectionStatus = .noCamera
            print("[Zone \(zoneId)] \(lastStatus)")
            session.commitConfiguration()
            return
        }

        // Update selectedCameraId if we auto-selected
        if selectedCameraId == nil {
            selectedCameraId = device.uniqueID
        }

        print("[Zone \(zoneId)] Using camera: \(device.localizedName)")

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            lastStatus = "Failed to open camera input"
            connectionStatus = .disconnected
            print("[Zone \(zoneId)] \(lastStatus)")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        // Only add output if not already added
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: camQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        // Setup preview layer
        if previewLayer == nil {
            let pl = AVCaptureVideoPreviewLayer(session: session)
            pl.videoGravity = viewMode == .cropToFit ? .resizeAspectFill : .resizeAspect
            pl.frame = hostLayer.bounds

            if let plConn = pl.connection, plConn.isVideoMirroringSupported {
                plConn.automaticallyAdjustsVideoMirroring = false
                plConn.isVideoMirrored = MIRROR_PREVIEW
            } else if MIRROR_PREVIEW {
                pl.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }

            hostLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            hostLayer.addSublayer(pl)
            self.previewLayer = pl
        }

        session.commitConfiguration()
        session.startRunning()

        connectionStatus = .connected
        lastStatus = "Camera running… step into frame"
    }

    private func updatePreviewFrame() {
        previewLayer?.frame = CGRect(origin: .zero, size: canvasSize)
    }

    private func applyViewMode() {
        previewLayer?.videoGravity = viewMode == .cropToFit ? .resizeAspectFill : .resizeAspect
        updateVideoRect()
    }

    private func updateVideoRect() {
        guard canvasSize.width > 0, canvasSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            videoRect = .zero; return
        }
        let container = CGRect(origin: .zero, size: canvasSize)
        if viewMode == .fullFrame {
            videoRect = makeAspectFitRect(aspect: imageSize, inside: container)
        } else {
            videoRect = makeAspectFillRect(aspect: imageSize, inside: container)
        }
        updateActiveZoneRect()
    }

    private func updateActiveZoneRect() {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            activeZoneRect = .zero; return
        }
        let squareSide = min(canvasSize.width, canvasSize.height) * activeZoneSize
        let x = (canvasSize.width - squareSide) / 2
        let y = (canvasSize.height - squareSide) / 2
        activeZoneRect = CGRect(x: x, y: y, width: squareSide, height: squareSide)
    }

    private func makeAspectFillRect(aspect: CGSize, inside: CGRect) -> CGRect {
        let scale = max(inside.width / aspect.width, inside.height / aspect.height)
        let w = aspect.width * scale
        let h = aspect.height * scale
        let x = inside.midX - w / 2
        let y = inside.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func makeAspectFitRect(aspect: CGSize, inside: CGRect) -> CGRect {
        let scale = min(inside.width / aspect.width, inside.height / aspect.height)
        let w = aspect.width * scale
        let h = aspect.height * scale
        let x = inside.midX - w / 2
        let y = inside.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func mapPointToCanvas(normalized p: CGPoint) -> CGPoint {
        guard videoRect != .zero else { return .zero }
        let px = MIRROR_PREVIEW ? (1.0 - p.x) : p.x
        let py = p.y
        let x = videoRect.minX + px * videoRect.width
        let y = videoRect.minY + (1.0 - py) * videoRect.height
        return CGPoint(x: x, y: y)
    }

    private func smoothPoint(_ new: CGPoint, previous: CGPoint?) -> CGPoint {
        guard let prev = previous else { return new }
        let a = positionSmoothingAlpha
        return CGPoint(x: prev.x + (new.x - prev.x) * a,
                       y: prev.y + (new.y - prev.y) * a)
    }

    // MARK: - Body Center Calculation
    private func calculateBodyCenter(from keypoints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGPoint? {
        // Try to get hip center first (most stable)
        if let root = keypoints[.root] {
            return root
        }

        // Fall back to average of shoulders
        if let leftShoulder = keypoints[.leftShoulder],
           let rightShoulder = keypoints[.rightShoulder] {
            return CGPoint(
                x: (leftShoulder.x + rightShoulder.x) / 2,
                y: (leftShoulder.y + rightShoulder.y) / 2
            )
        }

        // Fall back to any available point
        if let firstPoint = keypoints.values.first {
            return firstPoint
        }

        return nil
    }

    // MARK: - Frames → Vision
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        frameCounter += 1
        if frameCounter >= 1000 {
            seq = VNSequenceRequestHandler()
            frameCounter = 0
        }

        oscRefreshCounter += 1
        if oscRefreshCounter >= 1800 {
            oscSender = SimpleOSCSender(host: "127.0.0.1", port: 9000)
            oscRefreshCounter = 0
        }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let newSize = CGSize(width: w, height: h)
        if newSize != imageSize {
            imageSize = newSize
            DispatchQueue.main.async { self.updateVideoRect() }
        }

        do {
            try seq.perform([bodyRequest, handRequest], on: pb)
            let now = Date().timeIntervalSince1970

            // --- PROCESS ALL BODIES (up to 2) ---
            var detectedBodies: [(keypoints: [VNHumanBodyPoseObservation.JointName: CGPoint], center: CGPoint)] = []

            if let bodyResults = bodyRequest.results, !bodyResults.isEmpty {
                for bodyObs in bodyResults.prefix(1) {
                    if let points = try? bodyObs.recognizedPoints(.all) {
                        var bodyMap: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
                        for (name, p) in points {
                            if p.confidence > CONFIDENCE_THRESHOLD {
                                let norm = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                                let canvasPt = mapPointToCanvas(normalized: norm)
                                bodyMap[name] = canvasPt
                            }
                        }
                        if !bodyMap.isEmpty, let center = calculateBodyCenter(from: bodyMap) {
                            detectedBodies.append((keypoints: bodyMap, center: center))
                        }
                    }
                }
            }

            // --- PROCESS ALL HANDS ---
            var detectedHands: [(tip: CGPoint, wrist: CGPoint?)] = []

            if let handResults = handRequest.results, !handResults.isEmpty {
                for handObs in handResults {
                    if let tipPoint = try? handObs.recognizedPoint(.middleTip),
                       tipPoint.confidence > CONFIDENCE_THRESHOLD {
                        let tipNorm = CGPoint(x: CGFloat(tipPoint.x), y: CGFloat(tipPoint.y))
                        let tipCanvas = mapPointToCanvas(normalized: tipNorm)

                        var wristCanvas: CGPoint? = nil
                        if let wristPoint = try? handObs.recognizedPoint(.wrist),
                           wristPoint.confidence > CONFIDENCE_THRESHOLD {
                            let wristNorm = CGPoint(x: CGFloat(wristPoint.x), y: CGFloat(wristPoint.y))
                            wristCanvas = mapPointToCanvas(normalized: wristNorm)
                        }

                        detectedHands.append((tip: tipCanvas, wrist: wristCanvas))
                    }
                }
            }

            DispatchQueue.main.async {
                let size = self.canvasSize
                guard size.width > 0, size.height > 0 else { return }

                // --- MATCH DETECTED BODIES TO DANCER SLOTS ---
                var usedBodyIndices: Set<Int> = []
                var updatedDancers = self.dancers

                // First pass: match by proximity to last known position
                for slotIndex in updatedDancers.indices {
                    if let lastCenter = updatedDancers[slotIndex].lastKnownCenter {
                        var bestMatch: Int? = nil
                        var bestDist: CGFloat = self.BODY_MATCH_THRESHOLD

                        for (bodyIndex, body) in detectedBodies.enumerated() where !usedBodyIndices.contains(bodyIndex) {
                            let dist = hypot(body.center.x - lastCenter.x, body.center.y - lastCenter.y)
                            if dist < bestDist {
                                bestDist = dist
                                bestMatch = bodyIndex
                            }
                        }

                        if let matchedIndex = bestMatch {
                            usedBodyIndices.insert(matchedIndex)
                            let body = detectedBodies[matchedIndex]

                            // Smooth keypoints
                            var smoothedKeypoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
                            for (name, p) in body.keypoints {
                                let prev = updatedDancers[slotIndex].bodyKeypoints[name]
                                smoothedKeypoints[name] = self.smoothPoint(p, previous: prev)
                            }

                            updatedDancers[slotIndex].bodyKeypoints = smoothedKeypoints
                            updatedDancers[slotIndex].bodyCenter = self.smoothPoint(body.center, previous: updatedDancers[slotIndex].bodyCenter)
                            updatedDancers[slotIndex].lastKnownCenter = updatedDancers[slotIndex].bodyCenter
                            updatedDancers[slotIndex].lastSeenTime = now
                            updatedDancers[slotIndex].isActive = true
                        }
                    }
                }

                // Assign remaining bodies to empty/expired slots
                for (bodyIndex, body) in detectedBodies.enumerated() where !usedBodyIndices.contains(bodyIndex) {
                    let slotIndex = 0
                    let isExpired = now - updatedDancers[slotIndex].lastSeenTime > self.DANCER_PERSISTENCE_TIMEOUT
                    if !updatedDancers[slotIndex].isActive || isExpired {
                        var smoothedKeypoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
                        for (name, p) in body.keypoints {
                            let prev = updatedDancers[slotIndex].bodyKeypoints[name]
                            smoothedKeypoints[name] = self.smoothPoint(p, previous: prev)
                        }

                        updatedDancers[slotIndex].bodyKeypoints = smoothedKeypoints
                        updatedDancers[slotIndex].bodyCenter = body.center
                        updatedDancers[slotIndex].lastKnownCenter = body.center
                        updatedDancers[slotIndex].lastSeenTime = now
                        updatedDancers[slotIndex].isActive = true
                    }
                }

                // Mark dancers as inactive if not seen recently
                for slotIndex in updatedDancers.indices {
                    if now - updatedDancers[slotIndex].lastSeenTime > self.DANCER_PERSISTENCE_TIMEOUT {
                        updatedDancers[slotIndex].isActive = false
                    }
                }

                // --- MATCH HANDS TO BODIES ---
                if !self.isHandLocked {
                for slotIndex in updatedDancers.indices where updatedDancers[slotIndex].isActive {
                    let bodyKeypoints = updatedDancers[slotIndex].bodyKeypoints

                    // Get wrist positions from body
                    let leftWrist = bodyKeypoints[.leftWrist]
                    let rightWrist = bodyKeypoints[.rightWrist]

                    // Find hands closest to each wrist
                    var bestLeftHand: CGPoint? = nil
                    var bestLeftDist: CGFloat = 200  // max matching distance
                    var bestRightHand: CGPoint? = nil
                    var bestRightDist: CGFloat = 200

                    for hand in detectedHands {
                        // Try to match by wrist proximity
                        if let wrist = hand.wrist {
                            if let lw = leftWrist {
                                let dist = hypot(wrist.x - lw.x, wrist.y - lw.y)
                                if dist < bestLeftDist {
                                    bestLeftDist = dist
                                    bestLeftHand = hand.tip
                                }
                            }
                            if let rw = rightWrist {
                                let dist = hypot(wrist.x - rw.x, wrist.y - rw.y)
                                if dist < bestRightDist {
                                    bestRightDist = dist
                                    bestRightHand = hand.tip
                                }
                            }
                        } else {
                            // Fall back to tip proximity to wrist
                            if let lw = leftWrist {
                                let dist = hypot(hand.tip.x - lw.x, hand.tip.y - lw.y)
                                if dist < bestLeftDist {
                                    bestLeftDist = dist
                                    bestLeftHand = hand.tip
                                }
                            }
                            if let rw = rightWrist {
                                let dist = hypot(hand.tip.x - rw.x, hand.tip.y - rw.y)
                                if dist < bestRightDist {
                                    bestRightDist = dist
                                    bestRightHand = hand.tip
                                }
                            }
                        }
                    }

                    // If no wrists available, fall back to body center left/right split
                    if leftWrist == nil && rightWrist == nil, let center = updatedDancers[slotIndex].bodyCenter {
                        var handsNearBody: [(tip: CGPoint, dist: CGFloat)] = []
                        for hand in detectedHands {
                            let dist = hypot(hand.tip.x - center.x, hand.tip.y - center.y)
                            if dist < 400 {  // within reasonable distance of body
                                handsNearBody.append((tip: hand.tip, dist: dist))
                            }
                        }

                        // Sort by X position, leftmost = left hand
                        let sorted = handsNearBody.sorted { $0.tip.x < $1.tip.x }
                        if sorted.count >= 2 {
                            bestLeftHand = sorted.first?.tip
                            bestRightHand = sorted.last?.tip
                        } else if sorted.count == 1 {
                            let hand = sorted[0].tip
                            if hand.x < center.x {
                                bestLeftHand = hand
                            } else {
                                bestRightHand = hand
                            }
                        }
                    }

                    // Smooth hand positions
                    if let lh = bestLeftHand {
                        updatedDancers[slotIndex].leftMiddleTip = self.smoothPoint(lh, previous: updatedDancers[slotIndex].leftMiddleTip)
                    }
                    if let rh = bestRightHand {
                        updatedDancers[slotIndex].rightMiddleTip = self.smoothPoint(rh, previous: updatedDancers[slotIndex].rightMiddleTip)
                    }
                }
                }

                // --- CALCULATE OSC VALUES ---
                if self.controlMode == .lockedHand {
                    if self.isHandLocked, let lockedPos = self.lockedHandPosition {
                        // Collect all detected hand tips directly from raw detections
                        var allHands: [CGPoint] = []
                        for hand in detectedHands {
                            allHands.append(hand.tip)
                        }

                        // Find closest hand to locked position
                        var bestHand: CGPoint? = nil
                        var bestDist: CGFloat = self.HAND_MATCH_THRESHOLD
                        for hand in allHands {
                            let dist = hypot(hand.x - lockedPos.x, hand.y - lockedPos.y)
                            if dist < bestDist { bestDist = dist; bestHand = hand }
                        }

                        if let matched = bestHand {
                            self.lockedHandPosition = self.smoothPoint(matched, previous: lockedPos)

                            // Calculate OSC using Active Zone (always)
                            self.updateActiveZoneRect()
                            let origin = CGPoint(x: self.activeZoneRect.midX, y: self.activeZoneRect.midY)
                            let maxD = max(self.activeZoneRect.width / 2, 1)
                            let currentPos = self.lockedHandPosition ?? lockedPos
                            let d = hypot(currentPos.x - origin.x, currentPos.y - origin.y)
                            var raw = Float(min(1.0, d / maxD))
                            if let rampStart = self.relockRampStartValue, let rampTime = self.relockRampStartTime {
                                let elapsed = now - rampTime
                                let progress = min(1.0, elapsed / self.RELOCK_RAMP_DURATION)
                                if progress < 1.0 {
                                    raw = rampStart + (raw - rampStart) * Float(progress)
                                } else {
                                    self.relockRampStartValue = nil
                                    self.relockRampStartTime = nil
                                }
                            }
                            if self.useSmoothing {
                                raw = self.oscSmoothingAlpha * raw + (1 - self.oscSmoothingAlpha) * self.lastLockedHandOSCValue
                            }
                            self.lastLockedHandOSCValue = raw
                        }
                    }
                } else if self.controlMode == .lockedHandVertical {
                    if self.isHandLocked, let lockedPos = self.lockedHandPosition {
                        var allHands: [CGPoint] = []
                        for hand in detectedHands {
                            allHands.append(hand.tip)
                        }

                        var bestHand: CGPoint? = nil
                        var bestDist: CGFloat = self.HAND_MATCH_THRESHOLD
                        for hand in allHands {
                            let dist = hypot(hand.x - lockedPos.x, hand.y - lockedPos.y)
                            if dist < bestDist { bestDist = dist; bestHand = hand }
                        }

                        if let matched = bestHand {
                            self.lockedHandPosition = self.smoothPoint(matched, previous: lockedPos)

                            // Calculate OSC using VERTICAL POSITION within Active Zone
                            self.updateActiveZoneRect()
                            let currentPos = self.lockedHandPosition ?? lockedPos

                            // Y position mapping: bottom of box = 0.0, top of box = 1.0
                            let boxTop = self.activeZoneRect.minY
                            let boxBottom = self.activeZoneRect.maxY
                            let boxHeight = boxBottom - boxTop

                            // Clamp position to box bounds
                            let clampedY = max(boxTop, min(boxBottom, currentPos.y))

                            // Calculate vertical position (inverted: top=1.0, bottom=0.0)
                            var raw = Float(1.0 - (clampedY - boxTop) / boxHeight)
                            raw = max(0, min(1, raw))

                            // Apply relock ramping if active
                            if let rampStart = self.relockRampStartValue, let rampTime = self.relockRampStartTime {
                                let elapsed = now - rampTime
                                let progress = min(1.0, elapsed / self.RELOCK_RAMP_DURATION)
                                if progress < 1.0 {
                                    raw = rampStart + (raw - rampStart) * Float(progress)
                                } else {
                                    self.relockRampStartValue = nil
                                    self.relockRampStartTime = nil
                                }
                            }

                            if self.useSmoothing {
                                raw = self.oscSmoothingAlpha * raw + (1 - self.oscSmoothingAlpha) * self.lastLockedHandOSCValue
                            }
                            self.lastLockedHandOSCValue = raw
                        }
                    }
                }

                self.dancers = updatedDancers

                // --- UPDATE STATUS ---
                if self.isHandLocked {
                    self.lastStatus = String(format: "Hand locked ✓  OSC: %.3f", self.lastLockedHandOSCValue)
                } else if self.dancers.contains(where: { $0.isActive }) {
                    self.lastStatus = "Click hand to lock"
                } else {
                    self.lastStatus = "No pose detected"
                }

                // --- SEND OSC (throttled) ---
                if self.isZoneActive && self.isHandLocked && now - self.lastSendTime >= self.sendInterval {
                    self.lastSendTime = now
                    let address: String
                    if self.controlMode == .lockedHand {
                        address = "\(self.oscPrefix)/Center"
                    } else {
                        address = "\(self.oscPrefix)/TopBottom"
                    }
                    self.oscSender.send(address: address, floats: [self.lastLockedHandOSCValue])
                }
            }
        } catch {
            DispatchQueue.main.async {
                for i in self.dancers.indices {
                    self.dancers[i].isActive = false
                }
                self.lastStatus = "Vision error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Content View (Split-Screen)

struct ContentView: View {
    @ObservedObject var zone1: CameraModel
    @ObservedObject var zone2: CameraModel

    var body: some View {
        HStack(spacing: 0) {
            ZoneView(cam: zone1, otherZoneCameraId: zone2.selectedCameraId)
            Divider()
            ZoneView(cam: zone2, otherZoneCameraId: zone1.selectedCameraId)
        }
        .onAppear { installKeyMonitor() }
    }

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.charactersIgnoringModifiers {
            case "1":
                zone1.unlockHand()
                return nil
            case "2":
                zone2.unlockHand()
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - Zone Controls View

struct ZoneControlsView: View {
    @ObservedObject var cam: CameraModel
    @ObservedObject var cameraManager = CameraManager.shared
    var otherZoneCameraId: String?

    private var isSharedCamera: Bool {
        guard let selected = cam.selectedCameraId, !selected.isEmpty,
              let other = otherZoneCameraId, !other.isEmpty else { return false }
        return selected == other
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $cam.isZoneActive)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

            Text("Zone \(cam.zoneId)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(cam.zoneId == 1 ? .mint : .orange)

            Picker("Camera", selection: Binding(
                get: { cam.selectedCameraId ?? "" },
                set: { cam.selectCamera(deviceId: $0.isEmpty ? nil : $0) }
            )) {
                Text("Auto").tag("")
                ForEach(cameraManager.discoveredDevices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            Picker("Mode", selection: $cam.controlMode) {
                ForEach(CameraModel.ControlMode.allCases, id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Picker("View", selection: $cam.viewMode) {
                ForEach(CameraModel.ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 70)

            statusIndicator

            if isSharedCamera {
                Text("Shared cam")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.yellow.opacity(0.3))
                    .foregroundColor(.yellow)
                    .cornerRadius(4)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.8))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch cam.connectionStatus {
        case .connected:
            Text(cam.connectionStatus.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
        case .connecting:
            Text(cam.connectionStatus.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.yellow)
        case .disconnected:
            Text(cam.connectionStatus.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
        case .noCamera:
            Text(cam.connectionStatus.rawValue)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Zone View

struct ZoneView: View {
    @ObservedObject var cam: CameraModel
    var otherZoneCameraId: String?

    private var zoneColor: Color {
        cam.zoneId == 1 ? .mint : .orange
    }

    var body: some View {
        VStack(spacing: 0) {
            ZoneControlsView(cam: cam, otherZoneCameraId: otherZoneCameraId)

            HStack(spacing: 8) {
                Text("Response:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                Slider(value: $cam.responsiveness, in: 0.2...1.0)
                    .controlSize(.mini)
                Text(String(format: "%.2f", cam.responsiveness))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.8))

            // Active Zone controls
            if cam.controlMode == .lockedHand || cam.controlMode == .lockedHandVertical {
                HStack(spacing: 8) {
                    Toggle("Active Zone:", isOn: $cam.useActiveZone)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Slider(value: $cam.activeZoneSize, in: 0.5...1.0)
                        .controlSize(.mini)
                        .disabled(!cam.useActiveZone)
                    Text(String(format: "%.0f%%", cam.activeZoneSize * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.8))
            }

            // Relock button (only visible in Center/Top-Bottom mode when hand is locked)
            if (cam.controlMode == .lockedHand || cam.controlMode == .lockedHandVertical) && cam.isHandLocked {
                HStack(spacing: 8) {
                    Button("🔓 Relock Hand") {
                        cam.unlockHand()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(.white)
                    .cornerRadius(4)

                    Picker("", selection: $cam.useStrictMatching) {
                        Text("200px").tag(false)
                        Text("100px").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                    .labelsHidden()

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.8))
            }

            GeometryReader { proxy in
                ZStack {
                    CameraView(cam: cam)
                    overlay
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    cam.handleClick(at: value.location)
                                }
                        )

                    // Status overlay
                    VStack {
                        HStack {
                            Text(cam.lastStatus)
                                .font(.system(size: 11))
                                .padding(6)
                                .background(.black.opacity(0.5))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                            Spacer()
                        }
                        Spacer()

                        // OSC address hint at bottom
                        HStack {
                            Text("OSC: \(cam.oscPrefix)/...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(zoneColor.opacity(0.6))
                                .padding(4)
                            Spacer()
                        }
                    }
                    .padding(8)

                    if cam.connectionStatus == .disconnected {
                        VStack(spacing: 8) {
                            Text("Camera Disconnected")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.red)
                            Text("Reconnect the camera or select a new one above")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(16)
                        .background(.black.opacity(0.7))
                        .cornerRadius(8)
                    }

                    if cam.permissionDenied {
                        Text("Camera access denied.\nEnable in System Settings → Privacy & Security → Camera.")
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.black.opacity(0.6))
                            .foregroundColor(.white)
                    }
                }
                .onAppear { cam.setCanvasSize(proxy.size) }
                .onChange(of: proxy.size) { newSize in cam.setCanvasSize(newSize) }
                .opacity(cam.isZoneActive ? 1.0 : 0.5)
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(zoneColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var overlay: some View {
        Canvas { ctx, size in
            // Video area outline
            if cam.videoRect != .zero {
                let path = Path(roundedRect: cam.videoRect, cornerRadius: 2)
                ctx.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 1)
            }

            // Window center
            let c = CGPoint(x: size.width/2, y: size.height/2)
            let centerPath = Path(ellipseIn: CGRect(x: c.x-4, y: c.y-4, width: 8, height: 8))
            ctx.stroke(centerPath, with: .color(.cyan), lineWidth: 2)

            // Active zone rectangle
            if cam.activeZoneRect != .zero {
                let zonePath = Path(cam.activeZoneRect)
                ctx.stroke(zonePath, with: .color(.white), lineWidth: 2)
            }

            // Locked hand marker
            if (cam.controlMode == .lockedHand || cam.controlMode == .lockedHandVertical) && cam.isHandLocked, let pos = cam.lockedHandPosition {
                let lockedPath = Path(ellipseIn: CGRect(x: pos.x - 15, y: pos.y - 15, width: 30, height: 30))
                ctx.stroke(lockedPath, with: .color(.red), lineWidth: 4)
            }

            // Draw each active dancer (skip in Locked Hand mode when locked)
            if !((cam.controlMode == .lockedHand || cam.controlMode == .lockedHandVertical) && cam.isHandLocked) {
            for dancer in cam.dancers where dancer.isActive {
                let color: Color = dancer.dancerId == 1 ? .mint : .orange
                let secondaryColor: Color = dancer.dancerId == 1 ? .green : .red

                // Body joints: shoulders and ankles
                let visibleJoints: [VNHumanBodyPoseObservation.JointName] = [
                    .leftShoulder, .rightShoulder,
                    .leftAnkle, .rightAnkle
                ]
                for (name, p) in dancer.bodyKeypoints where visibleJoints.contains(name) {
                    let jointPath = Path(ellipseIn: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8))
                    ctx.fill(jointPath, with: .color(color.opacity(0.8)))
                }

                // Middle finger tips (bigger circles)
                if let p = dancer.leftMiddleTip {
                    let handPath = Path(ellipseIn: CGRect(x: p.x-12, y: p.y-12, width: 24, height: 24))
                    ctx.stroke(handPath, with: .color(color), lineWidth: 3)
                }
                if let p = dancer.rightMiddleTip {
                    let handPath = Path(ellipseIn: CGRect(x: p.x-12, y: p.y-12, width: 24, height: 24))
                    ctx.stroke(handPath, with: .color(secondaryColor), lineWidth: 3)
                }
            }
            } // end locked hand skip

            // No pose message
            if !cam.dancers.contains(where: { $0.isActive }) {
                ctx.draw(Text("No pose — step into frame")
                    .foregroundColor(.white),
                         at: CGPoint(x: size.width/2, y: size.height*0.1))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Camera View

struct CameraView: NSViewRepresentable {
    let cam: CameraModel
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        DispatchQueue.main.async { cam.start(on: v.layer!) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        cam.setCanvasSize(v.bounds.size)
    }
}
