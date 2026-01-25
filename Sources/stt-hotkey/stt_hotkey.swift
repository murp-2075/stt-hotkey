import AppKit
import AVFoundation
import Carbon
import Foundation

private enum AppState {
    case idle
    case starting
    case recording
    case transcribing
}

private struct HotkeyConfig {
    let keyCode: UInt32
    let modifiers: UInt32
}

private struct Env {
    let values: [String: String]

    static func load(from url: URL) -> Env {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return Env(values: [:])
        }

        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return Env(values: values)
    }

    func value(_ key: String) -> String? {
        values[key]
    }
}

@MainActor
private final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    var onHotkey: (() -> Void)?

    func register(hotkey: HotkeyConfig) -> Bool {
        hotKeyID = EventHotKeyID(signature: fourCharCode("stth"), id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            return false
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotkeyEvent(event)
            return noErr
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, userData, &handlerRef)
        return installStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    nonisolated private func handleHotkeyEvent(_ event: EventRef) {
        var eventID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventID
        )
        guard status == noErr else { return }

        let capturedID = eventID
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard capturedID.signature == self.hotKeyID.signature,
                  capturedID.id == self.hotKeyID.id else { return }
            self.onHotkey?()
        }
    }
}

private final class AudioRecorder: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var didFireStart = false
    private var onFirstBuffer: (() -> Void)?
    private(set) var fileURL: URL?

    func start(onFirstBuffer: @escaping () -> Void) throws -> URL {
        stop()
        didFireStart = false
        self.onFirstBuffer = onFirstBuffer

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-hotkey-\(Int(Date().timeIntervalSince1970)).wav")

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No input channels available."])
        }

        file = try AVAudioFile(forWriting: tempURL, settings: inputFormat.settings)
        fileURL = tempURL

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let file = self.file {
                do {
                    try file.write(from: buffer)
                    if !self.didFireStart {
                        self.didFireStart = true
                        let onFirst = self.onFirstBuffer
                        DispatchQueue.main.async {
                            onFirst?()
                        }
                    }
                } catch {
                    // Ignore write errors; recorder will surface issues on stop/transcribe.
                }
            }
        }

        engine.prepare()
        try engine.start()
        return tempURL
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        onFirstBuffer = nil
        didFireStart = false
    }
}

private final class AudioStreamRecorder: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var didFireStart = false
    private var onFirstBuffer: (() -> Void)?
    private var onAudioData: ((Data) -> Void)?

    func start(onFirstBuffer: @escaping () -> Void, onAudioData: @escaping (Data) -> Void) throws {
        stop()
        didFireStart = false
        self.onFirstBuffer = onFirstBuffer
        self.onAudioData = onAudioData

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioStreamRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No input channels available."])
        }

        self.inputFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            guard let pcmData = self.convertToPCM(buffer) else { return }
            self.onAudioData?(pcmData)
            if !self.didFireStart {
                self.didFireStart = true
                let onFirst = self.onFirstBuffer
                DispatchQueue.main.async {
                    onFirst?()
                }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        inputFormat = nil
        onFirstBuffer = nil
        onAudioData = nil
        didFireStart = false
    }

    private func convertToPCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, let inputFormat else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        final class ConverterState: @unchecked Sendable {
            var didProvideInput = false
            let buffer: AVAudioPCMBuffer

            init(buffer: AVAudioPCMBuffer) {
                self.buffer = buffer
            }
        }

        let state = ConverterState(buffer: buffer)
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return state.buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil || convertedBuffer.frameLength == 0 {
            return nil
        }

        if let channelData = convertedBuffer.int16ChannelData {
            let bytesPerFrame = Int(convertedBuffer.format.streamDescription.pointee.mBytesPerFrame)
            let byteCount = Int(convertedBuffer.frameLength) * bytesPerFrame
            return Data(bytes: channelData.pointee, count: byteCount)
        }

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return nil }
        return Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
    }
}

private final class OpenAITranscriber: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct StreamEvent: Decodable {
        let type: String
        let delta: String?
        let text: String?
    }

    enum TranscriptionError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response."
            case .httpError(_, let body):
                return body.isEmpty ? "HTTP error." : body
            case .noText:
                return "No transcription text received."
            }
        }
    }

    private var dataBuffer = Data()
    private var errorBuffer = Data()
    private var fullText = ""
    private var httpStatus: Int?
    private var completion: ((Result<String, Error>) -> Void)?
    private var onDelta: ((String) -> Void)?
    private var session: URLSession?

    func transcribe(fileURL: URL, apiKey: String, onDelta: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        self.onDelta = onDelta
        self.completion = completion
        self.fullText = ""
        self.dataBuffer.removeAll()
        self.errorBuffer.removeAll()
        self.httpStatus = nil

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        func appendFile(name: String, filename: String, mimeType: String, fileURL: URL) {
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(mimeType)\r\n\r\n")
            body.append(fileData)
            body.append("\r\n")
        }

        appendField(name: "model", value: "gpt-4o-mini-transcribe")
        appendField(name: "stream", value: "true")
        appendField(name: "response_format", value: "json")
        appendFile(name: "file", filename: fileURL.lastPathComponent, mimeType: "audio/wav", fileURL: fileURL)
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.dataTask(with: request)
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let status = httpStatus, status >= 400 {
            errorBuffer.append(data)
            return
        }

        dataBuffer.append(data)
        while let range = dataBuffer.range(of: Data("\n".utf8)) {
            let lineData = dataBuffer.subdata(in: 0..<range.lowerBound)
            dataBuffer.removeSubrange(0..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleLine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let status = httpStatus, status >= 400 {
            let body = String(data: errorBuffer, encoding: .utf8) ?? ""
            finish(with: .failure(TranscriptionError.httpError(status, body)))
            return
        }
        if let error {
            finish(with: .failure(error))
            return
        }

        if !fullText.isEmpty {
            finish(with: .success(fullText))
        } else {
            finish(with: .failure(TranscriptionError.noText))
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return }
        let payload = String(trimmed.dropFirst(6))
        if payload == "[DONE]" {
            finish(with: .success(fullText))
            return
        }
        guard let payloadData = payload.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: payloadData) else { return }

        if event.type == "transcript.text.delta", let delta = event.delta {
            fullText += delta
            DispatchQueue.main.async { [weak self] in
                self?.onDelta?(delta)
            }
        } else if event.type == "transcript.text.done", let text = event.text {
            fullText = text
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let completion = completion else { return }
        self.completion = nil
        self.onDelta = nil

        DispatchQueue.main.async { [weak self] in
            completion(result)
            self?.session?.invalidateAndCancel()
            self?.session = nil
        }
    }
}

private final class OpenAIRealtimeTranscriber: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum RealtimeError: LocalizedError {
        case connectionClosed
        case serverError(String)
        case transcriptionFailed(String)
        case noText

        var errorDescription: String? {
            switch self {
            case .connectionClosed:
                return "Realtime connection closed."
            case .serverError(let message):
                return message
            case .transcriptionFailed(let message):
                return message
            case .noText:
                return "No transcription text received."
            }
        }
    }

    private let stateQueue = DispatchQueue(label: "stt-hotkey.realtime.state")
    private var session: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var isConfigured = false
    private var pendingAudio: [Data] = []
    private var pendingClear = false
    private var pendingCommit = false
    private var isAcceptingAudio = false
    private var currentItemID: String?
    private var fullText = ""
    private var onDelta: ((String) -> Void)?
    private var completion: ((Result<String, Error>) -> Void)?
    private var didFinish = false

    private let realtimeModel: String
    private let transcriptionModel: String

    init(realtimeModel: String = "gpt-realtime-mini", transcriptionModel: String = "gpt-4o-mini-transcribe") {
        self.realtimeModel = realtimeModel
        self.transcriptionModel = transcriptionModel
        super.init()
    }

    func start(apiKey: String, onDelta: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        self.onDelta = onDelta
        self.completion = completion
        fullText = ""
        currentItemID = nil
        isConfigured = false
        pendingAudio.removeAll()
        pendingClear = false
        pendingCommit = false
        isAcceptingAudio = false

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(realtimeModel)") else {
            finish(with: .failure(RealtimeError.serverError("Invalid realtime URL.")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.webSocket = task
        task.resume()
        receiveLoop()
    }

    func beginInput() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.fullText = ""
            self.currentItemID = nil
            self.isAcceptingAudio = true
            if self.isConfigured {
                self.sendClear()
            } else {
                self.pendingClear = true
            }
        }
    }

    func sendAudio(_ data: Data) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.isAcceptingAudio else { return }
            if self.isConfigured {
                self.sendAudioAppend(data)
            } else {
                self.pendingAudio.append(data)
            }
        }
    }

    func commit() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isAcceptingAudio = false
            if self.isConfigured {
                self.sendCommit()
            } else {
                self.pendingCommit = true
            }
        }
    }

    func cancel() {
        finish(with: .failure(RealtimeError.connectionClosed))
    }

    func shutdown() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.didFinish else { return }
            self.didFinish = true
            self.completion = nil
            self.onDelta = nil
            DispatchQueue.main.async { [weak self] in
                self?.webSocket?.cancel(with: .goingAway, reason: nil)
                self?.session?.invalidateAndCancel()
                self?.webSocket = nil
                self?.session = nil
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        sendSessionUpdate()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(with: .failure(RealtimeError.connectionClosed))
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(with: .failure(error))
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleServerEvent(data)
                    }
                case .data(let data):
                    self.handleServerEvent(data)
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func sendSessionUpdate() {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "transcription": [
                            "model": transcriptionModel
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        sendEvent(payload)
    }

    private func handleServerEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "session.updated":
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.isConfigured = true
                if self.pendingClear {
                    self.sendClear()
                    self.pendingClear = false
                }
                if !self.pendingAudio.isEmpty {
                    let queued = self.pendingAudio
                    self.pendingAudio.removeAll()
                    queued.forEach { self.sendAudioAppend($0) }
                }
                if self.pendingCommit {
                    self.sendCommit()
                    self.pendingCommit = false
                }
            }
        case "input_audio_buffer.committed":
            if let itemID = object["item_id"] as? String {
                stateQueue.async { [weak self] in
                    self?.currentItemID = itemID
                }
            }
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = object["item_id"] as? String,
                  let delta = object["delta"] as? String else { return }
            stateQueue.async { [weak self] in
                guard let self else { return }
                if self.currentItemID == nil {
                    self.currentItemID = itemID
                }
                guard self.currentItemID == itemID else { return }
                self.fullText += delta
                DispatchQueue.main.async { [weak self] in
                    self?.onDelta?(delta)
                }
            }
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = object["item_id"] as? String else { return }
            let transcript = object["transcript"] as? String
            stateQueue.async { [weak self] in
                guard let self else { return }
                if self.currentItemID == nil {
                    self.currentItemID = itemID
                }
                guard self.currentItemID == itemID else { return }
                if let transcript, !transcript.isEmpty {
                    self.fullText = transcript
                }
                let resultText = self.fullText
                if resultText.isEmpty {
                    self.finish(with: .failure(RealtimeError.noText))
                } else {
                    self.finish(with: .success(resultText))
                }
            }
        case "conversation.item.input_audio_transcription.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "Transcription failed."
            finish(with: .failure(RealtimeError.transcriptionFailed(message)))
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "Realtime API error."
            finish(with: .failure(RealtimeError.serverError(message)))
        default:
            break
        }
    }

    private func sendAudioAppend(_ data: Data) {
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        sendEvent(payload)
    }

    private func sendClear() {
        sendEvent(["type": "input_audio_buffer.clear"])
    }

    private func sendCommit() {
        sendEvent(["type": "input_audio_buffer.commit"])
    }

    private func sendEvent(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { [weak self] error in
            if let error {
                self?.finish(with: .failure(error))
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.didFinish else { return }
            self.didFinish = true

            let completion = self.completion
            self.completion = nil
            self.onDelta = nil

            DispatchQueue.main.async { [weak self] in
                completion?(result)
                self?.webSocket?.cancel(with: .normalClosure, reason: nil)
                self?.session?.invalidateAndCancel()
                self?.webSocket = nil
                self?.session = nil
            }
        }
    }
}

@MainActor
final class AppMain: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotkeyManager = HotkeyManager()
    private let fileRecorder = AudioRecorder()
    private let streamRecorder = AudioStreamRecorder()
    private var streamTranscriber: OpenAIRealtimeTranscriber?

    private var env = Env(values: [:])
    private var apiKey: String?
    private var useRealtimeTranscription = false
    private var startSound: NSSound?
    private var state: AppState = .idle {
        didSet { updateStatusIcon() }
    }
    private var startAttempt = 0
    private var blinkTimer: Timer?
    private var blinkRemaining = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupEnv()
        if env.value("SHOW_DOCK_ICON") == "1" {
            NSApplication.shared.setActivationPolicy(.regular)
        } else {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("stt-hotkey: launched")
        cleanupStaleTempFiles()
        setupStatusItem()
        setupStartSound()
        setupHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        streamTranscriber?.shutdown()
    }

    private func setupEnv() {
        guard let execURL = Bundle.main.executableURL else { return }
        let envURL = execURL.deletingLastPathComponent().appendingPathComponent(".env")
        if FileManager.default.fileExists(atPath: envURL.path) {
            env = Env.load(from: envURL)
        } else {
            let cwdEnvURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
            env = Env.load(from: cwdEnvURL)
        }
        apiKey = env.value("OPENAI_API_KEY")
        let realtimeFlag = env.value("REALTIME_TRANSCRIPTION")
            ?? env.value("Realtime_Transcription")
            ?? env.value("Realtime Transcription")
        useRealtimeTranscription = parseBoolFlag(realtimeFlag)
        log("stt-hotkey: realtime transcription \(useRealtimeTranscription ? "enabled" : "disabled")")
    }

    private func cleanupStaleTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries where url.lastPathComponent.hasPrefix("stt-hotkey-") && url.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: url)
        }
        log("stt-hotkey: cleaned temp wav files")
    }

    private func setupStatusItem() {
        let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Idle")
        image?.isTemplate = true
        statusItem.button?.image = image
        if statusItem.button?.image == nil {
            statusItem.button?.title = "STT"
        }
        statusItem.isVisible = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Recording", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupHotkey() {
        let defaultHotkey = HotkeyConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        let config = parseHotkey(from: env.value("HOTKEY")) ?? defaultHotkey
        hotkeyManager.onHotkey = { [weak self] in
            self?.toggleRecording()
        }
        let ok = hotkeyManager.register(hotkey: config)
        if !ok {
            log("stt-hotkey: failed to register hotkey")
            showAlert(title: "Hotkey Error", message: "Failed to register global hotkey.")
        } else {
            log("stt-hotkey: hotkey registered")
        }
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle:
            requestMicPermissionAndStart()
        case .starting:
            cancelPendingStart()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            NSSound.beep()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func requestMicPermissionAndStart() {
        guard apiKey?.isEmpty == false else {
            showAlert(title: "Missing API Key", message: "Set OPENAI_API_KEY in the .env next to the executable.")
            return
        }

        startAttempt += 1
        let attempt = startAttempt
        state = .starting

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard attempt == self.startAttempt, self.state == .starting else { return }
                if granted {
                    self.startRecording()
                } else {
                    log("stt-hotkey: microphone permission denied")
                    self.showAlert(title: "Microphone Permission", message: "Microphone access is required to record audio.")
                    self.state = .idle
                }
            }
        }
    }

    private func cancelPendingStart() {
        startAttempt += 1
        state = .idle
    }

    private func startRecording() {
        guard let apiKey else {
            showAlert(title: "Missing API Key", message: "Set OPENAI_API_KEY in the .env next to the executable.")
            state = .idle
            return
        }

        if useRealtimeTranscription {
            log("stt-hotkey: mode = realtime")
            startRealtimeRecording(apiKey: apiKey)
        } else {
            log("stt-hotkey: mode = legacy")
            startLegacyRecording()
        }
    }

    private func stopRecordingAndTranscribe() {
        if useRealtimeTranscription {
            stopRealtimeRecordingAndTranscribe()
        } else {
            stopLegacyRecordingAndTranscribe()
        }
    }

    private func startRealtimeRecording(apiKey: String) {
        let transcriber = OpenAIRealtimeTranscriber()
        streamTranscriber = transcriber
        transcriber.start(apiKey: apiKey, onDelta: { _ in
            // No UI updates needed for deltas yet.
        }, completion: { [weak self] result in
            guard let self else { return }
            self.streamRecorder.stop()
            self.streamTranscriber = nil
            self.state = .idle
            switch result {
            case .success(let text):
                log("stt-hotkey: transcription success")
                self.copyToClipboard(text)
                self.playDing()
                self.blinkIcon()
            case .failure(let error):
                log("stt-hotkey: transcription error - \(error.localizedDescription)")
                self.showAlert(title: "Transcription Error", message: error.localizedDescription)
            }
        })
        transcriber.beginInput()

        do {
            try streamRecorder.start(onFirstBuffer: { [weak self] in
                self?.playRecordingStartDing()
            }, onAudioData: { [weak self] data in
                self?.streamTranscriber?.sendAudio(data)
            })
            state = .recording
            log("stt-hotkey: recording started (realtime)")
        } catch {
            log("stt-hotkey: recording error - \(error.localizedDescription)")
            showAlert(title: "Recording Error", message: error.localizedDescription)
            transcriber.shutdown()
            streamTranscriber = nil
            state = .idle
        }
    }

    private func stopRealtimeRecordingAndTranscribe() {
        streamRecorder.stop()
        log("stt-hotkey: recording stopped (realtime)")
        state = .transcribing

        guard let transcriber = streamTranscriber else {
            showAlert(title: "Transcription Error", message: "Realtime transcription session not available.")
            state = .idle
            return
        }

        transcriber.commit()
    }

    private func startLegacyRecording() {
        do {
            _ = try fileRecorder.start(onFirstBuffer: { [weak self] in
                self?.playRecordingStartDing()
            })
            state = .recording
            log("stt-hotkey: recording started (legacy)")
        } catch {
            log("stt-hotkey: recording error - \(error.localizedDescription)")
            showAlert(title: "Recording Error", message: error.localizedDescription)
            state = .idle
        }
    }

    private func stopLegacyRecordingAndTranscribe() {
        fileRecorder.stop()
        log("stt-hotkey: recording stopped (legacy)")
        guard let fileURL = fileRecorder.fileURL else {
            showAlert(title: "Recording Error", message: "No recording file found.")
            state = .idle
            return
        }

        state = .transcribing

        guard let apiKey else {
            showAlert(title: "Missing API Key", message: "Set OPENAI_API_KEY in the .env next to the executable.")
            state = .idle
            return
        }

        let transcriber = OpenAITranscriber()
        transcriber.transcribe(fileURL: fileURL, apiKey: apiKey, onDelta: { _ in
            // No UI updates needed for deltas yet.
        }, completion: { [weak self] result in
            guard let self else { return }
            self.state = .idle
            switch result {
            case .success(let text):
                log("stt-hotkey: transcription success")
                self.copyToClipboard(text)
                self.playDing()
                self.blinkIcon()
            case .failure(let error):
                log("stt-hotkey: transcription error - \(error.localizedDescription)")
                self.showAlert(title: "Transcription Error", message: error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: fileURL)
        })
    }

    private func updateStatusIcon() {
        switch state {
        case .idle:
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Idle")
        case .starting:
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Starting")
        case .recording:
            statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        case .transcribing:
            statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribing")
        }
        statusItem.button?.image?.isTemplate = true
    }

    private func blinkIcon() {
        blinkTimer?.invalidate()
        let normalImage = NSImage(systemSymbolName: "mic", accessibilityDescription: "Idle")
        let doneImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        normalImage?.isTemplate = true
        doneImage?.isTemplate = true

        blinkRemaining = 6
        blinkTimer = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(handleBlinkTimer(_:)), userInfo: ["normal": normalImage as Any, "done": doneImage as Any], repeats: true)
    }

    @objc private func handleBlinkTimer(_ timer: Timer) {
        guard blinkRemaining > 0 else {
            timer.invalidate()
            updateStatusIcon()
            return
        }

        blinkRemaining -= 1
        let info = timer.userInfo as? [String: Any]
        let normalImage = info?["normal"] as? NSImage
        let doneImage = info?["done"] as? NSImage
        if blinkRemaining % 2 == 0 {
            statusItem.button?.image = doneImage
        } else {
            statusItem.button?.image = normalImage
        }
    }

    private func playDing() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func setupStartSound() {
        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        startSound = NSSound(contentsOf: soundURL, byReference: true) ?? NSSound(named: NSSound.Name("Ping"))
        if startSound == nil {
            log("stt-hotkey: failed to load start sound")
        }
    }

    private func playRecordingStartDing() {
        if let sound = startSound, sound.play() {
        } else {
            NSSound.beep()
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func parseBoolFlag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        return ["1", "true", "yes", "y", "on"].contains(normalized)
    }

    private func parseHotkey(from raw: String?) -> HotkeyConfig? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.lowercased().split(separator: "+").map { String($0) }
        guard !parts.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            case "alt", "option":
                modifiers |= UInt32(optionKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            default:
                key = part
            }
        }

        guard let key else { return nil }
        let keyCodeMap: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A),
            "b": UInt32(kVK_ANSI_B),
            "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E),
            "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G),
            "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J),
            "k": UInt32(kVK_ANSI_K),
            "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M),
            "n": UInt32(kVK_ANSI_N),
            "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q),
            "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S),
            "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V),
            "w": UInt32(kVK_ANSI_W),
            "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y),
            "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0),
            "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4),
            "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6),
            "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9)
        ]

        guard let keyCode = keyCodeMap[key] else { return nil }
        return HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppMain()
        app.delegate = delegate
        app.run()
    }
}

private func log(_ message: String) {
    NSLog("%@", message)
}

private func fourCharCode(_ string: String) -> OSType {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + UInt32(scalar.value)
    }
    return result
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
