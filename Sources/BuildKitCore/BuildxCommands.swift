import Foundation

/// Pure helpers that produce shell-friendly strings for integrating a
/// running BuildKit endpoint with common host tooling (`docker buildx`,
/// `buildctl`).
///
/// Lives in `BuildKitCore` so it's testable without UI or process exec.
public enum BuildxCommands {
    /// Default builder name used when registering Crucible with buildx.
    public static let defaultBuilderName = "crucible"

    /// `unix://` URL form of the endpoint, with the path percent-encoded
    /// so spaces and other URL-reserved characters survive shell quoting
    /// and most CLI parsers.
    public static func unixURL(for endpoint: BuildKitEndpoint) -> String {
        let allowed = CharacterSet.urlPathAllowed
        let encoded = endpoint.socketPath
            .addingPercentEncoding(withAllowedCharacters: allowed)
            ?? endpoint.socketPath
        return "unix://\(encoded)"
    }

    /// `BUILDKIT_HOST=unix://...` line ready to paste into a shell or
    /// `.envrc`. The URL is single-quoted so spaces in the host path
    /// don't trip word-splitting; single quotes are safe for unix paths
    /// because we forbid `'` from valid paths upstream of this.
    public static func buildKitHostEnv(for endpoint: BuildKitEndpoint) -> String {
        "BUILDKIT_HOST='\(unixURL(for: endpoint))'"
    }

    /// `docker buildx create ...` invocation as a single shell line.
    /// The endpoint URL is single-quoted; the builder name is interpolated
    /// directly because we control its character set.
    public static func dockerBuildxCreateCommand(
        for endpoint: BuildKitEndpoint,
        builderName: String = BuildxCommands.defaultBuilderName,
        useAfterCreate: Bool = true
    ) -> String {
        let url = unixURL(for: endpoint)
        var line =
            "docker buildx create --name \(builderName) --driver remote '\(url)'"
        if useAfterCreate {
            line += " && docker buildx use \(builderName)"
        }
        return line
    }

    /// argv form of `docker buildx create ...` for execution via
    /// `Process` / `posix_spawn`. Avoids shell quoting entirely.
    public static func dockerBuildxCreateArguments(
        for endpoint: BuildKitEndpoint,
        builderName: String = BuildxCommands.defaultBuilderName
    ) -> [String] {
        // Pass the raw socket path inside the URL — the CLI's URL parser
        // accepts unencoded spaces as long as we don't go through a shell.
        [
            "buildx", "create",
            "--name", builderName,
            "--driver", "remote",
            "unix://\(endpoint.socketPath)",
        ]
    }

    /// argv to remove the builder.
    public static func dockerBuildxRemoveArguments(
        builderName: String = BuildxCommands.defaultBuilderName
    ) -> [String] {
        ["buildx", "rm", builderName]
    }

    /// argv to inspect (used to detect "already registered").
    public static func dockerBuildxInspectArguments(
        builderName: String = BuildxCommands.defaultBuilderName
    ) -> [String] {
        ["buildx", "inspect", builderName]
    }
}
