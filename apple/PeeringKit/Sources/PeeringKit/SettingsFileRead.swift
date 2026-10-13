import Foundation

/// How a failed read of a user's settings file is understood. Only a file that is not there may be treated as empty: one that exists and cannot be read must be left alone, or the next write replaces it with `{}`.
public enum SettingsFileRead {
    public static func isAbsence(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        }
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) }
        return false
    }
}
