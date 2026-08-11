import Darwin
import Foundation

enum ManagedChildProcessError: LocalizedError {
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .spawnFailed(code):
            String(cString: strerror(code))
        }
    }
}

final class ManagedChildProcess: @unchecked Sendable {
    typealias OutputHandler = @Sendable (String) -> Void
    typealias TerminationHandler = @Sendable (ManagedChildProcessTermination) -> Void

    nonisolated let processIdentifier: pid_t

    nonisolated private let lock = NSLock()
    nonisolated private let stdoutHandle: FileHandle
    nonisolated private let stderrHandle: FileHandle
    nonisolated private let outputReaders = DispatchGroup()
    nonisolated private let onTermination: TerminationHandler
    nonisolated(unsafe) private var hasExited = false
    nonisolated(unsafe) private var hasObservedExitWithoutReaping = false
    nonisolated(unsafe) private var hasRequestedTermination = false
    nonisolated(unsafe) private var hasNotifiedTermination = false
    nonisolated(unsafe) private var shouldStopOutputReaders = false

    nonisolated init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onStdout: @escaping OutputHandler,
        onStderr: @escaping OutputHandler,
        onTermination: @escaping TerminationHandler
    ) throws {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else {
            throw ManagedChildProcessError.spawnFailed(errno)
        }
        guard pipe(&stderrPipe) == 0 else {
            let pipeError = errno
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            throw ManagedChildProcessError.spawnFailed(pipeError)
        }

        if let relocationError = Self.relocateStandardDescriptors(
            in: &stdoutPipe,
            and: &stderrPipe
        ) {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            throw ManagedChildProcessError.spawnFailed(relocationError)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsResult == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            throw ManagedChildProcessError.spawnFailed(fileActionsResult)
        }
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            posix_spawn_file_actions_destroy(&fileActions)
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            throw ManagedChildProcessError.spawnFailed(attributesResult)
        }

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let configurationResults = [
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1]),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        ]
        if let configurationError = configurationResults.first(where: { $0 != 0 }) {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            throw ManagedChildProcessError.spawnFailed(configurationError)
        }

        var pid = pid_t()
        let argv = [executableURL.lastPathComponent] + arguments
        let env = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        let spawnResult = executableURL.path.withCString { path in
            withCStringArray(argv) { argvPointer in
                withCStringArray(env) { envPointer in
                    posix_spawn(&pid, path, &fileActions, &attributes, argvPointer, envPointer)
                }
            }
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw ManagedChildProcessError.spawnFailed(spawnResult)
        }

        self.processIdentifier = pid
        self.stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        self.stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        self.onTermination = onTermination

        startOutputReader(stdoutHandle, onOutput: onStdout)
        startOutputReader(stderrHandle, onOutput: onStderr)
        waitForExit()
    }

    nonisolated func terminate(grace: TimeInterval = 2) {
        let shouldScheduleEscalation = lock.withLock {
            guard hasExited == false, hasRequestedTermination == false else {
                return false
            }
            hasRequestedTermination = true
            // waitForExit observes termination with WNOWAIT and deliberately
            // keeps this direct child unreaped until its output descendants
            // are quiescent. The PID therefore remains reserved while this
            // lock is held, making the private process-group signal immune to
            // numeric PID/PGID reuse.
            _ = Darwin.kill(-processIdentifier, SIGTERM)
            return true
        }
        guard shouldScheduleEscalation else {
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
            self?.signalOwnedProcessGroup(SIGKILL)
        }
    }

    nonisolated var isRunning: Bool {
        lock.withLock {
            hasExited == false
        }
    }

    private nonisolated func signalOwnedProcessGroup(_ signal: Int32) {
        lock.withLock {
            guard hasExited == false else {
                return
            }
            _ = Darwin.kill(-processIdentifier, signal)
        }
    }

    private nonisolated func startOutputReader(
        _ handle: FileHandle,
        onOutput: @escaping OutputHandler
    ) {
        outputReaders.enter()
        DispatchQueue.global(qos: .utility).async { [weak self, outputReaders] in
            defer {
                try? handle.close()
                outputReaders.leave()
            }

            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                guard let self,
                      self.lock.withLock({ self.shouldStopOutputReaders == false }) else {
                    break
                }
                var descriptor = pollfd(
                    fd: handle.fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&descriptor, 1, 100)
                if pollResult == 0 {
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    break
                }
                let byteCount = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
                }
                if byteCount > 0 {
                    pending.append(contentsOf: bytes.prefix(Int(byteCount)))
                    while let newlineIndex = pending.firstIndex(of: 0x0A) {
                        let endIndex = pending.index(after: newlineIndex)
                        let line = pending[..<endIndex]
                        pending.removeSubrange(..<endIndex)
                        if self.lock.withLock({ self.shouldStopOutputReaders == false }) {
                            onOutput(String(decoding: line, as: UTF8.self))
                        }
                    }
                    continue
                }
                if byteCount < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                }
                break
            }

            if let self,
               pending.isEmpty == false,
               self.lock.withLock({ self.shouldStopOutputReaders == false }) {
                onOutput(String(decoding: pending, as: UTF8.self))
            }
        }
    }

    private nonisolated func waitForExit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            // Observe exit without reaping. Keeping the session leader as a
            // zombie reserves both its PID and its process-group identifier
            // until all inherited output pipes have been quiesced.
            var exitInformation = siginfo_t()
            var observationResult: Int32
            repeat {
                observationResult = waitid(
                    P_PID,
                    id_t(self.processIdentifier),
                    &exitInformation,
                    WEXITED | WNOWAIT
                )
            } while observationResult == -1 && errno == EINTR
            guard observationResult == 0 else {
                return
            }
            self.lock.withLock {
                self.hasObservedExitWithoutReaping = true
            }

            // POSIX only guarantees that all bytes written before the child
            // exits can be read after its exit is observable. Deliver those bytes
            // before reporting termination so callers can safely interpret a
            // final path or error line emitted immediately before exit.
            if self.outputReaders.wait(timeout: .now() + 1) == .timedOut {
                // A descendant can inherit the pipes and survive the leader.
                self.signalOwnedProcessGroup(SIGTERM)
            }
            if self.outputReaders.wait(timeout: .now() + 1) == .timedOut {
                self.signalOwnedProcessGroup(SIGKILL)
            }
            if self.outputReaders.wait(timeout: .now() + 1) == .timedOut {
                // A kernel/pipe anomaly must not prevent the process lifecycle
                // from reaching its terminal callback indefinitely. Readers
                // poll rather than block permanently, so ask them to retire
                // without closing a descriptor out from under an active read.
                self.lock.withLock {
                    self.shouldStopOutputReaders = true
                }
                _ = self.outputReaders.wait(timeout: .now() + 1)
            }

            var status: Int32 = 0
            let reapedPID: pid_t = self.lock.withLock {
                var result: pid_t
                repeat {
                    result = waitpid(self.processIdentifier, &status, 0)
                } while result == -1 && errno == EINTR
                // Publish terminal ownership while still holding the same lock
                // used by every signal. There is no check-to-signal window in
                // which this PID can be reaped, reused, and targeted again.
                self.hasExited = true
                return result
            }
            guard reapedPID == self.processIdentifier else {
                return
            }
            self.notifyTermination(status: status)
        }
    }

    private nonisolated func notifyTermination(status: Int32) {
        let shouldNotify = lock.withLock {
            guard hasNotifiedTermination == false else {
                return false
            }

            hasNotifiedTermination = true
            return true
        }

        guard shouldNotify else {
            return
        }

        onTermination(ManagedChildProcessTermination(waitStatus: status))
    }

    private nonisolated static func relocateStandardDescriptors(
        in firstPipe: inout [Int32],
        and secondPipe: inout [Int32]
    ) -> Int32? {
        for index in firstPipe.indices where firstPipe[index] <= STDERR_FILENO {
            let relocated = fcntl(firstPipe[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard relocated >= 0 else {
                return errno
            }
            close(firstPipe[index])
            firstPipe[index] = relocated
        }
        for index in secondPipe.indices where secondPipe[index] <= STDERR_FILENO {
            let relocated = fcntl(secondPipe[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard relocated >= 0 else {
                return errno
            }
            close(secondPipe[index])
            secondPipe[index] = relocated
        }
        return nil
    }
}

struct ManagedChildProcessTermination: Sendable {
    let waitStatus: Int32

    nonisolated var exitCode: Int32? {
        guard waitStatus & 0x7f == 0 else {
            return nil
        }

        return (waitStatus >> 8) & 0xff
    }

    nonisolated var signal: Int32? {
        let signal = waitStatus & 0x7f
        return signal == 0 ? nil : signal
    }

    nonisolated var isSuccess: Bool {
        exitCode == 0
    }
}

private nonisolated func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) rethrows -> Result {
    let cStrings = strings.map { strdup($0) }
    defer {
        for cString in cStrings {
            free(cString)
        }
    }

    var pointers = cStrings
    pointers.append(nil)

    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
