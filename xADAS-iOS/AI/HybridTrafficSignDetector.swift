import CoreGraphics
import CoreVideo
import Foundation

/// Traffic-sign pipeline designed for a moving vehicle:
/// 1) run a permissive full-frame detector to find *any* traffic-sign candidate,
/// 2) associate the physical sign with a persistent track ID using geometry,
/// 3) crop a dynamic ROI around the tracked sign from the ORIGINAL frame,
/// 4) run VN82 again on the enlarged ROI,
/// 5) fuse classification evidence across time before publishing a sign.
///
/// This intentionally separates "where is a sign?" from "which sign is it?" so a
/// distant speed sign can be tracked even while its number is still ambiguous.
final class HybridTrafficSignDetector {
    private let directDetector: VNTrafficSign82Detector?
    private let fallback = TrafficSignDetector()

    private struct Track {
        let id: Int
        var box: CGRect                  // Vision normalized coordinates (origin bottom-left)
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var observations: Int
        var votes: [TrafficSignKind: Float]
        var hits: [TrafficSignKind: Int]
        var bestConfidence: [TrafficSignKind: Float]
        var confirmedKind: TrafficSignKind?
    }

    private var tracks: [Track] = []
    private var nextTrackID = 1

    private let trackLifetime: TimeInterval = 1.10
    private let fullFrameThreshold: Float = 0.12
    private let refineThreshold: Float = 0.11
    private let maxFullFrameCandidates = 10
    private let maxRefinementsPerFrame = 2

    var modeLabel: String {
        directDetector == nil ? "SIGN AI • OCR FALLBACK" : "SIGN AI • VN82 TRACK+ROI"
    }

    init() {
        directDetector = try? VNTrafficSign82Detector()
    }

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        guard let directDetector else {
            return try fallback.detect(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        pruneTracks(now: timestamp)

        // Stage 1: detect traffic-sign-shaped objects across the full image. Keep
        // unmapped VN82 classes too: a far-away LIMIT 60 may initially be classified
        // as the wrong traffic-sign class, but its physical box is still valuable.
        let raw = try directDetector.detect(
            pixelBuffer: pixelBuffer,
            confidenceThreshold: fullFrameThreshold
        )
        let fullFrameCandidates = raw
            .filter(isPlausibleSignCandidate)
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxFullFrameCandidates)

        var touchedTrackIDs = Set<Int>()
        var candidateTrackPairs: [(VN82Detection, Int)] = []

        for detection in fullFrameCandidates {
            if let index = bestTrackIndex(for: detection.boundingBox, excluding: touchedTrackIDs) {
                let id = tracks[index].id
                updateGeometry(trackIndex: index, with: detection.boundingBox, timestamp: timestamp)
                addClassVote(trackIndex: index, classID: detection.classID, confidence: detection.confidence, weight: 0.65)
                touchedTrackIDs.insert(id)
                candidateTrackPairs.append((detection, id))
            } else {
                let id = nextTrackID
                nextTrackID += 1
                var track = Track(
                    id: id,
                    box: detection.boundingBox,
                    firstSeen: timestamp,
                    lastSeen: timestamp,
                    observations: 1,
                    votes: [:],
                    hits: [:],
                    bestConfidence: [:],
                    confirmedKind: nil
                )
                if let kind = trafficSignKind(forClassID: detection.classID) {
                    track.votes[kind] = detection.confidence * 0.65
                    track.hits[kind] = 1
                    track.bestConfidence[kind] = detection.confidence
                }
                tracks.append(track)
                touchedTrackIDs.insert(id)
                candidateTrackPairs.append((detection, id))
            }
        }

        // Stage 2: spend expensive high-resolution recognition only on the strongest
        // tracked candidates. The crop is made from the original frame, not from the
        // already-resized 640x640 detector input.
        let refinementTargets = candidateTrackPairs
            .sorted { $0.0.confidence > $1.0.confidence }
            .prefix(maxRefinementsPerFrame)

        for (_, trackID) in refinementTargets {
            guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
            let roi = dynamicTopLeftROI(aroundVisionBox: tracks[index].box)
            let refined = try directDetector.detect(
                pixelBuffer: pixelBuffer,
                normalizedCropTopLeft: roi,
                confidenceThreshold: refineThreshold
            )

            // Only mapped classes are semantic evidence. Geometry came from the
            // full-frame stage; the ROI stage exists to distinguish values like 60/80.
            let mappedRefined = refined.compactMap { detection -> (TrafficSignKind, Float)? in
                guard let kind = trafficSignKind(forClassID: detection.classID) else { return nil }
                return (kind, detection.confidence)
            }

            if let best = mappedRefined.max(by: { $0.1 < $1.1 }) {
                addVote(trackIndex: index, kind: best.0, confidence: best.1, weight: 1.45)
            }
        }

        // Stage 3: publish only stable semantic decisions. The downstream state
        // tracker sees confidence >= 0.98 only after this physical-sign track has
        // accumulated enough consistent evidence, so one bad 60/80 frame cannot flip it.
        var outputs: [TrafficSignObservation] = []
        for index in tracks.indices where touchedTrackIDs.contains(tracks[index].id) {
            if let confirmed = stableKind(forTrackAt: index) {
                tracks[index].confirmedKind = confirmed
                let best = tracks[index].bestConfidence[confirmed] ?? 0.5
                outputs.append(TrafficSignObservation(
                    kind: confirmed,
                    confidence: max(0.985, best),
                    timestamp: timestamp
                ))
            }
        }

        // If several physical tracks show the same semantic sign, retain the strongest
        // publication only; different signs may still coexist in the same frame.
        var bestByKind: [TrafficSignKind: TrafficSignObservation] = [:]
        for observation in outputs {
            if bestByKind[observation.kind]?.confidence ?? 0 < observation.confidence {
                bestByKind[observation.kind] = observation
            }
        }
        return Array(bestByKind.values)
    }

    private func isPlausibleSignCandidate(_ detection: VN82Detection) -> Bool {
        let box = detection.boundingBox
        guard box.width >= 0.003,
              box.height >= 0.003,
              box.width <= 0.30,
              box.height <= 0.30 else { return false }
        let aspect = box.width / max(box.height, 0.0001)
        return aspect >= 0.35 && aspect <= 2.8
    }

    private func bestTrackIndex(for box: CGRect, excluding usedIDs: Set<Int>) -> Int? {
        var bestIndex: Int?
        var bestScore: CGFloat = -1

        for index in tracks.indices where !usedIDs.contains(tracks[index].id) {
            let existing = tracks[index].box
            let overlap = iou(existing, box)
            let dx = existing.midX - box.midX
            let dy = existing.midY - box.midY
            let centerDistance = sqrt(dx * dx + dy * dy)
            let scale = max(existing.width, existing.height, box.width, box.height)
            let adaptiveDistance = max(0.055, scale * 2.8)

            guard overlap >= 0.08 || centerDistance <= adaptiveDistance else { continue }
            let distanceScore = max(0, 0.35 - centerDistance)
            let sizeSimilarity = 1.0 - min(1.0, abs(existing.width - box.width) + abs(existing.height - box.height))
            let score = overlap * 1.8 + distanceScore + sizeSimilarity * 0.15
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func updateGeometry(trackIndex: Int, with newBox: CGRect, timestamp: TimeInterval) {
        let old = tracks[trackIndex].box
        let alpha: CGFloat = 0.58
        tracks[trackIndex].box = CGRect(
            x: old.minX * (1 - alpha) + newBox.minX * alpha,
            y: old.minY * (1 - alpha) + newBox.minY * alpha,
            width: old.width * (1 - alpha) + newBox.width * alpha,
            height: old.height * (1 - alpha) + newBox.height * alpha
        )
        tracks[trackIndex].lastSeen = timestamp
        tracks[trackIndex].observations += 1
    }

    private func addClassVote(trackIndex: Int, classID: Int, confidence: Float, weight: Float) {
        guard let kind = trafficSignKind(forClassID: classID) else { return }
        addVote(trackIndex: trackIndex, kind: kind, confidence: confidence, weight: weight)
    }

    private func addVote(trackIndex: Int, kind: TrafficSignKind, confidence: Float, weight: Float) {
        let contribution = max(0, confidence) * weight
        tracks[trackIndex].votes[kind, default: 0] += contribution
        tracks[trackIndex].hits[kind, default: 0] += 1
        tracks[trackIndex].bestConfidence[kind] = max(
            tracks[trackIndex].bestConfidence[kind] ?? 0,
            confidence
        )

        // Slowly decay competing semantic votes so old ambiguity does not remain
        // forever after the tracked crop becomes clear.
        for key in Array(tracks[trackIndex].votes.keys) where key != kind {
            tracks[trackIndex].votes[key] = (tracks[trackIndex].votes[key] ?? 0) * 0.90
        }
    }

    private func stableKind(forTrackAt index: Int) -> TrafficSignKind? {
        let track = tracks[index]
        guard track.observations >= 2, !track.votes.isEmpty else { return nil }

        let ranked = track.votes.sorted { $0.value > $1.value }
        guard let first = ranked.first else { return nil }
        let winner = first.key
        let winnerScore = first.value
        let runnerUpScore = ranked.dropFirst().first?.value ?? 0
        let winnerHits = track.hits[winner] ?? 0
        let dominance = winnerScore / max(0.12, runnerUpScore)

        let changingExisting = track.confirmedKind.map { $0 != winner } ?? false
        let requiredHits = changingExisting ? 4 : 3
        let requiredScore: Float = changingExisting ? 1.70 : 1.05
        let requiredDominance: Float = changingExisting ? 2.10 : 1.45

        guard winnerHits >= requiredHits,
              winnerScore >= requiredScore,
              dominance >= requiredDominance else {
            return track.confirmedKind
        }
        return winner
    }

    /// Converts Vision's bottom-left box to a top-left crop and expands it heavily.
    /// The minimum 24% crop satisfies the current ONNX crop preparation contract;
    /// for a tiny distant sign this still gives roughly 4x the effective model pixels.
    private func dynamicTopLeftROI(aroundVisionBox box: CGRect) -> CGRect {
        let centerX = box.midX
        let centerYTop = 1.0 - box.midY
        let objectSide = max(box.width, box.height)
        let side = min(0.56, max(0.24, objectSide * 4.5))

        var x = centerX - side / 2
        var y = centerYTop - side / 2
        x = min(max(x, 0), 1 - side)
        y = min(max(y, 0), 1 - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    private func pruneTracks(now: TimeInterval) {
        tracks.removeAll { now - $0.lastSeen > trackLifetime }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    private func trafficSignKind(forClassID id: Int) -> TrafficSignKind? {
        switch id {
        case 57: return .speedLimit(10)
        case 61: return .speedLimit(20)
        case 62: return .speedLimit(30)
        case 2: return .speedLimit(40)
        case 39: return .speedLimit(50)
        case 12: return .speedLimit(60)
        case 40: return .speedLimit(70)
        case 41: return .speedLimit(80)
        case 63: return .speedLimit(90)
        case 58: return .speedLimit(100)
        case 59: return .speedLimit(110)
        case 60: return .speedLimit(120)
        case 79: return .denseAreaStart
        case 80: return .denseAreaEnd
        default: return nil
        }
    }
}
