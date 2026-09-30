import AppKit
import Foundation

@main
enum UsoMain {
    static func main() {
        guard let options = CommandLineOptions.parse() else {
            fputs("Uso: invalid arguments. Use --help.\n", stderr)
            exit(2)
        }

        if options.showsHelp {
            print(CommandLineOptions.help)
            return
        }
        if options.runsSelfCheck {
            exit(SelfCheck.run() ? 0 : 1)
        }
        if let previewPath = options.previewPath {
            exit(renderPreview(path: previewPath, codexHome: options.codexHome) ? 0 : 1)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate(codexHome: options.codexHome, showsSettings: options.showsSettings)
        application.delegate = delegate
        application.run()
    }

    private static func renderPreview(path: URL, codexHome: URL) -> Bool {
        let result = UsageClient(codexHome: codexHome).load()
        let claude = ClaudeUsageClient().load()
        let codexPresentation = UsagePresentation(snapshot: result.snapshot, issue: result.issue, isRefreshing: false)
        let claudePresentation = UsagePresentation(snapshot: claude.snapshot, issue: claude.issue, isRefreshing: false)
        let rings = RingSettings().visible(codex: codexPresentation, claude: claudePresentation)
        let limits = rings.map { $0.limits(codex: codexPresentation, claude: claudePresentation) }
        do {
            let dimensions = try RingRenderer.writePreview(limits: limits, icons: rings.map(\.icon), to: path)
            print("Preview: \(path.path)")
            print("Dimensions: \(Int(dimensions.width))x\(Int(dimensions.height)) px (@2x)")
            print("Codex: \(result.snapshot?.source.rawValue ?? result.issue?.title ?? "Unavailable")")
            print("Claude: \(claude.snapshot?.source.rawValue ?? claude.issue?.title ?? "Unavailable")")
            return true
        } catch {
            fputs("Uso: could not write preview PNG.\n", stderr)
            return false
        }
    }
}
private struct CommandLineOptions {
    var codexHome: URL
    var previewPath: URL?
    var runsSelfCheck = false
    var showsHelp = false
    var showsSettings = false

    static let help = """
    Usage: Uso [--settings] [--self-check] [--preview PATH] [--codex-home PATH]

      --settings         Open ring settings on launch.
      --self-check       Run deterministic mapping and decoding checks, then exit.
      --preview PATH     Render enabled menu-bar rings to a PNG at 2x, then exit.
      --codex-home PATH  Override CODEX_HOME for CLI verification.
      --help             Show this help.
    """

    static func parse() -> CommandLineOptions? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        var options = CommandLineOptions(
            codexHome: URL(fileURLWithPath: environmentHome ?? home.appendingPathComponent(".codex").path)
        )
        var arguments = Array(CommandLine.arguments.dropFirst())

        while let argument = arguments.first {
            arguments.removeFirst()
            switch argument {
            case "--settings":
                options.showsSettings = true
            case "--self-check":
                options.runsSelfCheck = true
            case "--preview":
                guard let value = arguments.first else {
                    return nil
                }
                arguments.removeFirst()
                options.previewPath = URL(fileURLWithPath: value)
            case "--codex-home":
                guard let value = arguments.first else {
                    return nil
                }
                arguments.removeFirst()
                options.codexHome = URL(fileURLWithPath: value)
            case "--help", "-h":
                options.showsHelp = true
            default:
                return nil
            }
        }

        let modes = [options.runsSelfCheck, options.previewPath != nil, options.showsHelp, options.showsSettings].filter { $0 }.count
        return modes <= 1 ? options : nil
    }
}
