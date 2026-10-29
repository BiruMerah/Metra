import Foundation
import WebKit

@main
enum MathJaxAcknowledgementChecks {
    @MainActor static func main() throws {
        func error(_ code:WKError.Code) -> NSError { NSError(domain:WKErrorDomain,code:code.rawValue) }
        let checks = [
            "unsupported_ack_waits_for_mathml_message":MathJaxBridge.isIgnorableAcknowledgementError(error(.javaScriptResultTypeIsUnsupported)),
            "javascript_exception_still_fails":!MathJaxBridge.isIgnorableAcknowledgementError(error(.javaScriptExceptionOccurred)),
            "web_process_termination_still_fails":!MathJaxBridge.isIgnorableAcknowledgementError(error(.webContentProcessTerminated)),
            "invalid_webview_still_fails":!MathJaxBridge.isIgnorableAcknowledgementError(error(.webViewInvalidated)),
            "other_domain_not_ignored":!MathJaxBridge.isIgnorableAcknowledgementError(NSError(domain:"other",code:WKError.Code.javaScriptResultTypeIsUnsupported.rawValue))
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["checks":checks,"passed":checks.values.filter{$0}.count,"total":checks.count,
            "scope":"Production callback error classification; no WebView created or model inference"],options:[.prettyPrinted,.sortedKeys]))
        guard checks.values.allSatisfy({$0}) else { throw NSError(domain:"MathJaxAcknowledgementChecks",code:1) }
    }
}
