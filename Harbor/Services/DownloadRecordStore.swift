import Foundation

/// Owns durable record sequencing and the serialization boundary shared by
/// record writes and state mutations that must be committed atomically.
@MainActor
final class DownloadRecordStore {
    typealias SaveOperation = @Sendable (
        DownloadPersistence,
        [DownloadRecord],
        DownloadPersistenceRevision
    ) async throws -> Void

    private struct MutationContext: Equatable, Sendable {
        let gateIdentifier: UUID
        let ownerToken: UUID
    }

    private enum CurrentMutation {
        @TaskLocal static var context: MutationContext?
    }

    private struct Waiter {
        let id: UUID
        let ownerToken: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let persistence: DownloadPersistence
    private let saveOperation: SaveOperation
    private let writerIdentifier = UUID()
    private let gateIdentifier = UUID()
    private var revision: UInt64 = 0
    private var gateOwner: UUID?
    private var waiters: [Waiter] = []

    init(
        persistence: DownloadPersistence,
        saveOperation: @escaping SaveOperation = { persistence, records, revision in
            try persistence.save(records, revision: revision)
        }
    ) {
        self.persistence = persistence
        self.saveOperation = saveOperation
    }

    func load() async throws -> [DownloadRecord] {
        try await persistence.load()
    }

    /// Evaluates `records` only after entering the serialization boundary so
    /// the snapshot cannot be captured while another durable mutation is
    /// suspended between its in-memory update and its record write.
    func save(records: () -> [DownloadRecord]) async throws {
        try await withExclusiveAccess {
            revision &+= 1
            let currentRevision = DownloadPersistenceRevision(
                writerIdentifier: writerIdentifier,
                value: revision
            )
            try await saveOperation(
                persistence,
                records(),
                currentRevision
            )
        }
    }

    func performSerializedMutation(
        _ operation: () async -> Void
    ) async {
        do {
            try await withExclusiveAccess {
                await operation()
            }
        } catch {
            // Acquiring the gate only fails when the caller is cancelled.
            // A cancelled mutation has not started and must not change state.
        }
    }

    private func withExclusiveAccess<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        if let context = CurrentMutation.context,
           context.gateIdentifier == gateIdentifier,
           gateOwner == context.ownerToken {
            return try await operation()
        }

        let ownerToken = UUID()
        try await acquireGate(ownerToken: ownerToken)
        defer { releaseGate(ownerToken: ownerToken) }

        return try await CurrentMutation.$context.withValue(
            MutationContext(
                gateIdentifier: gateIdentifier,
                ownerToken: ownerToken
            )
        ) {
            try await operation()
        }
    }

    private func acquireGate(ownerToken: UUID) async throws {
        try Task.checkCancellation()
        if gateOwner == nil {
            gateOwner = ownerToken
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard Task.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    Waiter(
                        id: waiterID,
                        ownerToken: ownerToken,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            // Cancellation can race with ownership transfer. If this waiter
            // was granted the gate, release it before propagating cancellation.
            if gateOwner == ownerToken {
                releaseGate(ownerToken: ownerToken)
            }
            throw error
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseGate(ownerToken: UUID) {
        guard gateOwner == ownerToken else {
            return
        }
        guard waiters.isEmpty == false else {
            gateOwner = nil
            return
        }
        let next = waiters.removeFirst()
        gateOwner = next.ownerToken
        next.continuation.resume()
    }
}
