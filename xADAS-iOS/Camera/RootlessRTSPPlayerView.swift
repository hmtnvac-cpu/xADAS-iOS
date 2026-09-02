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

    required init?(coder: NSCoder) {
        nil
    }

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

private final class RTSPH264Client {
    private let url: URL
    private let queue = DispatchQueue(label: "xadas.rtsp.native")
    private let statusHandler: (String) -> Void
    private let parameterSetHandler: (Data, Data) -> Void
    private let accessUnitHandler: ([Data]) -> Void

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var cseq = 1
    private var pendingResponse: ((Int, [String: String], Data) -> Void)?
    private var sessionID: String?
    private var playing = false
    private var stopped = false

    private var currentTimestamp: UInt32?
    private var accessUnit: [Data] = []
    private var fragmentedNAL: Data?

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
        guard let hostName = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
            report("70MAI URL INVALID")
            return
        }

        let connection = NWConnection(host: .init(hostName), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.report("70MAI RTSP CONNECTED")
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

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        pendingResponse = nil
        playing = false
        currentTimestamp = nil
        accessUnit.removeAll(keepingCapacity: false)
        fragmentedNAL = nil
    }

    private func describe() {
        sendRequest(
            method: "DESCRIBE",
            target: url.absoluteString,
            headers: ["Accept": "application/sdp"]
        ) { [weak self] code, headers, body in
            guard let self, code == 200 else {
                self?.report("70MAI DESCRIBE FAILED")
                return
            }
            guard let sdp = String(data: body, encoding: .utf8),
                  let trackURL = self.videoTrackURL(from: sdp) else {
                self.report("70MAI SDP VIDEO NOT FOUND")
                return
            }
            self.readSDPParameterSets(sdp)
            self.setup(trackURL: trackURL)
        }
    }

    private func setup(trackURL: String) {
        sendRequest(
            method: "SETUP",
            target: trackURL,
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
        ) { [weak self] code, headers, _ in
            guard let self, code == 200 else {
                self?.report("70MAI SETUP TCP FAILED")
                return
            }
            if let rawSession = headers["session"] {
                self.sessionID = rawSession.split(separator: ";", maxSplits: 1).first.map(String.init)
            }
            self.play()
        }
    }

    private func play() {
        var headers: [String: String] = [:]
        if let sessionID { headers["Session"] = sessionID }
        sendRequest(method: "PLAY", target: url.absoluteString, headers: headers) { [weak self] code, _, _ in
            guard let self, code == 200 else {
                self?.report("70MAI PLAY FAILED")
                return
            }
            self.playing = true
            self.report("70MAI PLAYING • NATIVE RTSP")
        }
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
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        let request = lines.joined(separator: "\r\n")
        pendingResponse = completion
        connection.send(content: request.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.report("70MAI RTSP SEND ERROR • \(error.localizedDescription)")
            }
        })
    }

    private func receiveLoop() {
        guard let connection, !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeBuffer()
            }
            if let error {
                self.report("70MAI RTSP RECEIVE ERROR • \(error.localizedDescription)")
                return
            }
            if !isComplete {
                self.receiveLoop()
            }
        }
    }

    private func consumeBuffer() {
        while !receiveBuffer.isEmpty {
            if receiveBuffer.first == 0x24 {
                guard receiveBuffer.count >= 4 else { return }
                let channel = receiveBuffer[1]
                let length = (Int(receiveBuffer[2]) << 8) | Int(receiveBuffer[3])
                guard receiveBuffer.count >= 4 + length else { return }
                let payload = Data(receiveBuffer[4..<(4 + length)])
                receiveBuffer.removeSubrange(0..<(4 + length))
                if channel == 0 {
                    consumeRTP(payload)
                }
                continue
            }

            guard let headerRange = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerEnd = headerRange.upperBound
            guard let headerText = String(data: receiveBuffer[..<headerEnd], encoding: .utf8) else {
                receiveBuffer.removeAll()
                return
            }
            let contentLength = parseHeaders(headerText)["content-length"].flatMap(Int.init) ?? 0
            guard receiveBuffer.count >= headerEnd + contentLength else { return }
            let body = Data(receiveBuffer[headerEnd..<(headerEnd + contentLength)])
            receiveBuffer.removeSubrange(0..<(headerEnd + contentLength))

            let lines = headerText.components(separatedBy: "\r\n")
            let statusCode = lines.first?
                .split(separator: " ")
                .dropFirst()
                .first
                .flatMap { Int($0) } ?? 0
            let headers = parseHeaders(headerText)
            let completion = pendingResponse
            pendingResponse = nil
            completion?(statusCode, headers, body)
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

    private func videoTrackURL(from sdp: String) -> String? {
        var inVideo = false
        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
            }
            guard inVideo, line.hasPrefix("a=control:") else { continue }
            let control = String(line.dropFirst("a=control:".count))
            if control.lowercased().hasPrefix("rtsp://") {
                return control
            }
            let base = url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
            return URL(string: control, relativeTo: URL(string: base))?.absoluteString ?? base + control
        }
        return nil
    }

    private func readSDPParameterSets(_ sdp: String) {
        guard let range = sdp.range(of: "sprop-parameter-sets=") else { return }
        let tail = sdp[range.upperBound...]
        let value = tail.prefix { $0 != ";" && $0 != "\r" && $0 != "\n" }
        let parts = value.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let sps = Data(base64Encoded: String(parts[0])),
              let pps = Data(base64Encoded: String(parts[1])) else { return }
        parameterSetHandler(sps, pps)
    }

    private func consumeRTP(_ packet: Data) {
        guard packet.count >= 12 else { return }
        let first = packet[0]
        let second = packet[1]
        let cc = Int(first & 0x0F)
        let hasExtension = (first & 0x10) != 0
        let marker = (second & 0x80) != 0
        let timestamp = UInt32(packet[4]) << 24 |
            UInt32(packet[5]) << 16 |
            UInt32(packet[6]) << 8 |
            UInt32(packet[7])

        var offset = 12 + cc * 4
        guard packet.count >= offset else { return }
        if hasExtension {
            guard packet.count >= offset + 4 else { return }
            let words = (Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])
            offset += 4 + words * 4
            guard packet.count >= offset else { return }
        }
        guard offset < packet.count else { return }

        if currentTimestamp != nil, currentTimestamp != timestamp, !accessUnit.isEmpty {
            flushAccessUnit()
        }
        currentTimestamp = timestamp

        let payload = Data(packet[offset...])
        guard let firstPayload = payload.first else { return }
        let nalType = firstPayload & 0x1F

        switch nalType {
        case 1...23:
            appendNAL(payload)
        case 24:
            consumeSTAPA(payload)
        case 28:
            consumeFUA(payload)
        default:
            break
        }

        if marker {
            flushAccessUnit()
        }
    }

    private func appendNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let type = nal[0] & 0x1F
        if type == 7 {
            if let pps = accessUnit.first(where: { !$0.isEmpty && ($0[0] & 0x1F) == 8 }) {
                parameterSetHandler(nal, pps)
            }
        } else if type == 8 {
            if let sps = accessUnit.first(where: { !$0.isEmpty && ($0[0] & 0x1F) == 7 }) {
                parameterSetHandler(sps, nal)
            }
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
        guard !accessUnit.isEmpty else {
            currentTimestamp = nil
            return
        }
        let nals = accessUnit
        accessUnit.removeAll(keepingCapacity: true)
        currentTimestamp = nil
        accessUnitHandler(nals)
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [statusHandler] in
            statusHandler(text)
        }
    }
}

private final class H264VideoDecoder {
    private let queue = DispatchQueue(label: "xadas.h264.decoder")
    private let output: (CVPixelBuffer) -> Void
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init(output: @escaping (CVPixelBuffer) -> Void) {
        self.output = output
    }

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
        queue.async { [weak self] in
            self?.decodeOnQueue(accessUnit)
        }
    }

    func reset() {
        queue.sync {
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
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
        if session == nil, sps != nil, pps != nil {
            rebuildSession()
        }
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

        let copyStatus = sampleData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

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
        guard status == noErr, let videoDescription = description as? CMVideoFormatDescription else { return }
        formatDescription = videoDescription

        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr,
                      let refCon,
                      let imageBuffer else { return }
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
