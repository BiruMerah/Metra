import Foundation
import ImageIO
import UIKit

actor HeavyInferenceGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

struct FormulaPageResult: Sendable {
    let formulas: [FormulaRegion]
    let components: [ComponentResult]
}

@MainActor
final class FormulaPipeline {
    private let runtime = UniMERNetRuntime()
    private var mathJax: MathJaxBridge?
    var onProgress: ((String)->Void)?

    private static func compactNumericWhitespace(_ latex:String) -> String {
        var text=latex
        for pattern in [#"(?<=[0-9])[ \t\r\n]+(?=[0-9.,])"#,#"(?<=[.,])[ \t\r\n]+(?=[0-9])"#] {
            if let regex=try? NSRegularExpression(pattern:pattern) { text=regex.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"") }
        }
        return text
    }

    func process(pageID: String, regions: [LayoutRegion], observations: [OCRObservation], pageRoot: URL, gate: HeavyInferenceGate) async -> FormulaPageResult {
        var formulas = LayoutMerge.formulas(pageID: pageID, regions: regions, observations: observations)
        var stageResults: [ComponentResult] = []
        guard !formulas.isEmpty else { return FormulaPageResult(formulas: [], components: ["unimernet","mathjax","mathcat"].map { ComponentResult(component:$0,status:"skipped_no_input",errorCode:nil,message:"Tidak ada region formula pada halaman.",rawArtifact:nil,metrics:[:]) }) }
        await gate.acquire()
        for index in formulas.indices {
            let formulaID = formulas[index].id
            onProgress?("\(pageID): formula \(index+1)/\(formulas.count), UniMERNet → MathJax → MathCAT...")
            let directory = pageRoot.appendingPathComponent("formulas/\(formulaID)", isDirectory: true)
            let artifactPrefix = "pages/\(pageID)/formulas/\(formulaID)"
            var stages: [ComponentResult] = []
            var currentStage = "unimernet"
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if regions.first(where: { $0.id == formulas[index].layoutRegionID })?.detectionSource == Pix2TextMFDRuntime.proposalVersion {
                    stages.append(ComponentResult(component:"mfd_crop_provenance",status:"succeeded",errorCode:nil,
                        message:"Recognition crop selected by supplemental MFD merge; raw detector and Vision crops retained",
                        rawArtifact:"pages/\(pageID)/mfd-crop-merge.json",metrics:[:]))
                }
                if let region=regions.first(where: { $0.id == formulas[index].layoutRegionID }),
                   ["vision_visual_numeric_proposal_v2","vision_degree_literal_proposal_v1"].contains(region.detectionSource ?? ""),
                   let text=region.proposalText, let literal=VisualNumericLiteral.parse(text) {
                    let observation=observations.first { $0.id == region.sourceObservationID }
                    let decision = region.detectionSource == "vision_degree_literal_proposal_v1" ?
                        VisualNumericMergeDecision(version:"explicit_ocr_degree_literal_v1",allowed:true,
                            reason:"Exact OCR number and explicit degree glyph; speech normalization only; OCR photo accuracy unassessed",evidenceArtifact:"\(artifactPrefix)/vision-literal.json") : observation?.numericEvidence?.mergeDecision(selectedLiteral: literal) ??
                        VisualNumericMergeDecision(version:"numeric_corroboration_merge_v2",allowed:false,
                            reason:"Numeric OCR corroboration unavailable; speech withheld",evidenceArtifact:"")
                    let allowed = decision.allowed
                    formulas[index].route=["apple_vision_numeric_label","literal_numeric_mathml_v1","mathcat_id"]
                    formulas[index].recognitionArtifact="\(artifactPrefix)/vision-literal.json"
                    // This is explicitly derived TeX for consumers; no model LaTeX
                    // generation or MathJax parsing is claimed on this route.
                    formulas[index].latex=literal.number + ((literal.unit == "°" || literal.unit == "º") ? "^{\\circ}" : (literal.unit == "%" ? "\\%" : ""))
                    formulas[index].mathML=literal.mathML
                    formulas[index].derivations=["Parse literal Vision numeric label into presentation MathML; no numerical change; º maps to degree operator; MathCAT owns speech; raw and OCR agreement retained"]
                    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                    try encoder.encode(literal).write(to:directory.appendingPathComponent("vision-literal.json"),options:.atomic)
                    try encoder.encode(decision).write(to:directory.appendingPathComponent("numeric-merge-decision.json"),options:.atomic)
                    stages.append(ComponentResult(component:"vision_numeric_corroboration",status:allowed ? "succeeded" : "needs_review",
                        errorCode:allowed ? nil : "numeric_evidence_requires_review",message:decision.reason,
                        rawArtifact:"\(artifactPrefix)/numeric-merge-decision.json",metrics:[:]))
                    try literal.mathML.write(to:directory.appendingPathComponent("mathml.xml"),atomically:true,encoding:.utf8)
                    stages.append(ComponentResult(component:"vision_numeric_mathml",status:"succeeded",errorCode:nil,message:observation?.numericEvidence?.reason,
                        rawArtifact:"\(artifactPrefix)/vision-literal.json",metrics:[:]))
                    for name in ["unimernet","mathjax"] { stages.append(ComponentResult(component:name,status:"skipped_by_route",errorCode:nil,message:"Literal numeric Vision → MathML route; no inference/parsing call",rawArtifact:nil,metrics:[:])) }
                    currentStage="mathcat"
                    let spoken=try await MathCATAdapter.shared.speak(mathML:literal.mathML)
                    formulas[index].spokenText=spoken.spokenText
                    formulas[index].canonicalMathML=spoken.canonicalMathML
                    formulas[index].mathCATProfile=spoken.profile
                    formulas[index].status="spoken_generated"
                    formulas[index].errorCode=nil
                    formulas[index].spokenMergeAllowed=allowed
                    formulas[index].sourceConsistencyStatus=allowed ? "consistent_literal_ocr_readings" : "needs_review"
                    formulas[index].sourceConsistencyMessage=decision.reason
                    try encoder.encode(spoken).write(to:directory.appendingPathComponent("mathcat.raw.json"),options:.atomic)
                    stages.append(ComponentResult(component:"mathcat",status:"succeeded",errorCode:nil,message:spoken.version,rawArtifact:"\(artifactPrefix)/mathcat.raw.json",metrics:["inference_ms":spoken.milliseconds]))
                    formulas[index].stageResults=stages
                    stageResults += stages
                    try encoder.encode(formulas[index]).write(to:directory.appendingPathComponent("formula-result.json"),options:.atomic)
                    continue
                }
                guard let cropPath = formulas[index].cropArtifact else { throw FormulaRecognitionError.failed("Crop reference hilang") }
                var cropURL = pageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(cropPath)
                // A tall formula region can overlap a separately detected prose line at its top.
                // Preserve the original crop, and record the derived recognition ROI explicitly.
                let box=formulas[index].bboxPageXYXY
                let textBands=regions.filter { region in
                    let t=region.bboxPageXYXY
                    return region.label=="text" && t.ymin<=box.ymin+0.05*(box.ymax-box.ymin) && t.ymax>box.ymin && t.ymax<box.ymin+0.3*(box.ymax-box.ymin) && min(t.xmax,box.xmax)-max(t.xmin,box.xmin)>0.8*(box.xmax-box.xmin)
                }
                if let bottom=textBands.map({$0.bboxPageXYXY.ymax}).max() {
                    let trimmed=PixelBox(xmin:box.xmin,ymin:ceil(bottom)+1,xmax:box.xmax,ymax:box.ymax)
                    let supportedLines=observations.filter { trimmed.intersection($0.bboxPageXYXY)/max(1,$0.bboxPageXYXY.area)>0.8 }.count
                    if supportedLines>=2,let source=CGImageSourceCreateWithURL(pageRoot.appendingPathComponent("normalized.png") as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),let crop=image.cropping(to:CGRect(x:trimmed.xmin,y:trimmed.ymin,width:trimmed.xmax-trimmed.xmin,height:trimmed.ymax-trimmed.ymin)),let png=UIImage(cgImage:crop).pngData() {
                        cropURL=directory.appendingPathComponent("recognition-crop.png")
                        try png.write(to:cropURL,options:.atomic)
                        formulas[index].recognitionBBoxPageXYXY=trimmed
                        formulas[index].recognitionCropArtifact="\(artifactPrefix)/recognition-crop.png"
                        formulas[index].derivations=["Exclude top strip occupied by separately detected text region(s) \(textBands.map(\.id).joined(separator:",")); retain original detection/crop; source review required"]
                    }
                }
                let recognized = try await runtime.recognize(cropURL: cropURL, formulaID: formulaID, artifacts: directory)
                formulas[index].latex = recognized.latexRaw
                formulas[index].recognitionArtifact = "\(artifactPrefix)/unimernet.raw.json"
                stages.append(ComponentResult(component:"unimernet",status:recognized.eosReached ? "succeeded" : "needs_review",errorCode:recognized.eosReached ? nil : recognized.stopReason,message:nil,rawArtifact:"\(artifactPrefix)/unimernet.raw.json",metrics:recognized.metrics.mapValues { Optional($0) }))
                guard recognized.eosReached, !recognized.latexRaw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw FormulaRecognitionError.failed("Generation tidak mencapai EOS atau LaTeX kosong: \(recognized.stopReason)") }
                currentStage = "mathjax"
                if mathJax == nil { mathJax = MathJaxBridge() }
                let compacted=Self.compactNumericWhitespace(recognized.latexRaw)
                formulas[index].latexForMathJax=compacted
                if compacted != recognized.latexRaw {
                    formulas[index].derivations=(formulas[index].derivations ?? [])+["Compact ASCII whitespace between numeric characters for MathJax token grouping; raw LaTeX retained; no separator replacement"]
                    let log:[String:String]=["operation":"tex_numeric_whitespace_compaction_v1","input":recognized.latexRaw,"output":compacted]
                    try JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("latex-transport-derivation.json"),options:.atomic)
                }
                let parsed = try await mathJax!.convert(latex:compacted,formulaID:formulaID)
                formulas[index].mathML = parsed.mathML
                try parsed.mathML.write(to:directory.appendingPathComponent("mathml.xml"),atomically:true,encoding:.utf8)
                stages.append(ComponentResult(component:"mathjax",status:parsed.hasMathErrorNode ? "failed" : "succeeded",errorCode:parsed.hasMathErrorNode ? "mathml_merror" : nil,message:parsed.parseError,rawArtifact:"\(artifactPrefix)/mathml.xml",metrics:["parse_ms":parsed.parseMilliseconds]))
                guard !parsed.hasMathErrorNode else { throw MathJaxBridgeError.parseFailed(parsed.parseError ?? "merror") }
                currentStage = "mathcat"
                let rawSpoken = try await MathCATAdapter.shared.speak(mathML:parsed.mathML)
                var spoken = rawSpoken
                let rawEncoder = JSONEncoder(); rawEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try rawEncoder.encode(rawSpoken).write(to: directory.appendingPathComponent("mathcat.raw.json"), options: .atomic)
                stages.append(ComponentResult(component:"mathcat",status:"succeeded",errorCode:nil,message:"\(rawSpoken.version); raw image MathML speech retained separately from unit normalization",rawArtifact:"\(artifactPrefix)/mathcat.raw.json",metrics:["inference_ms":rawSpoken.milliseconds]))
                formulas[index].spokenText = spoken.spokenText
                formulas[index].canonicalMathML = spoken.canonicalMathML
                formulas[index].mathCATProfile = spoken.profile
                formulas[index].status = "spoken_generated"
                formulas[index].errorCode = nil
                let sourceRegion = regions.first { $0.id == formulas[index].layoutRegionID }
                let target = formulas[index].recognitionBBoxPageXYXY ?? formulas[index].bboxPageXYXY
                let containedOCR = observations.filter { target.intersection($0.bboxPageXYXY)/max(1,$0.bboxPageXYXY.area) >= 0.8 }
                    .sorted { $0.rawOrder < $1.rawOrder }.map(\.selectedText).joined(separator:"\n")
                let structureSource = sourceRegion?.proposalText ?? containedOCR
                if sourceRegion?.detectionSource == "vision_degree_expression_proposal_v1" {
                    let recognizedTokens = MathMLSourceTree.read(parsed.mathML).map { MathMLSourceTree.compact($0.tokens) }
                    let expectedTokens = MathMLSourceTree.compact(structureSource)
                    let allowed = recognizedTokens == expectedTokens
                    formulas[index].spokenMergeAllowed = allowed
                    formulas[index].sourceConsistencyStatus = allowed ? "complete_degree_expression_agrees" : "needs_review"
                    formulas[index].sourceConsistencyMessage = "Complete parentheses, digits, operators and degree must agree; extra or missing tokens are withheld"
                    try rawEncoder.encode(["source":structureSource,"image_tokens":recognizedTokens ?? "","allowed":String(allowed)])
                        .write(to:directory.appendingPathComponent("degree-expression-consistency.json"),options:.atomic)
                    stages.append(ComponentResult(component:"formula_degree_expression_consistency",status:allowed ? "succeeded" : "needs_review",
                        errorCode:allowed ? nil : "complete_degree_expression_mismatch",message:formulas[index].sourceConsistencyMessage,
                        rawArtifact:"\(artifactPrefix)/degree-expression-consistency.json",metrics:[:]))
                }
                let embedded = EmbeddedLengthUnitNormalizer.normalize(mathML:parsed.mathML,target:target,observations:observations)
                let wholeUnitRoute = sourceRegion?.detectionSource == LengthUnitSource.version ||
                    (sourceRegion?.detectionSource == Pix2TextMFDRuntime.proposalVersion && LengthUnitSource.parse(structureSource) != nil)
                if !wholeUnitRoute, let normalized = embedded.mathML {
                    try rawEncoder.encode(embedded).write(to:directory.appendingPathComponent("unit-normalization.json"),options:.atomic)
                    stages.append(ComponentResult(component:"formula_unit_normalization",status:"succeeded",errorCode:nil,message:EmbeddedLengthUnitNormalizer.version,
                        rawArtifact:"\(artifactPrefix)/unit-normalization.json",metrics:[:]))
                    try normalized.write(to:directory.appendingPathComponent("mathml.unit-normalized.xml"),atomically:true,encoding:.utf8)
                    spoken = try await MathCATAdapter.shared.speak(mathML:normalized)
                    try rawEncoder.encode(spoken).write(to:directory.appendingPathComponent("mathcat.unit-normalized.json"),options:.atomic)
                    formulas[index].spokenText = spoken.spokenText
                    formulas[index].canonicalMathML = spoken.canonicalMathML
                    formulas[index].mathCATProfile = spoken.profile
                    formulas[index].unitPowerAnchors = embedded.anchors
                    formulas[index].derivations = (formulas[index].derivations ?? []) + ["\(EmbeddedLengthUnitNormalizer.version): exact source quantity and image subtree; raw math preserved"]
                    stages.append(ComponentResult(component:"mathcat_unit_normalized",status:"succeeded",errorCode:nil,message:spoken.version,rawArtifact:"\(artifactPrefix)/mathcat.unit-normalized.json",metrics:["inference_ms":spoken.milliseconds]))
                }
                if sourceRegion?.detectionSource == LengthUnitSource.version ||
                    (sourceRegion?.detectionSource == Pix2TextMFDRuntime.proposalVersion && LengthUnitSource.parse(structureSource) != nil) {
                    let normalized = LengthUnitNormalizer.normalize(source: structureSource, mathML: parsed.mathML)
                    let check = normalized.normalizedValidation ?? normalized.rawValidation
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(normalized).write(to: directory.appendingPathComponent("unit-normalization.json"), options: .atomic)
                    stages.append(ComponentResult(component:"formula_unit_normalization",status:normalized.allowed ? "succeeded" : "needs_review",
                        errorCode:normalized.allowed ? nil : "unit_normalization_withheld",message:normalized.reason,
                        rawArtifact:"\(artifactPrefix)/unit-normalization.json",metrics:[:]))
                    if normalized.allowed, let mathML = normalized.normalizedMathML {
                        try mathML.write(to:directory.appendingPathComponent("mathml.unit-normalized.xml"),atomically:true,encoding:.utf8)
                        currentStage = "mathcat_unit_normalized"
                        spoken = try await MathCATAdapter.shared.speak(mathML:mathML)
                        try encoder.encode(spoken).write(to:directory.appendingPathComponent("mathcat.unit-normalized.json"),options:.atomic)
                        formulas[index].spokenText = spoken.spokenText
                        formulas[index].canonicalMathML = spoken.canonicalMathML
                        formulas[index].mathCATProfile = spoken.profile
                        formulas[index].derivations = (formulas[index].derivations ?? []) + ["\(LengthUnitNormalizer.version): \(normalized.operation ?? "unit_intent"); complete source and image power checks recorded; raw MathML/MathCAT remain separate"]
                        stages.append(ComponentResult(component:"mathcat_unit_normalized",status:"succeeded",errorCode:nil,
                            message:spoken.version,rawArtifact:"\(artifactPrefix)/mathcat.unit-normalized.json",metrics:["inference_ms":spoken.milliseconds]))
                    }
                    try encoder.encode(check).write(to: directory.appendingPathComponent("unit-consistency.json"), options: .atomic)
                    formulas[index].sourceConsistencyStatus = check.allowed ? "image_length_unit_consistent" : "needs_review"
                    formulas[index].sourceConsistencyMessage = check.reason
                    formulas[index].spokenMergeAllowed = check.allowed && formulas[index].spokenMergeAllowed != false
                    stages.append(ComponentResult(component: "formula_unit_consistency", status: check.allowed ? "succeeded" : "needs_review",
                        errorCode: check.allowed ? nil : "unit_measurement_requires_review", message: check.reason,
                        rawArtifact: "\(artifactPrefix)/unit-consistency.json", metrics: [:]))
                } else if sourceRegion?.detectionSource != "vision_degree_expression_proposal_v1", !structureSource.isEmpty, FormulaExponentCheck.needsCheck(structureSource,mathML:parsed.mathML) {
                    let check = FormulaExponentCheck.check(source:structureSource,mathML:parsed.mathML)
                    let checkURL = directory.appendingPathComponent("exponent-consistency.json")
                    let checkEncoder = JSONEncoder(); checkEncoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    try checkEncoder.encode(check).write(to:checkURL,options:.atomic)
                    formulas[index].sourceConsistencyStatus = check.allowed ? (check.expected.isEmpty ? "image_recognized_power_ocr_structure_unassessed" : "consistent_with_explicit_ocr_exponents") : "needs_review"
                    formulas[index].sourceConsistencyMessage = check.message
                    formulas[index].spokenMergeAllowed = check.allowed && formulas[index].spokenMergeAllowed != false
                    stages.append(ComponentResult(component:"formula_exponent_consistency",status:check.allowed ? "succeeded" : "needs_review",
                        errorCode:check.allowed ? nil : "exponent_structure_requires_review",message:check.message,
                        rawArtifact:"\(artifactPrefix)/exponent-consistency.json",metrics:[:]))
                }
                if formulas[index].spokenMergeAllowed != false, let proposal=regions.first(where:{$0.id==formulas[index].layoutRegionID})?.proposalText,proposal.count==1,proposal.rangeOfCharacter(from:.letters) != nil {
                    let check=FormulaIdentifierCheck.check(mathML:parsed.mathML,expected:proposal)
                    formulas[index].sourceConsistencyStatus=check.allowed ? "consistent_with_ocr_proposal" : "needs_review"
                    formulas[index].sourceConsistencyMessage=check.message
                    formulas[index].spokenMergeAllowed=check.allowed && formulas[index].spokenMergeAllowed != false
                }
                if formulas[index].spokenMergeAllowed != false, let region = regions.first(where: { $0.id == formulas[index].layoutRegionID }),
                   region.detectionSource == "vision_visual_numeric_proposal_v2", let proposal = region.proposalText {
                    let check = FormulaNumericCheck.check(mathML:parsed.mathML,expected:proposal)
                    formulas[index].sourceConsistencyStatus = check.allowed ? "consistent_with_ocr_numeric_proposal" : "needs_review"
                    formulas[index].sourceConsistencyMessage = check.message
                    formulas[index].spokenMergeAllowed = check.allowed && formulas[index].spokenMergeAllowed != false
                }
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            } catch {
                formulas[index].status = error is CancellationError ? "cancelled" : "unresolved"
                formulas[index].errorCode = error is CancellationError ? "run_cancelled" : "formula_pipeline_failed"
                formulas[index].failureMessage = error.localizedDescription
                let failedStage = currentStage
                if !stages.contains(where: { $0.component == failedStage && $0.status != "succeeded" }) {
                    stages.append(ComponentResult(component:failedStage,status:error is CancellationError ? "cancelled" : "failed",errorCode:formulas[index].errorCode,message:error.localizedDescription,rawArtifact:nil,metrics:[:]))
                }
            }
            for component in ["unimernet","mathjax","mathcat"] where !stages.contains(where:{$0.component == component}) {
                stages.append(ComponentResult(component:component,status:"skipped_dependency",errorCode:"upstream_formula_stage_failed",message:nil,rawArtifact:nil,metrics:[:]))
            }
            formulas[index].stageResults = stages
            stageResults += stages
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try? encoder.encode(formulas[index]).write(to:directory.appendingPathComponent("formula-result.json"),options:.atomic)
        }
        await runtime.unload()
        await gate.release()
        let summaries = ["unimernet","mathjax","mathcat","vision_numeric_mathml"].map { name -> ComponentResult in
            let values=stageResults.filter{($0.component==name || (name=="mathcat" && $0.component=="mathcat_unit_normalized")) && $0.status != "skipped_by_route"}
            let success=values.filter{$0.status=="succeeded"}.count
            let metricKeys=Set(values.flatMap{$0.metrics.keys})
            var metrics:[String:Double?]=["attempted":Double(values.count),"succeeded":Double(success)]
            for key in metricKeys { metrics[key]=values.compactMap{$0.metrics[key] ?? nil}.reduce(0,+) }
            return ComponentResult(component:name,status:values.isEmpty ? "skipped_no_input" : (success==values.count ? "succeeded" : (success>0 ? "partial" : "failed")),errorCode:success==values.count ? nil : "formula_stage_incomplete",message:"\(success)/\(values.count) actual stage calls completed; route skips excluded; correctness requires source review",rawArtifact:"pages/\(pageID)/formula-detection.raw.json",metrics:metrics)
        }
        return FormulaPageResult(formulas:formulas,components:summaries)
    }
}

/// Compare only explicit OCR exponent notation with the recognizer's structure.
/// Flattened x2 / x' remains ambiguous. No character, LaTeX or speech is repaired.
private final class FormulaExponentCheck: NSObject, XMLParserDelegate {
    struct Power: Codable, Equatable { let base:String; let exponent:String }
    struct Result: Codable {
        let version:String
        let allowed:Bool
        let message:String
        let source:String
        let expected:[Power]
        let recognized:[Power]
    }
    private final class Node {
        let name:String
        var text = ""
        var children:[Node] = []
        init(_ name:String) { self.name = name }
        var leafText:String { text + children.map(\.leafText).joined() }
    }
    private var stack:[Node] = []
    private var roots:[Node] = []
    private var powers:[Power] = []
    private static let raised = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
    static func needsCheck(_ source:String,mathML:String) -> Bool {
        source.contains(where:{ raised.contains($0) }) || source.contains("^") ||
            source.range(of:#"[A-Za-z](?:[0-9]+|['’′])"#,options:.regularExpression) != nil ||
            mathML.contains("<msup") || mathML.contains("<msubsup")
    }
    static func check(source:String,mathML:String) -> Result {
        guard let regex = try? NSRegularExpression(pattern:#"([A-Za-z])(?:([⁰¹²³⁴⁵⁶⁷⁸⁹]+)|\s*\^\s*(?:\{\s*([+-]?[0-9]+)\s*\}|([+-]?[0-9]+)))"#) else {
            return Result(version:"image_exponent_consistency_v2",allowed:false,message:"Exponent checker unavailable; speech withheld",source:source,expected:[],recognized:[])
        }
        let ns = source as NSString
        let expected = regex.matches(in:source,range:NSRange(location:0,length:ns.length)).map { match -> Power in
            let base = ns.substring(with:match.range(at:1))
            if match.range(at:2).location != NSNotFound {
                let exponent = ns.substring(with:match.range(at:2)).map { String(raised.firstIndex(of:$0)!) }.joined()
                return Power(base:base,exponent:exponent)
            }
            let range = match.range(at:3).location != NSNotFound ? match.range(at:3) : match.range(at:4)
            return Power(base:base,exponent:ns.substring(with:range))
        }
        let reader = FormulaExponentCheck(), parser = XMLParser(data:Data(mathML.utf8))
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        // Linear OCR can flatten or omit superscripts. With no explicit OCR power,
        // it cannot veto structured image recognition. It also cannot create one.
        let imagePower = parsed && !reader.powers.isEmpty
        let allowed = expected.isEmpty ? imagePower : (parsed && expected == reader.powers)
        return Result(version:"image_exponent_consistency_v2",allowed:allowed,
            message:allowed ? (expected.isEmpty ? "UniMERNet recognized structured powers from the image; linear OCR lacks explicit power structure and is not used to invent or veto exponents; photo accuracy remains unassessed" : "Explicit OCR exponent notation matches MathML base/exponent pairs; source photo accuracy remains unassessed") :
                "Exponent structure is missing, conflicting or ambiguous in OCR (including flattened x2/prime). Keep raw recognition; withhold speech rather than infer or repair a power",
            source:source,expected:expected,recognized:reader.powers)
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        guard stack.count < 128 else { parser.abortParsing(); return }
        let node = Node(name)
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser:XMLParser,foundCharacters text:String) { stack.last?.text += text }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        guard let node = stack.popLast() else { return }
        if name == "msup" || name == "msubsup" {
            let exponentIndex = name == "msup" ? 1 : 2
            guard node.children.count > exponentIndex else { return }
            let base = node.children[0].leafText.filter { !$0.isWhitespace }
            let exponent = node.children[exponentIndex].leafText.filter { !$0.isWhitespace }
            powers.append(.init(base:base,exponent:exponent))
        }
    }
}

// Cross-check the recognizer against the literal one-letter Vision proposal.
// This only flags contradictions; it never changes LaTeX, MathML or MathCAT text.
private final class FormulaIdentifierCheck: NSObject, XMLParserDelegate {
    var identifiers:[String]=[]
    var token:String?
    var buffer=""
    var extraStructure=false
    var specialVariant=false
    static func check(mathML:String,expected:String) -> (allowed:Bool,message:String) {
        let check=FormulaIdentifierCheck()
        let parser=XMLParser(data:Data(mathML.utf8));parser.delegate=check
        let valid=parser.parse()
        let allowed=valid && check.identifiers==[expected] && !check.extraStructure && !check.specialVariant
        return (allowed,allowed ? "MathML is one identifier matching the Vision proposal; source fidelity still requires visual review" : "Vision proposed \(expected); UniMERNet MathML has identifiers \(check.identifiers), extra structure=\(check.extraStructure), special variant=\(check.specialVariant). Raw speech retained but withheld from merged segments; no automatic correction")
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        if ["mn","mo","mfrac","msqrt","mroot","msub","msup","msubsup","munder","mover","munderover","mtable","mtext"].contains(name) {extraStructure=true}
        if let variant=attributes["mathvariant"],!["normal","italic"].contains(variant) {specialVariant=true}
        if name=="mi" {token=name;buffer=""}
    }
    func parser(_ parser:XMLParser,foundCharacters text:String) {if token != nil {buffer+=text}}
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        if name=="mi",token != nil {identifiers.append(buffer);token=nil}
    }
}


// Mechanical disagreement check, never a numeric correction or speech engine.
private final class FormulaNumericCheck: NSObject, XMLParserDelegate {
    private var inNumber = false
    private var digits = ""
    static func check(mathML:String,expected:String) -> (allowed:Bool,message:String) {
        let reader = FormulaNumericCheck()
        let parser = XMLParser(data:Data(mathML.utf8)); parser.delegate = reader; parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        let expectedDigits = String(expected.filter { $0.isNumber })
        let got = reader.digits
        let uncertainOCR = expected.contains("*") || expected.contains("З")
        let expectedDegree = expected.contains("°") || expected.contains("º")
        let gotDegree = mathML.contains("∘") || mathML.contains("°")
        let allowed = parsed && !expectedDigits.isEmpty && expectedDigits == got && !uncertainOCR && (!expectedDegree || gotDegree)
        return (allowed,allowed ? "Literal numeric tokens agree with the Vision proposal; source photo correctness remains unassessed" :
            "Numeric/symbol disagreement with Vision proposal; expected literal \(expected), MathML digits \(got). Raw preserved; merged speech withheld")
    }
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) { if elementName == "mn" { inNumber = true } }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if inNumber { digits += String(string.filter { $0.isNumber }) } }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) { if elementName == "mn" { inNumber = false } }
}
