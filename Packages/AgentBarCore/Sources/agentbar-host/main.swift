import Foundation
import AgentBarCore

// agentbar-host: runs as the agent user (LaunchDaemon with UserName=agentbar). Dumb pipe between AgentBar (owner) and `claude`.
// Environment: AGENTBAR_IPC_DIR = directory of the group socket (default /Users/Shared/AgentBar). Nothing else is read from the environment.

setvbuf(stderr, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("agentbar-host: " + msg + "\n").utf8))
    exit(1)
}

guard geteuid() != 0 else { die("refusing to run as root; run as the agent user") }
guard let config = HostService.Config.current() else { die("cannot determine the current user") }

let ipc = ProcessInfo.processInfo.environment["AGENTBAR_IPC_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? HostRunner.defaultDirectory
let service = HostService(config: config)
let runner = HostRunner(service: service, ipcDirectory: URL(fileURLWithPath: ipc, isDirectory: true))

umask(0o077)
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler {
        runner.stop()   // terminates all children first
        exit(0)
    }
    s.resume()
    sources.append(s)
}

FileHandle.standardError.write(Data("agentbar-host: user \(config.user), work root \(config.workspaceRoot.path), ipc \(ipc)\n".utf8))
runner.runForever()
