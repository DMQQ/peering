import Foundation

/// Which git the host may start. On a Mac without developer tools `/usr/bin/git` is a stub that opens a system install dialog, so it is used only when the tools it forwards to exist.
public enum AgentGitLocator {
    public static let missingMessage = "git is not installed on this Mac. Install the Xcode Command Line Tools (run xcode-select --install in Terminal) to review changes."

    private static let commandLineTools = "/Library/Developer/CommandLineTools/usr/bin/git"
    private static let packageManagerPaths = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]

    /// `developerDirectory` is where `xcode-select` points, nil when it points nowhere.
    public static func executable(exists: (String) -> Bool, developerDirectory: String?) -> String? {
        if let developerDirectory, exists(developerDirectory + "/usr/bin/git") { return "/usr/bin/git" }
        if exists(commandLineTools) { return "/usr/bin/git" }
        return packageManagerPaths.first(where: exists)
    }
}
