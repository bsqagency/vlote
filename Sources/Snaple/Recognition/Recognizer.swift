import Foundation
import Vision

/// On-device text and barcode recognition (Vision). Nothing leaves the machine.
enum Recognizer {
    static func text(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    cont.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func barcodes(in image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    cont.resume(returning: (request.results ?? []).compactMap { $0.payloadStringValue })
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
