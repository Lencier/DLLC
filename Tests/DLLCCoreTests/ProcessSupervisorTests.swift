import Foundation
import Darwin
import Testing
@testable import DLLCCore

private final class ProcessLines: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    func append(_ stream: DLLCCore.OutputStream, _ line: String) {
        lock.withLock { if stream == .stdout { out.append(line) } else { err.append(line) } }
    }
    var stdout: [String] { lock.withLock { out } }
    var stderr: [String] { lock.withLock { err } }
}

struct ProcessSupervisorTests {
    private func shell(_ command: String) -> ProcessSpec {
        ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
    }

    @Test func linesAndPartialUTF8() async throws {
        let lines = ProcessLines()
        let result = try await ProcessSupervisor().run(shell("printf 'one\\rtwo\\r\\nthree\\n'; printf '\\340'; sleep 0.03; printf '\\270\\201\\nlast'; printf 'error\\rtail' >&2")) {
            lines.append($0, $1)
        }
        #expect(result.succeeded)
        #expect(lines.stdout == ["one", "two", "three", "ก", "last"])
        #expect(lines.stderr == ["error", "tail"])
        #expect(result.stdout.isEmpty)
        #expect(result.stderrTail == "error\rtail")
    }

    @Test func largeConcurrentOutputAndCapture() async throws {
        let lines = ProcessLines()
        let result = try await ProcessSupervisor().run(shell("/bin/dd if=/dev/zero bs=1048576 count=6 2>/dev/null & /bin/dd if=/dev/zero bs=1048576 count=6 1>&2 2>/dev/null; wait"), captureStdout: true) {
            if $0 == .stdout { lines.append($0, $1) }
        }
        #expect(result.succeeded)
        #expect(result.stdout.count >= 6 * 1_048_576)
        #expect(result.stderrTail.utf8.count == 16_384)
        #expect(lines.stdout.isEmpty)
    }

    @Test func exitAndSpawnFailure() async throws {
        let supervisor = ProcessSupervisor()
        let failed = try await supervisor.run(shell("exit 42"))
        #expect(failed.exitCode == 42)
        #expect(!failed.succeeded)
        #expect(failed.terminationSignal == nil)
        let signalled = try await supervisor.run(shell("kill -TERM $$"))
        #expect(signalled.exitCode == -1)
        #expect(signalled.terminationSignal == SIGTERM)
        do {
            _ = try await supervisor.run(ProcessSpec(executable: URL(fileURLWithPath: "/nonexistent/dllc-test"), arguments: []))
            Issue.record("Missing executable should throw")
        } catch ProcessSupervisorError.spawnFailed(let code, let path) {
            #expect(code == ENOENT); #expect(path == "/nonexistent/dllc-test")
        }
        #expect(supervisor.runningCount == 0)
    }

    @Test(arguments: ["echo $$; sleep 100 & sleep 100; wait", "sleep 100 & echo $$; exit 0"])
    func cancellationKillsGrandchildren(command: String) async throws {
        let supervisor = ProcessSupervisor(), lines = ProcessLines()
        let task = Task {
            try await supervisor.run(shell(command)) { lines.append($0, $1) }
        }
        for _ in 0..<200 {
            if !lines.stdout.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(lines.stdout.first.flatMap(Int32.init))
        #expect(supervisor.runningCount == 1)
        task.cancel()
        let result = try await task.value
        #expect(result.wasCancelled)
        #expect(!result.succeeded)
        // init may need a moment to reap the orphaned grandchildren after the group kill.
        for _ in 0..<100 {
            if kill(-pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(-pid, 0) == -1)
        #expect(errno == ESRCH)
        #expect(supervisor.runningCount == 0)
    }

    @Test func cancellationBeforeSpawnAndTerminateAll() async throws {
        let supervisor = ProcessSupervisor()
        let task = Task { try await supervisor.run(shell("sleep 100")) }
        task.cancel()
        #expect(try await task.value.wasCancelled)
        let next = Task { try await supervisor.run(shell("trap '' TERM; sleep 100")) }
        for _ in 0..<200 {
            if supervisor.runningCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        supervisor.terminateAll(timeout: 0.05)
        #expect(try await next.value.wasCancelled)
        #expect(supervisor.runningCount == 0)
    }

    @Test func environmentWorkingDirectoryAndRegistryIdentity() async throws {
        let supervisor = ProcessSupervisor(), lines = ProcessLines()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("processes.json")
        supervisor.configureRegistry(registry)
        let task = Task {
            try await supervisor.run(ProcessSpec(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", "echo $$; pwd; printf '%s\\n' \"$DLLC_TEST\"; sleep 100; echo finished"], environment: ["DLLC_TEST": "ไทย"], workingDirectory: directory)) { lines.append($0, $1) }
        }
        for _ in 0..<200 {
            if lines.stdout.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lines.stdout.dropFirst().first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == directory.resolvingSymlinksInPath().path)
        #expect(lines.stdout.last == "ไทย")
        defer { task.cancel() }
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]])
        try #require(records.count == 1)
        // A reused PID with a different start time MUST NOT be signalled.
        records[0]["seconds"] = 0
        let stale = directory.appendingPathComponent("stale.json")
        try JSONSerialization.data(withJSONObject: records).write(to: stale)
        let recovery = ProcessSupervisor()
        recovery.configureRegistry(stale)
        #expect(recovery.reapOrphans() == 0)
        #expect(supervisor.runningCount == 1)
        // A genuine matching identity is recovered by a fresh supervisor.
        recovery.configureRegistry(registry)
        try #require(recovery.reapOrphans() == 1)
        let result = try await task.value
        #expect(result.terminationSignal == SIGKILL)
    }
}
