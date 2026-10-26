import Foundation
import WebKit

struct MathJaxParseResult: Sendable {
    let formulaID: String
    let mathML: String
    let parseMilliseconds: Double
    let hasMathErrorNode: Bool
    let parseError: String?
}

@MainActor
final class MathJaxBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private var ready = false
    private var loadingError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [String: CheckedContinuation<MathJaxParseResult, Error>] = [:]
    private var requestStarts: [String: Double] = [:]
    private var activeRequestID: String?

    override init() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(self, name: "metra")
        webView.navigationDelegate = self
        guard let html = Bundle.main.url(forResource: "MathJaxBridge", withExtension: "html"),
              let resourceRoot = Bundle.main.resourceURL else {
            loadingError = MathJaxBridgeError.bundleMissing
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.ready else { return }
            self.failReadyWaiters(MathJaxBridgeError.parseFailed("startup timeout"))
        }
    }

    func convert(latex: String, formulaID: String) async throws -> MathJaxParseResult {
        try await waitUntilReady()
        guard activeRequestID == nil else { throw MathJaxBridgeError.concurrentRequest }
        let requestID = UUID().uuidString
        activeRequestID = requestID
        let start = ProcessInfo.processInfo.systemUptime
        requestStarts[requestID] = start

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let stalled = self.pending.removeValue(forKey:requestID) else { return }
                self.requestStarts.removeValue(forKey:requestID)
                self.activeRequestID = nil
                self.loadingError = MathJaxBridgeError.parseFailed("conversion timeout")
                stalled.resume(throwing:self.loadingError!)
            }
            guard let payload = Self.javascriptArray([requestID, formulaID, latex]) else {
                pending.removeValue(forKey: requestID)
                activeRequestID = nil
                continuation.resume(throwing: MathJaxBridgeError.requestEncodingFailed)
                return
            }
            // metraConvert is async and returns a Promise. WKWebView cannot
            // transport that value through evaluateJavaScript. Return null;
            // only the request-ID script message completes a conversion.
            webView.evaluateJavaScript("window.metraConvert(\(payload)); null;") { _, error in
                if let error, let continuation = self.pending.removeValue(forKey: requestID) {
                    self.requestStarts.removeValue(forKey: requestID)
                    self.activeRequestID = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "ready" {
            ready = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
            return
        }
        if body["kind"] as? String == "ready-error" {
            failReadyWaiters(MathJaxBridgeError.parseFailed(body["error"] as? String ?? "startup failed"))
            return
        }
        guard let requestID = body["requestID"] as? String,
              let continuation = pending.removeValue(forKey: requestID) else { return }
        let started = requestStarts.removeValue(forKey: requestID) ?? ProcessInfo.processInfo.systemUptime
        activeRequestID = nil
        guard let mathML = body["mathml"] as? String else {
            let error = body["error"] as? String ?? "MathJax parse failed without a parser message."
            continuation.resume(throwing: MathJaxBridgeError.parseFailed(error))
            return
        }
        continuation.resume(returning: MathJaxParseResult(
            formulaID: body["formulaID"] as? String ?? "unknown",
            mathML: mathML,
            parseMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
            hasMathErrorNode: body["hasMathErrorNode"] as? Bool ?? false,
            parseError: body["error"] as? String
        ))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failReadyWaiters(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failReadyWaiters(error)
    }

    private func waitUntilReady() async throws {
        if let loadingError { throw loadingError }
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    private func failReadyWaiters(_ error: Error) {
        loadingError = error
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
    }

    private static func javascriptArray(_ values: [String]) -> String? {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum MathJaxBridgeError: LocalizedError {
    case bundleMissing
    case concurrentRequest
    case requestEncodingFailed
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleMissing: "MathJaxBridge.html tidak ada di bundle aplikasi."
        case .concurrentRequest: "Bridge MathJax menerima satu ekspresi pada satu waktu."
        case .requestEncodingFailed: "Argumen formula tidak dapat dikodekan dengan aman untuk JavaScript."
        case .parseFailed(let reason): "MathJax menolak LaTeX: \(reason)"
        }
    }
}
