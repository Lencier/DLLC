import Foundation
import Darwin

public enum OutputStream: Sendable { case stdout, stderr }

public struct ProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public init(executable: URL, arguments: [String], environment: [String: String] = ProcessSpec.defaultEnvironment(), workingDirectory: URL? = nil) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.workingDirectory = workingDirectory
    }
    public static func defaultEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONUTF8": "1"]
        for key in ["HOME", "TMPDIR", "USER"] { result[key] = inherited[key] }
        // The static FFmpeg uses OpenSSL, which doesn't know the macOS keychain: point it at the
        // system CA bundle so HTTPS certificate verification works (verification stays on).
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") { result["SSL_CERT_FILE"] = "/etc/ssl/cert.pem" }
        return result
    }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var terminationSignal: Int32?
    public var wasCancelled: Bool
    public var stdout: Data
    public var stderrTail: String
    public var succeeded: Bool { exitCode == 0 && !wasCancelled && terminationSignal == nil }
}

public enum ProcessSupervisorError: Error, Sendable {
    case spawnFailed(Int32, String)
}

// The leader is deliberately left unreaped during escalation: its PID pins the group ID,
// so a delayed signal can never hit a newly reused PID/process group.
private final class ProcessRun: @unchecked Sendable {
    let lock = NSLock()
    var pid: pid_t = 0
    var finished = false
    var cancelled = false
    var stopTime: TimeInterval?
    var killDelay: TimeInterval = 3
    var quitting = false
    var sentTerm = false

    func stop(quitTimeout: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        cancelled = true
        if let quitTimeout {
            quitting = true
            killDelay = max(0, quitTimeout)
            stopTime = ProcessInfo.processInfo.systemUptime
            if pid > 0 { kill(-pid, SIGTERM) }
        } else if stopTime == nil {
            stopTime = ProcessInfo.processInfo.systemUptime
            if pid > 0 { kill(-pid, SIGINT) }
        }
    }

    /// True once the child has exited, without reaping it (WNOWAIT keeps the PID reserved).
    static func leaderExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    func wait(readers: DispatchGroup) -> (Int32, Bool) {
        while true {
            lock.lock()
            // Descendants may still hold the pipes after the leader exits. Keep its PID
            // pinned until EOF, so cancellation can still safely kill that group.
            let readersDone = readers.wait(timeout: .now()) == .success
            var canReap = readersDone
            if let start = stopTime {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if !quitting && elapsed >= 1.5 && !sentTerm {
                    kill(-pid, SIGTERM); sentTerm = true
                }
                // Finish as soon as the leader has exited and the pipes closed; the un-reaped leader
                // still pins the group, so the final SIGKILL can only reach its own stragglers.
                canReap = elapsed >= killDelay || (readersDone && Self.leaderExited(pid))
                if canReap { kill(-pid, SIGKILL) }
            }
            var status: Int32 = 0
            let result = canReap ? waitpid(pid, &status, WNOHANG) : 0
            if result == pid || (result == -1 && errno != EINTR) {
                finished = true
                let wasCancelled = cancelled
                lock.unlock()
                return (status, wasCancelled)
            }
            lock.unlock()
            // Exit is noticed within 30 ms; polling faster only wakes the CPU more during long jobs.
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}

private struct ProcessIdentity: Codable {
    var pid: pid_t
    var pgid: pid_t
    var seconds: Int64
    var microseconds: Int32
    var executable: String

    static func read(_ pid: pid_t) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return ProcessIdentity(pid: pid, pgid: getpgid(pid), seconds: Int64(info.kp_proc.p_starttime.tv_sec),
                               microseconds: info.kp_proc.p_starttime.tv_usec, executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    func matches(_ other: ProcessIdentity) -> Bool {
        pid == other.pid && pgid == pid && other.pgid == pgid && seconds == other.seconds
            && microseconds == other.microseconds && executable == other.executable
    }
}

private final class PipeOutput: @unchecked Sendable {
    var data = Data()
    // Accessed by one reader, then only after its DispatchGroup has completed.
    func read(_ fd: Int32, stream: OutputStream, capture: Bool, onLine: (@Sendable (OutputStream, String) -> Void)?) {
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        var pending = Data()
        var previousCR = false
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            let chunk = bytes.prefix(count)
            if capture { data.append(contentsOf: chunk); continue }
            if stream == .stderr {
                data.append(contentsOf: chunk)
                if data.count > 16_384 { data.removeFirst(data.count - 16_384) }
            }
            guard let onLine else { continue }
            // Decode only complete lines, keeping partial UTF-8 sequences untouched between reads.
            for byte in chunk {
                if byte == 10 || byte == 13 {
                    if !(byte == 10 && previousCR) { onLine(stream, String(decoding: pending, as: UTF8.self)) }
                    pending.removeAll(keepingCapacity: true)
                    previousCR = byte == 13
                } else {
                    pending.append(byte); previousCR = false
                }
            }
        }
        if !pending.isEmpty { onLine?(stream, String(decoding: pending, as: UTF8.self)) }
    }
}

public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor()
    private let lock = NSLock()
    private var runs: [pid_t: ProcessRun] = [:]
    private var identities: [pid_t: ProcessIdentity] = [:]
    private var registryURL: URL?
    public init() {}
    public var runningCount: Int { lock.withLock { runs.count } }

    public func run(_ spec: ProcessSpec, captureStdout: Bool = false,
                    onLine: (@Sendable (OutputStream, String) -> Void)? = nil) async throws -> ProcessResult {
        let state = ProcessRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let (pid, outFD, errFD) = try self.spawn(spec, state: state)
                        let out = PipeOutput(), err = PipeOutput(), readers = DispatchGroup()
                        readers.enter()
                        DispatchQueue.global().async {
                            out.read(outFD, stream: .stdout, capture: captureStdout, onLine: onLine); readers.leave()
                        }
                        readers.enter()
                        DispatchQueue.global().async {
                            err.read(errFD, stream: .stderr, capture: false, onLine: onLine); readers.leave()
                        }
                        let (status, cancelled) = state.wait(readers: readers)
                        self.lock.withLock {
                            self.runs.removeValue(forKey: pid); self.identities.removeValue(forKey: pid)
                            self.saveRegistry()
                        }
                        readers.wait()
                        let signal = status & 0x7f
                        continuation.resume(returning: ProcessResult(exitCode: signal == 0 ? (status >> 8) & 0xff : -1,
                            terminationSignal: signal == 0 ? nil : signal, wasCancelled: cancelled,
                            stdout: out.data, stderrTail: String(decoding: err.data, as: UTF8.self)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.stop() }
    }

    private func spawn(_ spec: ProcessSpec, state: ProcessRun) throws -> (pid_t, Int32, Int32) {
        let path = spec.executable.path
        guard !([path] + spec.arguments + spec.environment.map { "\($0.key)=\($0.value)" } + [spec.workingDirectory?.path ?? ""]).contains(where: { $0.utf8.contains(0) }) else {
            throw ProcessSupervisorError.spawnFailed(EINVAL, path)
        }
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw ProcessSupervisorError.spawnFailed(errno, path) }
        guard pipe(&err) == 0 else {
            let code = errno; close(out[0]); close(out[1]); throw ProcessSupervisorError.spawnFailed(code, path)
        }
        var success = false
        defer {
            close(out[1]); close(err[1])
            if !success { close(out[0]); close(err[0]) }
        }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw ProcessSupervisorError.spawnFailed(code, path) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attr))
        defer { posix_spawnattr_destroy(&attr) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
        if let directory = spec.workingDirectory {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        try check(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try check(posix_spawnattr_setpgroup(&attr, 0))
        var signals: sigset_t = 0
        sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attr, &signals))
        sigfillset(&signals)
        try check(posix_spawnattr_setsigdefault(&attr, &signals))
        let argv = ([path] + spec.arguments).map { strdup($0) } + [nil]
        let env = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        // Serialize publication with terminateAll and cancellation, including cancellation before spawn.
        lock.lock(); defer { lock.unlock() }
        state.lock.lock(); defer { state.lock.unlock() }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, path, &actions, &attr, args.baseAddress!, environment.baseAddress!)
            }
        }
        try check(code)
        success = true
        state.pid = pid
        runs[pid] = state
        identities[pid] = ProcessIdentity.read(pid)
        saveRegistry()
        if state.cancelled { kill(-pid, state.quitting ? SIGTERM : SIGINT) }
        return (pid, out[0], err[0])
    }

    public func terminateAll(timeout: TimeInterval = 3) {
        let active = lock.withLock { Array(runs.values) }
        active.forEach { $0.stop(quitTimeout: timeout.isFinite ? max(0, timeout) : 3) }
        while active.contains(where: { state in state.lock.withLock { !state.finished } }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    public func configureRegistry(_ registryURL: URL) { lock.withLock { self.registryURL = registryURL } }
    private func saveRegistry() {
        guard let registryURL, let data = try? JSONEncoder().encode(Array(identities.values)) else { return }
        try? FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: registryURL, options: .atomic)
    }
    public func reapOrphans() -> Int {
        lock.withLock {
            guard let registryURL, let data = try? Data(contentsOf: registryURL),
                  let recorded = try? JSONDecoder().decode([ProcessIdentity].self, from: data) else { return 0 }
            var count = 0
            for identity in recorded where runs[identity.pid] == nil {
                if let current = ProcessIdentity.read(identity.pid), identity.matches(current) {
                    // SIGKILL avoids a delayed escalation targeting a subsequently reused group ID.
                    if kill(-identity.pgid, SIGKILL) == 0 { count += 1 }
                }
            }
            saveRegistry()
            return count
        }
    }
}
