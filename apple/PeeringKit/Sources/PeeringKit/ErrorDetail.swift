import Foundation

/// What an Error Tracking issue carries beyond a domain and a code, without the message: the Swift type and enum case say which of our own failures it was, and neither can hold a path, a name or an address.
public enum ErrorDetail {
    public static func properties(for error: Error) -> [String: String] {
        let nsError = error as NSError
        var details = ["error_domain": nsError.domain, "error_code": String(nsError.code)]
        if let causes = underlyingCauses(of: nsError) { details["error_underlying"] = causes }
        guard Mirror(reflecting: error).displayStyle == .enum else { return details }
        details["error_type"] = String(reflecting: type(of: error))
        details["error_case"] = String(String(describing: error).prefix { $0 != "(" })
        return details
    }

    /// The chain of errors wrapped inside this one, outermost first, as `domain:code`. A wrapper such as Sparkle's or a TLS failure says little until the cause under it is known.
    private static func underlyingCauses(of error: NSError) -> String? {
        var causes: [String] = []
        var current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let link = current, causes.count < 4 {
            causes.append("\(link.domain):\(link.code)")
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return causes.isEmpty ? nil : causes.joined(separator: " > ")
    }
}
