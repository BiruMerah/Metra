import Foundation

/// Structural XML transport only. No OCR interpretation or speech generation.
final class MathMLSourceTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var attributes: [String:String]
        var text = ""
        var children: [Node] = []
        init(_ name:String, attributes:[String:String] = [:]) { self.name = name; self.attributes = attributes }
        var tokens: String {
            if ["annotation","annotation-xml","mspace"].contains(name) { return "" }
            if ["mi","mn","mo","mtext"].contains(name) { return text }
            return children.map(\.tokens).joined()
        }
        var xml: String {
            let attrs = attributes.filter { !$0.key.hasPrefix("data-semantic") && $0.key != "data-latex" }
                .sorted { $0.key < $1.key }.map { " \($0.key)=\"\(MathMLSourceTree.escape($0.value))\"" }.joined()
            return "<\(name)\(attrs)>\(MathMLSourceTree.escape(text))\(children.map(\.xml).joined())</\(name)>"
        }
    }
    private var stack: [Node] = []
    private var nodes = 0
    private var roots: [Node] = []
    static func read(_ mathML:String) -> Node? {
        guard mathML.utf8.count <= 500_000 else { return nil }
        let reader = MathMLSourceTree(), parser = XMLParser(data:Data(mathML.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.roots.count == 1, reader.roots[0].name == "math" else { return nil }
        return reader.roots[0]
    }
    static func compact(_ text:String) -> String {
        String(text.filter { !$0.isWhitespace && !["\u{2061}","\u{2062}","\u{2063}","\u{2064}"].contains(String($0)) })
            .replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:"∘",with:"°").replacingOccurrences(of:"º",with:"°")
    }
    static func escape(_ text:String) -> String {
        text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        nodes += 1
        guard stack.count < 128, nodes <= 4096 else { parser.abortParsing(); return }
        let node = Node(name,attributes:attributes)
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser:XMLParser,foundCharacters text:String) { stack.last?.text += text }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) { if !stack.isEmpty { stack.removeLast() } }
}
