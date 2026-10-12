import Foundation

extension LocalizedStringResource {
    /// The source-language sentence, whatever language the Mac is set to.
    public var englishText: String {
        var english = self
        english.locale = Locale(identifier: "en")
        return String(localized: english)
    }
}
