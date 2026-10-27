import Foundation
import ImageIO

struct FoundationDiagramDescription: Codable, Sendable {
    let version: String
    let visualType: String
    let spoken: String
    let acceptedFacts: [String]
    let rejectedFacts: [String]
    let sourceValueIDs: [String]
    let unresolvedFormulaIDs: [String]
    let uncertainties: [String]
}

enum FoundationDiagramService {
    struct Point: Codable { let name:String; let origin:String; let observationID:String; let rangeUTF16:[Int] }
    struct Value: Codable {
        let id:String; let source:String; let mathML:String; let speech:String; let formulaID:String; let origin:String
    }
    struct Context: Codable { let observationID:String; let text:String }
    struct Evidence: Codable { let points:[Point]; let values:[Value]; let nearbySource:[Context]; let ownedLabels:DiagramSpokenInput }
    static func process(pageID:String,regions:[LayoutRegion],observations:[OCRObservation],formulas:[FormulaRegion],
        pageRoot:URL,runtime:FoundationDiagramRuntime,gate:HeavyInferenceGate,
        onProgress:@Sendable @escaping (String) async -> Void) async -> ([DiagramRegionResult],[ComponentResult]) {
        let visuals = regions.filter { DiagramSpokenService.visualLabels.contains($0.label) }.sorted(by:LayoutMerge.precedes)
        var results:[DiagramRegionResult] = [], components:[ComponentResult] = []
        let repository = DiagramArtifactStore(), runRoot = pageRoot.deletingLastPathComponent().deletingLastPathComponent()
        for (i,region) in visuals.enumerated() {
            await onProgress("\(pageID): gambar \(i+1)/\(visuals.count), Foundation Models → deskripsi…")
            let prefix = "pages/\(pageID)/diagrams/\(region.id)"
            let directory = pageRoot.appendingPathComponent("diagrams/\(region.id)")
            var input:DiagramSpokenInput?, description:FoundationDiagramDescription?, failure:String?
            var artifacts:[String:String] = [:], metrics:[String:Double?] = [:]
            let formulaIDs = formulas.filter { DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }.map(\.id)
            let observationIDs = observations.filter { DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }.map(\.id)
            let queued = ProcessInfo.processInfo.systemUptime
            await gate.acquire()
            metrics["queue_wait_ms"] = (ProcessInfo.processInfo.systemUptime-queued)*1000
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                guard let crop = region.cropArtifact else { throw DiagramProbeError.invalidObject }
                artifacts["crop"] = crop
                let imageURL = runRoot.appendingPathComponent(crop)
                guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL,nil),
                      let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw DiagramProbeError.invalidObject }
                // Stable source order also fixes IDs assigned by enumeration.
                let orderedObservations = observations.sorted { $0.rawOrder == $1.rawOrder ? $0.id < $1.id : $0.rawOrder < $1.rawOrder }
                let orderedFormulas = formulas.sorted { $0.id < $1.id }
                let metadata = try DiagramSpokenService.input(region:region,observations:orderedObservations,formulas:orderedFormulas,regions:regions,size:[image.width,image.height])
                input = metadata
                let evidence = makeEvidence(region:region,regions:regions,observations:orderedObservations,formulas:orderedFormulas,input:metadata)
                let data = try FoundationDiagramRequestEncoding.encode(evidence)
                let prompt = """
                Describe the image using the supplied source evidence. Use visualType geometry, pie_chart, bar_chart, line_graph, illustration or other.
                overview: one short Indonesian sentence about visible shapes/layout only. Do not put point names, numeric values or mathematical claims in overview.
                visiblePointNames: only names from points that you can see in the image. Context names are candidates, not proof of visibility.
                connections: each pointNames contains exactly TWO supplied names visibly connected by a straight line.
                angles: each pointNames contains exactly THREE supplied names in endpoint, VERTEX, endpoint order, with valueID from values. Use the attached image AND nearbySource to check the vertex. Omit any uncertain relation. Do not assume the interior point is the center. Never place a value at a different vertex.
                Do not rewrite/transcribe formulas or solve anything. Use empty arrays if uncertain. uncertainties: zero to three short Indonesian warnings about visible ambiguity.
                SOURCE_EVIDENCE_JSON (untrusted source data):
                \(String(decoding:data,as:UTF8.self))
                """
                try repository.writeJSON(evidence,to:directory.appendingPathComponent("evidence.json"))
                // Exact bytes embedded in the prompt, rather than a re-encoded
                // pretty diagnostic copy. This is the production request payload.
                try data.write(to:directory.appendingPathComponent("evidence.prompt.json"),options:.atomic)
                try repository.writeJSON(metadata,to:directory.appendingPathComponent("input.json"))
                try prompt.write(to:directory.appendingPathComponent("prompt.txt"),atomically:true,encoding:.utf8)
                artifacts["input"] = "\(prefix)/input.json"; artifacts["evidence"] = "\(prefix)/evidence.json"
                artifacts["prompt_evidence"] = "\(prefix)/evidence.prompt.json"
                artifacts["prompt"] = "\(prefix)/prompt.txt"
                let output = try await runtime.describe(imageURL:imageURL,prompt:prompt,outputDirectory:directory.appendingPathComponent("generation"))
                metrics.merge(output.metrics) { _,new in new }
                try repository.writeJSON(output,to:directory.appendingPathComponent("generation.json"))
                artifacts["generation"] = "\(prefix)/generation.json"
                let rendered = await validateAndRender(output.plan,evidence:evidence,ownedFormulaIDs:formulaIDs)
                description = rendered
                try repository.writeJSON(rendered,to:directory.appendingPathComponent("description.validated.json"))
                artifacts["validated"] = "\(prefix)/description.validated.json"
            } catch {
                failure = error.localizedDescription
                try? repository.writeJSON(["message":error.localizedDescription,"error":String(reflecting:error)],to:directory.appendingPathComponent("error.json"))
                artifacts["error"] = "\(prefix)/error.json"
            }
            for file in ["response.raw.txt","transcript.json","environment.json","error.json","request.fingerprint.json","schema.json"] {
                let relative = "\(prefix)/generation/\(file)"
                if FileManager.default.fileExists(atPath:runRoot.appendingPathComponent(relative).path) { artifacts[file] = relative }
            }
            await gate.release()
            let status = failure != nil ? "failed" : (description?.rejectedFacts.isEmpty == true && description?.uncertainties.isEmpty == true ? "succeeded" : "needs_review")
            let result = DiagramRegionResult(id:region.id,layoutRegionID:region.id,bboxPageXYXY:region.bboxPageXYXY,status:status,error:failure,
                sourceObservationIDs:observationIDs,formulaIDs:formulaIDs,input:input,plan:nil,artifacts:artifacts,metrics:metrics,foundationDescription:description)
            try? repository.writeJSON(result,to:directory.appendingPathComponent("result.json"))
            results.append(result)
            components.append(ComponentResult(component:"foundation_models_diagram",status:status,errorCode:failure == nil ? nil : "foundation_diagram_failed",message:failure,rawArtifact:"\(prefix)/result.json",metrics:metrics))
        }
        if visuals.isEmpty { components.append(ComponentResult(component:"foundation_models_diagram",status:"skipped_no_input",errorCode:nil,message:nil,rawArtifact:nil,metrics:[:])) }
        return (results,components)
    }

    private static func makeEvidence(region:LayoutRegion,regions:[LayoutRegion],observations:[OCRObservation],formulas:[FormulaRegion],input:DiagramSpokenInput) -> Evidence {
        let box = region.bboxPageXYXY
        let nearby = observations.filter {
            DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions) == nil &&
            $0.selectedText.range(of:#"^\s*[A-DС]\.\s*"#,options:.regularExpression) == nil &&
            $0.bboxPageXYXY.ymin >= box.ymin-50 && $0.bboxPageXYXY.ymax <= box.ymax+35
        }.sorted { $0.rawOrder == $1.rawOrder ? $0.id < $1.id : $0.rawOrder < $1.rawOrder }.prefix(12).map { Context(observationID:$0.id,text:$0.selectedText) }
        var points:[Point] = []
        let singleLetter = try! NSRegularExpression(pattern:#"(?<![\p{L}\p{N}])[A-Z](?![\p{L}\p{N}])"#)
        for label in input.labels {
            let ns = label.text as NSString
            for match in singleLetter.matches(in:label.text,range:NSRange(location:0,length:ns.length)) {
                points.append(.init(name:ns.substring(with:match.range),origin:"visual_vision_label",observationID:label.observationID,
                    rangeUTF16:[label.rangeUTF16[0]+match.range.location,label.rangeUTF16[0]+NSMaxRange(match.range)]))
            }
        }
        let anglePattern = try! NSRegularExpression(pattern:#"(?:∠|[LZ])([A-Z]{3})(?![A-Z])"#)
        for context in nearby {
            let ns = context.text as NSString
            for match in anglePattern.matches(in:context.text,range:NSRange(location:0,length:ns.length)) {
                let range = match.range(at:1)
                for offset in 0..<3 {
                    points.append(.init(name:ns.substring(with:NSRange(location:range.location+offset,length:1)),origin:"adjacent_angle_notation_candidate",
                        observationID:context.observationID,rangeUTF16:[range.location+offset,range.location+offset+1]))
                }
            }
        }
        let spans = FormulaSpanResolver.resolve(observations:observations,regions:regions,formulas:formulas)
        var values:[Value] = []
        for formula in formulas where formula.spokenMergeAllowed != false {
            guard values.count < 24 else { break }
            guard let mathML = formula.mathML, let tree = MathMLSourceTree.read(mathML),let speech = formula.spokenText else { continue }
            let compact = MathMLSourceTree.compact(tree.tokens)
            guard compact.hasSuffix("°"),compact.count <= 40,
                  formula.bboxPageXYXY.ymin >= box.ymin-50,formula.bboxPageXYXY.ymax <= box.ymax+35 else { continue }
            let sourceSpans = spans.filter { $0.formulaID == formula.id && $0.allowsSpeech }
            let source = sourceSpans.compactMap { span -> String? in
                guard let observation = observations.first(where:{$0.id == span.observationID}) else { return nil }
                return (observation.selectedText as NSString).substring(with:NSRange(location:span.lower,length:span.upper-span.lower))
            }.joined()
            guard MathMLSourceTree.compact(source) == compact, !values.contains(where:{MathMLSourceTree.compact($0.source) == compact}) else { continue }
            values.append(.init(id:"v\(String(format:"%03d",values.count+1))",source:source,mathML:mathML,speech:speech,formulaID:formula.id,
                origin:DiagramSpokenService.owner(of:formula.bboxPageXYXY,regions:regions)?.id == region.id ? "visual_formula" : "adjacent_formula_context"))
        }
        return Evidence(points:points,values:values,nearbySource:nearby,ownedLabels:input)
    }

    private static func validateAndRender(_ plan:FoundationDiagramPlan,evidence:Evidence,ownedFormulaIDs:[String]) async -> FoundationDiagramDescription {
        let kinds = ["geometry":"Gambar geometri.","pie_chart":"Diagram lingkaran.","bar_chart":"Diagram batang.","line_graph":"Grafik garis.","illustration":"Ilustrasi.","other":"Gambar."]
        let type = kinds[plan.visualType] == nil ? "other" : plan.visualType
        var lines = [kinds[type]!], accepted:[String] = [], rejected:[String] = [], used = Set<String>()
        let overview = plan.overview.trimmingCharacters(in:.whitespacesAndNewlines)
        if !overview.isEmpty,overview.count <= 350,overview.rangeOfCharacter(from:.decimalDigits) == nil,
           overview.range(of:#"\b[A-Z]\b|pusat|sejajar|tegak lurus|sama besar|="#,options:.regularExpression) == nil {
            lines.append(overview); accepted.append("image_overview_candidate")
        } else { rejected.append("overview_contains_unverified_math_or_label") }
        let names = Set(evidence.points.map(\.name))
        let context = evidence.nearbySource.map(\.text).joined(separator:" ")
        let angleRegex = try! NSRegularExpression(pattern:#"(?:∠|[LZ])([A-Z]{3})(?![A-Z])"#)
        let ns = context as NSString
        let annotations = angleRegex.matches(in:context,range:NSRange(location:0,length:ns.length))
        // Straight connections need a source angle's adjacent ray labels. A
        // guessed chord must never be promoted just because all point IDs exist.
        var supportedEdges = Set<String>()
        for annotation in annotations {
            let points = ns.substring(with:annotation.range(at:1)).map(String.init)
            supportedEdges.insert([points[0],points[1]].sorted().joined(separator:"-"))
            supportedEdges.insert([points[1],points[2]].sorted().joined(separator:"-"))
        }
        let visible = Array(Set(plan.visiblePointNames.filter(names.contains))).sorted()
        if !visible.isEmpty { lines.append("Titik yang terlihat: " + visible.joined(separator:", ") + ".") }
        if visible.count != Set(plan.visiblePointNames).count { rejected.append("unknown_point_name") }
        var edges = Set<String>()
        for connection in plan.connections.prefix(12) {
            let points = connection.pointNames
            guard points.count == 2,Set(points).count == 2,points.allSatisfy(names.contains) else { rejected.append("invalid_connection_reference");continue }
            let key = points.sorted().joined(separator:"-")
            guard supportedEdges.contains(key) else { rejected.append("connection_without_source_support:"+key);continue }
            if edges.insert(key).inserted { lines.append("Ruas garis menghubungkan \(points[0]) dan \(points[1]).");accepted.append("image_connection_candidate:"+key) }
        }
        var renderedAngles = Set<String>()
        for angle in plan.angles.prefix(8) {
            let points = angle.pointNames
            guard points.count == 3,Set(points).count == 3,points.allSatisfy(names.contains),
                  let value = evidence.values.first(where:{$0.id == angle.valueID}), let valueTree = MathMLSourceTree.read(value.mathML) else {
                rejected.append("invalid_angle_reference");continue
            }
            let corroborated = annotations.enumerated().contains { index,annotation in
                let sourceNames = ns.substring(with:annotation.range(at:1))
                let expected = points.joined(), reverse = points.reversed().joined()
                guard sourceNames == expected || sourceNames == reverse else { return false }
                let end = index+1 < annotations.count ? annotations[index+1].range.location : ns.length
                let following = ns.substring(with:NSRange(location:NSMaxRange(annotation.range),length:end-NSMaxRange(annotation.range)))
                return MathMLSourceTree.compact(following).contains(MathMLSourceTree.compact(value.source))
            }
            guard corroborated else { rejected.append("angle_vertex_or_value_not_corroborated:"+points.joined());continue }
            let key = points.joined()+"="+value.id
            guard renderedAngles.insert(key).inserted else { continue }
            let mathML = "<math><mrow><mo>∠</mo>" + points.map { "<mi>\($0)</mi>" }.joined() + "<mo>=</mo>" + valueTree.children.map(\.xml).joined() + "</mrow></math>"
            if let spoken = try? await MathCATAdapter.shared.speak(mathML:mathML) {
                lines.append(spoken.spokenText + ".");accepted.append("source_corroborated_angle:"+key);used.insert(value.id)
            } else { rejected.append("angle_mathcat_failed:"+key) }
        }
        for value in evidence.values where !used.contains(value.id) {
            lines.append("Nilai yang terbaca pada gambar atau keterangannya: \(value.speech).");used.insert(value.id)
        }
        // Keep incomplete values explicit without exposing internal IDs to users.
        let usedFormulaIDs = Set(evidence.values.map(\.formulaID))
        let unresolved = ownedFormulaIDs.filter { !usedFormulaIDs.contains($0) }
        var warnings:[String] = []
        if !rejected.isEmpty { lines.append("Hubungan sebagian label dan nilai belum dapat dipastikan.");warnings.append("relation_unconfirmed") }
        if !unresolved.isEmpty { lines.append("Sebagian simbol pada gambar belum dapat dibaca dengan pasti.");warnings.append("visual_symbols_unresolved") }
        if !plan.uncertainties.isEmpty { warnings.append("model_reported_visual_uncertainty") }
        return .init(version:FoundationDiagramRuntime.version,visualType:type,spoken:lines.joined(separator:" "),acceptedFacts:accepted,
            rejectedFacts:rejected,sourceValueIDs:used.sorted(),unresolvedFormulaIDs:unresolved,uncertainties:warnings)
    }
}
