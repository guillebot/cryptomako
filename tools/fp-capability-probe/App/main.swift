import FileProvider
import Foundation

// CMProbe host: add | remove | phase N | mode M | signal | url
let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("probe"), displayName: "CMProbe")
let args = Array(CommandLine.arguments.dropFirst())

func run() async throws {
    switch args.first {
    case "add":
        try await NSFileProviderManager.add(domain)
        print("added")
    case "remove":
        try await NSFileProviderManager.remove(domain)
        print("removed")
    case "phase":
        ProbeControl.write("phase", args[1]); print("phase=\(args[1])")
        try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet); print("signalled")
    case "mode":
        ProbeControl.write("mode", args[1]); print("mode=\(args[1])")
    case "signal":
        try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet); print("signalled")
    case "url":
        print(try await NSFileProviderManager(for: domain)!.getUserVisibleURL(for: .rootContainer).path)
    default:
        print("usage: add|remove|phase N|mode M|signal|url")
    }
}

Task {
    do { try await run() } catch { print("error: \(error)") }
    exit(0)
}
dispatchMain()
