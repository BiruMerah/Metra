import Foundation

/// Copies only actually recognized Paddle Unicode glyphs into an aligned Vision
/// line. All prose, digits, spacing and source boxes stay from Vision. Differences
/// outside the supported confusion set veto the whole line; nothing is inferred.
enum PaddleMathSymbolSelector {
    static let version="paddle_unicode_symbol_selection_v3"
    static let minimumSymbolProbability:Float=0.70
    struct Change:Codable,Sendable {
        let visionRangeUTF16:[Int]
        let visionGlyph:String
        let paddleRangeUTF16:[Int]
        let paddleGlyph:String
        let paddleProbability:Float
    }
    struct Decision:Codable,Sendable {
        let version:String
        let accepted:Bool
        let selectedText:String
        let changes:[Change]
        let reason:String
    }
    private struct Token {
        let text:String
        let range:[Int]
        let probability:Float
    }
    static func select(vision:String,paddle:PaddleCTCResult) -> Decision {
        func declined(_ reason:String) -> Decision { Decision(version:version,accepted:false,selectedText:vision,changes:[],reason:reason) }
        let old=vision.indices.compactMap { index -> Token? in
            let character=vision[index],end=vision.index(after:index)
            return character.isWhitespace ? nil : Token(text:String(character),range:[index.utf16Offset(in:vision),end.utf16Offset(in:vision)],probability:0)
        }
        let new=paddle.glyphs.flatMap { glyph -> [Token] in
            glyph.text.indices.compactMap { index in
                let c=glyph.text[index],end=glyph.text.index(after:index)
                return c.isWhitespace ? nil : Token(text:String(c),range:[glyph.rangeUTF16[0]+index.utf16Offset(in:glyph.text),glyph.rangeUTF16[0]+end.utf16Offset(in:glyph.text)],probability:glyph.confidence)
            }
        }
        guard !old.isEmpty,old.count==new.count else { return declined("Non-whitespace character count differs; keep Vision") }
        let confusions:[String:Set<String>]=["∠":["L","Z"],"°":["o","O","0","º","'","’","′"],"²":["2","r","г","'","’","′","?"],"³":["3","r","г","'","’","′","?"]]
        var changes:[Change]=[],deferredSymbols=0
        for i in old.indices {
            if folded(old[i].text)==folded(new[i].text) { continue }
            // Existing choice marker homoglyph handling stays in its own context.
            if i==0,old.count>1,[".",")"].contains(old[1].text),
               ["А":"A","В":"B","С":"C"][old[i].text]==new[i].text { continue }
            guard confusions[new[i].text]?.contains(old[i].text)==true,
                  old[i].range[1]-old[i].range[0]==new[i].text.utf16.count else { return declined("A non-symbol/prose/numeric change was recognized; keep Vision") }
            // Threshold each aligned symbol independently. A weak second angle
            // does not discard an otherwise eligible first angle. Prose/digit
            // conflicts still veto the entire line above.
            guard new[i].probability>=minimumSymbolProbability else { deferredSymbols+=1;continue }
            changes.append(Change(visionRangeUTF16:old[i].range,visionGlyph:old[i].text,paddleRangeUTF16:new[i].range,
                paddleGlyph:new[i].text,paddleProbability:new[i].probability))
        }
        guard !changes.isEmpty else { return declined(deferredSymbols>0 ? "Unicode symbols below recorded operating threshold; keep Vision" : "No supported new Unicode glyph") }
        let selected=NSMutableString(string:vision)
        for change in changes.reversed() { selected.replaceCharacters(in:NSRange(location:change.visionRangeUTF16[0],length:change.visionRangeUTF16[1]-change.visionRangeUTF16[0]),with:change.paddleGlyph) }
        let text=selected as String,spans=UnicodeMathSource.spans(in:text)
        guard changes.allSatisfy({ change in spans.contains { $0.lower<=change.visionRangeUTF16[0] && $0.upper>=change.visionRangeUTF16[1] } }) else {
            return declined("Unicode glyph is not inside a supported complete math notation; keep Vision")
        }
        return Decision(version:version,accepted:true,selectedText:text,changes:changes,
            reason:"Copy explicit Paddle glyphs at aligned source positions only; \(deferredSymbols) below-threshold symbols left as Vision. Original Vision candidates, spacing and boxes retained. Image/formula fidelity still requires UniMERNet/source review.")
    }
    private static func folded(_ text:String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF01...0xFF5E).contains(scalar.value) ? UnicodeScalar(scalar.value-0xFEE0)! : scalar
        }))
    }
}
