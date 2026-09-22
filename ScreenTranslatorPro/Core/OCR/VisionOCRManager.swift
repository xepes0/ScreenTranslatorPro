import Foundation
import Vision
import UIKit

final class VisionOCRManager {
    func recognize(image: UIImage) async throws -> [OCRResult] {
        guard let cgImage = image.cgImage else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let results = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { item -> OCRResult? in
                    guard let text = item.topCandidates(1).first?.string else { return nil }
                    return OCRResult(text: text, boundingBox: item.boundingBox)
                }

                continuation.resume(returning: results)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
