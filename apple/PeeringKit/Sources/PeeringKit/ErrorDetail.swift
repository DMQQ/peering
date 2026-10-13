import Foundation

/// What an Error Tracking issue carries beyond a domain and a code, without the message: the Swift type and enum case say which of our own failures it was, and neither can hold a path, a name or an address.
public enum ErrorDetail {
    public static func properties(for error: Error) -> [String: String] {
        let nsError = error as NSError
        var details = ["error_domain": nsError.domain, "error_code": String(nsError.code)]
        guard Mirror(reflecting: error).displayStyle == .enum else { return details }
        details["error_type"] = String(reflecting: type(of: error))
        details["error_case"] = String(String(describing: error).prefix { $0 != "(" })
        return details
    }
}
