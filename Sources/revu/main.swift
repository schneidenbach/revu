import AppKit
import RevuCore

// A pipe closed on the other end (git exiting early, a caller that stopped reading our stdout) must show up
// as a failed write, never as a signal that kills the process mid-review. Must come before any git call.
signal(SIGPIPE, SIG_IGN)

// Argument and git errors are reported before AppKit is touched, so `--help` and failures work headless.
func fail(_ message: String) -> Never {
    Output.warn(message)
    exit(1)
}

let options: Options
switch Arguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .help:
    print(Arguments.usage)
    exit(0)
case let .failure(message):
    Output.write(Data("revu: \(message)\n\(Arguments.usage)\n".utf8), to: .standardError)
    exit(1)
case .version:
    print("revu \(Version.current)")
    exit(0)
case let .run(parsed):
    options = parsed
}

let (editor, editorWarning) = Editor.fromEnvironment(ProcessInfo.processInfo.environment["REVU_EDITOR"])
if let editorWarning { Output.warn(editorWarning) }

// Resolve repos synchronously before AppKit starts. (Not with top-level `await`: that would leave the
// main actor occupied by the async entry point for as long as `app.run()` runs, starving every Task.)
final class ResultBox: @unchecked Sendable { var result: Result<[RepoSnapshot], Error>? }
let box = ResultBox()
let loaded = DispatchSemaphore(value: 0)
let targets = options.targets, globalBase = options.base
Task.detached {
    do { box.result = .success(try await RepoSnapshot.loadAll(targets: targets, globalBase: globalBase)) }
    catch { box.result = .failure(error) }
    loaded.signal()
}
loaded.wait()

let snapshots: [RepoSnapshot]
switch box.result! {
case let .success(value): snapshots = value
case let .failure(error): fail(error.localizedDescription)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// revu is exec'd directly rather than launched via LaunchServices, so set the Dock icon explicitly.
if let icon = NSImage(named: "AppIcon") { app.applicationIconImage = icon }
let controller = AppController(state: AppState(snapshots: snapshots, options: options, externalEditor: editor))
app.delegate = controller
controller.start()
app.activate(ignoringOtherApps: true)
app.run()
