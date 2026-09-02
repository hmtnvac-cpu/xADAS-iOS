import AVFoundation
import CoreMedia
import Foundation
import Network
import UIKit
import VideoToolbox

final class RootlessRTSPPlayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private let frameProcessor: FrameProcessor
    private let statusHandler: (String) -> Void
    private var client: RTSPH264Client?
    private lazy var decoder = H264VideoDecoder { [weak self] pixelBuffer in
        guard let self else { return }
        self.frameProcessor.process(pixelBuffer: pixelBuffer)
        self.enqueue(pixelBuffer: pixelBuffer)
    }

    init(frameProcessor: FrameProcessor, statusHandler: @escaping (String) -> Void) {
        self.frameProcessor = frameProcessor
        self.statusHandler = statusHandler
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { nil }

    func start(urlString: String) {
        stop()
        statusHandler("70MAI CONNECTING • NATIVE RTSP")
        guard let url = URL(string: urlString) else {
            statusHandler("70MAI URL INVALID")
            return
        }

        let client = RTSPH264Client(
            url: url,
            statusHandler: statusHandler,
            parameterSetHandler: { [weak self] sps, pps in
                self?.decoder.setParameterSets(sps: sps, pps: pps)
            },
            accessUnitHandler: { [weak self] nals in
                self?.decoder.decode(accessUnit: nals)
            }
        )
        self.client = client
        client.start()
    }

    func stop() {
        client?.stop()
        client = nil
        decoder.reset()
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.flushAndRemoveImage()
        }
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sampleBuffer)
        }
    }
}

private enum RTSPTransportMode {
    case udp
    case tcp
}

private final class RTSPH264Client {
    private let url: URL
    private let queue = DispatchQueue(label: "xadas.rtsp.native")
    private let statusHandler: (String) -> Void
    private let parameterSetHandler: (Data, Data) -> Void
    private let accessUnitHandler: ([Data]) -> Void

    private var connection: NWConnection?
    private var udpRTPConnection: NWConnection?
    private var receiveBuffer = Data()
    private var cseq = 1
    private var pendingResponse: ((Int, [String: String], Data) -> Void)?
    private var sessionID: String?
    private var playTarget: String?
    private var setupTarget: String?
    private var stopped = false
    private var receivedFirstRTP = false
    private var transportMode: RTSPTransportMode = .udp
    private var rtpWatchdog: DispatchWorkItem?
    private let rtpPort = NWEndpoint.Port(rawValue: 50_000)!
    private let rtcpPort = NWEndpoint.Port(rawValue: 50_001)!

    private var currentTimestamp: UInt32?
    private var accessUnit: [Data] = []
    private var fragmentedNAL: Data?
    private var latestSPS: Data?
    private var latestPPS: Data?

    init(
        url: URL,
        statusHandler: @escaping (String) -> Void,
        parameterSetHandler: @escaping (Data, Data) -> Void,
        accessUnitHandler: @escaping ([Data]) -> Void
    ) {
        self.url = url
        self.statusHandler = statusHandler
        self.parameterSetHandler = parameterSetHandler
        self.accessUnitHandler = accessUnitHandler
    }

    func start() {
        stopped = false
        transportMode = .udp
        connectRTSP()
    }

    private func connectRTSP() {
        guard !stopped,
              let hostName = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
            report("70MAI URL INVALID")
            return
        }

        resetNetworkState()
        let connection = NWConnection(host: .init(hostName), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.report("70MAI RTSP CONNECTED • \(self.transportMode == .udp ? "UDP" : "TCP")")
                self.receiveLoop()
                self.describe()
            case .failed(let error):
                self.report("70MAI RTSP ERROR • \(error.localizedDescription)")
            case .waiting(let error):
                self.report("70MAI WAITING • \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func resetNetworkState() {
        rtpWatchdog?.cancel()
        rtpWatchdog = nil
        connection?.cancel()
        connection = nil
        udpRTPConnection?.cancel()
        udpRTPConnection = nil
        receiveBuffer.removeAll()
        pendingResponse = nil
        sessionID = nil
        playTarget = nil
        setupTarget = nil
        cseq = 1
        receivedFirstRTP = false
        currentTimestamp = nil
        accessUnit.removeAll()
        fragmentedNAL = nil
    }

    private func retryUsingTCP() {
        guard !stopped, transportMode == .udp else { return }
        report("70MAI UDP NO RTP • TRYING TCP")
        transportMode = .tcp
        connectRTSP()
    }

    func stop() {
        stopped = true
        rtpWatchdog?.cancel()
        rtpWatchdog = nil
        connection?.cancel()
        connection = nil
        udpRTPConnection?.cancel()
        udpRTPConnection = nil
        receiveBuffer.removeAll()
        pendingResponse = nil
        sessionID = nil
        playTarget = nil
        setupTarget = nil
        receivedFirstRTP = false
        currentTimestamp = nil
        accessUnit.removeAll()
        fragmentedNAL = nil
        latestSPS = nil
        latestPPS = nil
    }

    private func startUDPReceiver(serverPort: NWEndpoint.Port, completion: @escaping () -> Void) {
        guard let hostName = url.host else {
            report("70MAI UDP HOST INVALID")
            return
        }

        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("0.0.0.0")!),
            port: rtpPort
        )
        let udp = NWConnection(host: .init(hostName), port: serverPort, using: parameters)
        udpRTPConnection = udp
        udp.stateUpdateHandler = { [weak self, weak udp] state in
            guard let self, let udp, !self.stopped else { return }
            switch state {
            case .ready:
                self.report("70MAI RTP/UDP READY")
                self.receiveUDP(on: udp)
                completion()
            case .failed(let error):
                self.report("70MAI UDP ERROR • \(error.localizedDescription)")
            case .waiting(let error):
                self.report("70MAI UDP WAITING • \(error.localizedDescription)")
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.consumeRTP(data)
            }
            if let error {
                self.report("70MAI UDP RECEIVE ERROR • \(error.localizedDescription)")
                return
            }
            self.receiveUDP(on: connection)
        }
    }

    private func describe() {
        sendRequest(method: "DESCRIBE", target: url.absoluteString, headers: ["Accept": "application/sdp"]) { [weak self] code, headers, body in
            guard let self else { return }
            guard code == 200 else {
                self.report("70MAI DESCRIBE FAILED • \(code)")
                return
            }
            guard let sdp = String(data: body, encoding: .utf8) else {
                self.report("70MAI SDP INVALID")
                return
            }

            // 70mai/live555 returns the aggregate control URI in Content-Base.
            // PLAY must use that URI (usually with a trailing slash), not the
            // original DESCRIBE URI. VLC does this automatically.
            let contentBase = headers["content-base"]
                ?? headers["content-location"]
                ?? self.directoryURL(self.url.absoluteString)
            guard let trackURL = self.videoTrackURL(from: sdp, baseURL: contentBase) else {
                self.report("70MAI SDP VIDEO NOT FOUND")
                return
            }

            self.playTarget = self.presentationURL(from: sdp, baseURL: contentBase)
            self.setupTarget = trackURL
            self.readSDPParameterSets(sdp)
            self.setup(trackURL: trackURL)
        }
    }

    private func setup(trackURL: String) {
        let transport = transportMode == .udp
            ? "RTP/AVP;unicast;client_port=\(rtpPort.rawValue)-\(rtcpPort.rawValue)"
            : "RTP/AVP/TCP;unicast;interleaved=0-1"
        sendRequest(
            method: "SETUP",
            target: trackURL,
            headers: ["Transport": transport]
        ) { [weak self] code, headers, _ in
            guard let self else { return }
            guard code == 200 else {
                self.report("70MAI SETUP FAILED • \(code)")
                return
            }
            if let raw = headers["session"] {
                self.sessionID = raw.split(separator: ";", maxSplits: 1).first.map(String.init)
            }
            let negotiated = headers["transport"] ?? ""
            if self.transportMode == .tcp {
                self.report("70MAI SETUP OK • TCP")
                self.play()
                return
            }
            guard let serverPort = self.serverRTPPort(from: negotiated) else {
                self.report("70MAI UDP PORT MISSING • TRYING TCP")
                self.retryUsingTCP()
                return
            }
            self.report("70MAI SETUP OK • UDP")
            self.startUDPReceiver(serverPort: serverPort) { [weak self] in
                self?.play()
            }
        }
    }

    private func serverRTPPort(from transport: String) -> NWEndpoint.Port? {
        guard let range = transport.range(of: "server_port=", options: .caseInsensitive) else { return nil }
        let tail = transport[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        guard let value = UInt16(digits) else { return nil }
        return NWEndpoint.Port(rawValue: value)
    }

    private func play() {
        let target = playTarget ?? directoryURL(url.absoluteString)
        sendPlay(target: target, allowTrackFallback: true)
    }

    private func sendPlay(target: String, allowTrackFallback: Bool) {
        var headers = ["Range": "npt=0.000-"]
        if let sessionID { headers["Session"] = sessionID }

        sendRequest(method: "PLAY", target: target, headers: headers) { [weak self] code, _, _ in
            guard let self else { return }
            if code == 200 {
                self.report("70MAI PLAYING • WAITING RTP • \(self.transportMode == .udp ? "UDP" : "TCP")")
                self.startRTPWatchdog()
                return
            }

            // Some 70mai firmware accepts aggregate PLAY; other builds only
            // accept PLAY on the exact video track URI returned by SDP.
            if code == 404,
               allowTrackFallback,
               let setupTarget = self.setupTarget,
               setupTarget != target {
                self.report("70MAI PLAY RETRY • TRACK URI")
                self.sendPlay(target: setupTarget, allowTrackFallback: false)
                return
            }
            self.report("70MAI PLAY FAILED • \(code)")
        }
    }

    private func startRTPWatchdog() {
        rtpWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.receivedFirstRTP else { return }
            if self.transportMode == .udp {
                self.retryUsingTCP()
            } else {
                self.report("70MAI NO RTP • TCP")
            }
        }
        rtpWatchdog = item
        queue.asyncAfter(deadline: .now() + 4.0, execute: item)
    }

    private func sendRequest(
        method: String,
        target: String,
        headers: [String: String],
        completion: @escaping (Int, [String: String], Data) -> Void
    ) {
        guard let connection, !stopped else { return }
        var lines = [
            "\(method) \(target) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: xADAS-iOS/native-rtsp"
        ]
        cseq += 1
        for (key, value) in headers { lines.append("\(key): \(value)") }
        lines.append("")
        lines.append("")
        pendingResponse = completion
        let data = lines.joined(separator: "\r\n").data(using: .utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.report("70MAI SEND ERROR • \(error.localizedDescription)") }
        })
    }

    private func receiveLoop() {
        guard let connection, !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeBuffer()
            }
            if let error {
                self.report("70MAI RECEIVE ERROR • \(error.localizedDescription)")
                return
            }
            if !complete { self.receiveLoop() }
        }
    }

    private func consumeBuffer() {
        while !receiveBuffer.isEmpty {
            if receiveBuffer.first == 0x24 {
                guard receiveBuffer.count >= 4 else { return }
                let channel = receiveBuffer[1]
                let length = (Int(receiveBuffer[2]) << 8) | Int(receiveBuffer[3])
                guard receiveBuffer.count >= 4 + length else { return }
                let packet = Data(receiveBuffer[4..<(4 + length)])
                receiveBuffer.removeSubrange(0..<(4 + length))
                if channel == 0 { consumeRTP(packet) }
                continue
            }

            guard let headerRange = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerEnd = headerRange.upperBound
            guard let text = String(data: receiveBuffer[..<headerEnd], encoding: .utf8) else {
                receiveBuffer.removeAll()
                return
            }
            let headers = parseHeaders(text)
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            guard receiveBuffer.count >= headerEnd + contentLength else { return }
            let body = Data(receiveBuffer[headerEnd..<(headerEnd + contentLength)])
            receiveBuffer.removeSubrange(0..<(headerEnd + contentLength))

            let code = text.components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            let completion = pendingResponse
            pendingResponse = nil
            completion?(code, headers, body)
        }
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
        return result
    }

    private func videoTrackURL(from sdp: String, baseURL: String) -> String? {
        var inVideo = false
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video") }
            guard inVideo, line.hasPrefix("a=control:") else { continue }
            let control = String(line.dropFirst("a=control:".count))
            return resolveControlURL(control, baseURL: baseURL)
        }
        return nil
    }

    private func presentationURL(from sdp: String, baseURL: String) -> String {
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { break }
            guard line.hasPrefix("a=control:") else { continue }
            let control = String(line.dropFirst("a=control:".count))
            if control == "*" { return directoryURL(baseURL) }
            return resolveControlURL(control, baseURL: baseURL)
        }
        return directoryURL(baseURL)
    }

    private func resolveControlURL(_ control: String, baseURL: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") { return control }
        let base = directoryURL(baseURL)
        return URL(string: control, relativeTo: URL(string: base))?.absoluteString ?? base + control
    }

    private func directoryURL(_ value: String) -> String {
        value.hasSuffix("/") ? value : value + "/"
    }

    private func readSDPParameterSets(_ sdp: String) {
        guard let range = sdp.range(of: "sprop-parameter-sets=") else { return }
        let tail = sdp[range.upperBound...]
        let value = tail.prefix { $0 != ";" && $0 != "\r" && $0 != "\n" }
        let parts = value.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let sps = Data(base64Encoded: String(parts[0])),
              let pps = Data(base64Encoded: String(parts[1])) else { return }
        latestSPS = sps
        latestPPS = pps
        parameterSetHandler(sps, pps)
    }

    private func consumeRTP(_ packet: Data) {
        guard packet.count >= 12 else { return }
        if !receivedFirstRTP {
            receivedFirstRTP = true
            rtpWatchdog?.cancel()
            rtpWatchdog = nil
            report("70MAI RTP RECEIVING • \(transportMode == .udp ? "UDP" : "TCP")")
        }
        let first = packet[0]
        let second = packet[1]
        let cc = Int(first & 0x0F)
        let hasExtension = (first & 0x10) != 0
        let marker = (second & 0x80) != 0
        let timestamp = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7])

        var offset = 12 + cc * 4
        guard packet.count >= offset else { return }
        if hasExtension {
            guard packet.count >= offset + 4 else { return }
            let words = (Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])
            offset += 4 + words * 4
            guard packet.count >= offset else { return }
        }
        guard offset < packet.count else { return }

        if currentTimestamp != nil, currentTimestamp != timestamp, !accessUnit.isEmpty { flushAccessUnit() }
        currentTimestamp = timestamp

        let payload = Data(packet[offset...])
        guard let firstPayload = payload.first else { return }
        switch firstPayload & 0x1F {
        case 1...23: appendNAL(payload)
        case 24: consumeSTAPA(payload)
        case 28: consumeFUA(payload)
        default: break
        }
        if marker { flushAccessUnit() }
    }

    private func appendNAL(_ nal: Data) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7:
            latestSPS = nal
            if let latestPPS { parameterSetHandler(nal, latestPPS) }
        case 8:
            latestPPS = nal
            if let latestSPS { parameterSetHandler(latestSPS, nal) }
        default:
            break
        }
        accessUnit.append(nal)
    }

    private func consumeSTAPA(_ payload: Data) {
        var offset = 1
        while offset + 2 <= payload.count {
            let length = (Int(payload[offset]) << 8) | Int(payload[offset + 1])
            offset += 2
            guard length > 0, offset + length <= payload.count else { return }
            appendNAL(Data(payload[offset..<(offset + length)]))
            offset += length
        }
    }

    private func consumeFUA(_ payload: Data) {
        guard payload.count >= 2 else { return }
        let indicator = payload[0]
        let header = payload[1]
        let start = (header & 0x80) != 0
        let end = (header & 0x40) != 0
        let reconstructed = (indicator & 0xE0) | (header & 0x1F)
        if start {
            fragmentedNAL = Data([reconstructed])
            fragmentedNAL?.append(payload.dropFirst(2))
        } else {
            fragmentedNAL?.append(payload.dropFirst(2))
        }
        if end, let nal = fragmentedNAL {
            fragmentedNAL = nil
            appendNAL(nal)
        }
    }

    private func flushAccessUnit() {
        guard !accessUnit.isEmpty else { currentTimestamp = nil; return }
        let nals = accessUnit
        accessUnit.removeAll(keepingCapacity: true)
        currentTimestamp = nil
        accessUnitHandler(nals)
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [statusHandler] in statusHandler(text) }
    }
}

private final class H264VideoDecoder {
    private let queue = DispatchQueue(label: "xadas.h264.decoder")
    private let output: (CVPixelBuffer) -> Void
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init(output: @escaping (CVPixelBuffer) -> Void) { self.output = output }

    func setParameterSets(sps: Data, pps: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.sps == sps, self.pps == pps, self.session != nil { return }
            self.sps = sps
            self.pps = pps
            self.rebuildSession()
        }
    }

    func decode(accessUnit: [Data]) {
        queue.async { [weak self] in self?.decodeOnQueue(accessUnit) }
    }

    func reset() {
        queue.sync {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            formatDescription = nil
            sps = nil
            pps = nil
        }
    }

    private func decodeOnQueue(_ accessUnit: [Data]) {
        for nal in accessUnit where !nal.isEmpty {
            switch nal[0] & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }
        if session == nil, sps != nil, pps != nil { rebuildSession() }
        guard let session, let formatDescription else { return }

        let videoNALs = accessUnit.filter {
            guard let first = $0.first else { return false }
            let type = first & 0x1F
            return type == 1 || type == 5
        }
        guard !videoNALs.isEmpty else { return }

        var sampleData = Data()
        for nal in videoNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copyStatus = sampleData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleData.count)
        }
        guard copyStatus == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleData.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        var flagsOut = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    private func rebuildSession() {
        guard let sps, let pps else { return }
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let videoDescription = description else { return }
        formatDescription = videoDescription

        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let refCon, let imageBuffer else { return }
                let decoder = Unmanaged<H264VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.output(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: videoDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr else { return }
        session = newSession
    }
}
