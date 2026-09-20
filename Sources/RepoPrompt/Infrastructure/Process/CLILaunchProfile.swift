import Foundation

struct CLILaunchProfile: Equatable {
    let commandName: String
    let preferredBasenames: [String]
    let supplementalSearchPaths: [String]
}

enum CLILaunchProfiles {
    static let claudeCodeProviderSpecificPaths: [String] = [
        "~/.claude/local"
    ]

    static let openCodeProviderSpecificPaths: [String] = [
        "~/.opencode/bin"
    ]
    static let cursorProviderSpecificPaths: [String] = []
    /// Antigravity CLI (`agy`) installs into ~/.local/bin on Unix; supplement the
    /// native defaults with it so the resolver finds the binary regardless of the
    /// inherited child PATH.
    static let antigravityProviderSpecificPaths: [String] = [
        "~/.local/bin"
    ]

    /// Grok CLI (`grok`) is typically installed into ~/.local/bin or a Homebrew
    /// prefix on Unix; supplement the native defaults with these so the resolver
    /// finds the binary regardless of the inherited child PATH.
    static let grokProviderSpecificPaths: [String] = [
        "~/.local/bin"
    ]

    /// Official Devin installer location.
    static let devinProviderSpecificPaths: [String] = [
        "~/.local/bin"
    ]

    /// Official Grok Build installer location (`GROK_BIN_DIR` overrides it, but a custom
    /// value is honored through PATH or an explicitly configured absolute command only).
    static let grokBuildProviderSpecificPaths: [String] = [
        "~/.grok/bin"
    ]

    /// Preserve the committed Codex hint order exactly: shell/package-manager
    /// fallbacks first, then Codex.app resources. System bins are intentionally not
    /// added as supplemental hints because the resolver already searches the built
    /// child PATH, which comes from the user's shell/inherited environment.
    static let codexSupplementalSearchPaths: [String] = orderedUnique(
        CLINativePathDefaults.homebrewBins +
            CLINativePathDefaults.nodePackageManagerBins +
            [
                "~/.bun/bin"
            ] +
            CLINativePathDefaults.versionManagerShimBins +
            [
                "~/.cargo/bin",
                "~/.local/bin",
                "~/bin",
                "~/go/bin",
                "/Applications/Codex.app/Contents/Resources"
            ]
    )

    static let claudeCode = CLILaunchProfile(
        commandName: "claude",
        preferredBasenames: ["claude"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: claudeCodeProviderSpecificPaths)
    )

    static let codex = CLILaunchProfile(
        commandName: "codex",
        preferredBasenames: ["codex"],
        supplementalSearchPaths: codexSupplementalSearchPaths
    )

    static let openCode = CLILaunchProfile(
        commandName: "opencode",
        preferredBasenames: ["opencode"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(openCodeProviderSpecificPaths)
    )

    static let cursor = CLILaunchProfile(
        commandName: "cursor-agent",
        preferredBasenames: ["cursor-agent"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: cursorProviderSpecificPaths)
    )

    static let antigravity = CLILaunchProfile(
        commandName: "agy",
        preferredBasenames: ["agy"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: antigravityProviderSpecificPaths)
    )

    static let grok = CLILaunchProfile(
        commandName: "grok",
        preferredBasenames: ["grok"],
        supplementalSearchPaths: nativeDefaultsSupplemented(with: grokProviderSpecificPaths)
    )

    static let devin = CLILaunchProfile(
        commandName: "devin",
        preferredBasenames: ["devin"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(devinProviderSpecificPaths)
    )

    static let grokBuild = CLILaunchProfile(
        commandName: "grok",
        preferredBasenames: ["grok"],
        supplementalSearchPaths: providerSpecificPathsSupplementedWithNativeDefaults(grokBuildProviderSpecificPaths)
    )

    static func nativeDefaultsSupplemented(with providerSpecificPaths: [String]) -> [String] {
        orderedUnique(CLINativePathDefaults.defaultAdditionalPaths + providerSpecificPaths)
    }

    static func providerSpecificPathsSupplementedWithNativeDefaults(_ providerSpecificPaths: [String]) -> [String] {
        orderedUnique(providerSpecificPaths + CLINativePathDefaults.defaultAdditionalPaths)
    }

    private static func orderedUnique(_ paths: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }
}
