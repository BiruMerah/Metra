import Foundation

struct PaddleOCRGlyph: Codable, Sendable {
    let text: String
    let confidence: Float
    let rangeUTF16: [Int]
    let timestep: Int
    var endTimestep: Int
}

struct PaddleCTCResult: Codable, Sendable {
    let text: String
    let confidence: Float
    let glyphs: [PaddleOCRGlyph]
}

enum PaddleOCRCTC {
    /// Official CTC rule: remove repeated adjacent IDs, then blank 0. A blank
    /// separates genuine repeated characters. Confidence uses each selected step.
    static func decode(indices:[Int],scores:[Float],dictionary:[String],blankID:Int = 0) throws -> PaddleCTCResult {
        guard indices.count == scores.count,!dictionary.isEmpty else { throw PaddleOCRError.invalid("CTC trace shape mismatch") }
        var glyphs:[PaddleOCRGlyph] = [],text = "",previous = -1
        for i in indices.indices {
            let id=indices[i],score=scores[i]
            guard dictionary.indices.contains(id),score.isFinite,score>=0,score<=1.0001 else { throw PaddleOCRError.invalid("Invalid CTC class or probability") }
            if id != blankID,id != previous {
                let value=dictionary[id],start=text.utf16.count
                text += value
                glyphs.append(PaddleOCRGlyph(text:value,confidence:score,rangeUTF16:[start,text.utf16.count],timestep:i,endTimestep:i+1))
            } else if id != blankID,!glyphs.isEmpty { glyphs[glyphs.count-1].endTimestep=i+1 }
            previous=id
        }
        let confidence=glyphs.isEmpty ? 0 : glyphs.map(\.confidence).reduce(0,+)/Float(glyphs.count)
        return PaddleCTCResult(text:text,confidence:confidence,glyphs:glyphs)
    }
}

enum PaddleOCRError: LocalizedError {
    case invalid(String)
    var errorDescription:String? { switch self { case .invalid(let message):return "PaddleOCR: \(message)" } }
}
