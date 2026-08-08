import AppKit
import Foundation

@main
enum CodexUsageRingsMain {
    static func main() {
        guard let options = CommandLineOptions.parse() else {
            fputs("CodexUsageRings: invalid arguments. Use --help.\n", stderr)
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
        let delegate = AppDelegate(codexHome: options.codexHome)
        application.delegate = delegate
        application.run()
    }

    private static func renderPreview(path: URL, codexHome: URL) -> Bool {
        let result = UsageClient(codexHome: codexHome).load()
        guard let snapshot = result.snapshot, snapshot.hasAnyData else {
            fputs("CodexUsageRings: no current live or cached usage data for preview.\n", stderr)
            return false
        }
        do {
            let dimensions = try RingRenderer.writePreview(baseLimits: snapshot.baseLimits, to: path)
            print("Preview: \(path.path)")
            print("Dimensions: \(Int(dimensions.width))x\(Int(dimensions.height)) px (22x22 pt @2x)")
            print("Source: \(snapshot.source.rawValue)")
            return true
        } catch {
            fputs("CodexUsageRings: could not write preview PNG.\n", stderr)
            return false
        }
    }
}
private struct CommandLineOptions {
    var codexHome: URL
    var previewPath: URL?
    var runsSelfCheck = false
    var showsHelp = false

    static let help = """
    Usage: CodexUsageRings [--self-check] [--preview PATH] [--codex-home PATH]

      --self-check       Run deterministic mapping and decoding checks, then exit.
      --preview PATH     Render the current 22pt menu-bar rings to a 44x44 PNG, then exit.
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

        let modes = [options.runsSelfCheck, options.previewPath != nil, options.showsHelp].filter { $0 }.count
        return modes <= 1 ? options : nil
    }
}
