import Foundation
import OSLog

/// Changes made one after the other, each described by a step that can be made again, and the
/// undos that revert them: what the albums of the Photos library, the files of a folder and the
/// copies of a photo share.
///
/// A change runs behind the ones in flight, undos and redos included: a redo may depend on what the
/// undo before it did. Making a step tells the step that reverts it, which only the work knows (a
/// new identifier, the files really moved): an undo is registered with the manager before its work
/// has run, and its own inverse is filled in once it has.
///
/// The undos are registered on this object: its owner must live as long as the windows whose undo
/// managers it is given.
final class UndoableSteps<Step: Sendable> {
    /// Makes a step and returns the step that reverts it; nil when nothing changed.
    private let perform: @MainActor (Step) async throws -> Step?
    /// The last change asked for; the next one waits for it.
    private var tail: Task<Void, Never>?
    private let logger: Logger

    /// `category` names the owner in the log.
    init(category: String, perform: @escaping @MainActor (Step) async throws -> Step?) {
        self.perform = perform
        logger = Logger(subsystem: "fr.michaelperrin.qaama", category: category)
    }

    /// Makes a step behind the changes in flight and returns the step that reverts it; nil when
    /// nothing changed.
    func run(_ step: Step) async throws -> Step? {
        let perform = perform
        return try await chain { try await perform(step) }.value
    }

    /// Registers the undo of a change just made, under the name the Edit menu shows. Nothing to
    /// register without a step to revert it or without a manager.
    func register(_ inverse: Step?, named name: String, with undoManager: UndoManager?) {
        guard let undoManager, let inverse else { return }
        register(PendingStep(inverse), named: name, with: undoManager)
    }

    /// Waits for the changes in flight, undos and redos included; for tests.
    func waitUntilIdle() async {
        await tail?.value
    }

    /// A step that reverts another, known once that other is done.
    private final class PendingStep {
        var step: Step?

        init(_ step: Step? = nil) {
            self.step = step
        }
    }

    /// Queues a change behind the ones in flight. Synchronous, so changes run in the order they were
    /// asked for, whatever the order their tasks start in.
    private func chain(_ operation: @escaping @MainActor () async throws -> Step?) -> Task<Step?, any Error> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return task
    }

    /// Registers an undo that makes `pending`'s step. Performed by the manager, it first registers its
    /// own inverse (the redo) synchronously, as the manager requires, then queues the work, which
    /// tells what that inverse is.
    private func register(_ pending: PendingStep, named name: String, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { steps in
            MainActor.assumeIsolated {
                let inverse = PendingStep()
                steps.register(inverse, named: name, with: undoManager)
                _ = steps.chain {
                    // No step: the change this one reverts failed, so there is nothing to revert.
                    guard let step = pending.step else { return nil }
                    do {
                        inverse.step = try await steps.perform(step)
                    } catch {
                        steps.logger.error("\(name, privacy: .public) not reverted: \(error.localizedDescription, privacy: .public)")
                    }
                    return nil
                }
            }
        }
        undoManager.setActionName(name)
    }
}
