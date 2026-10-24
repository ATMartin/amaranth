public import Foundation

/// Debounced per-field saves for the notes editors. A save runs after `delay` without a newer edit of the same field,
/// or at once on `flush()` (meeting switch, collapsing an editor, closing, quitting) so typed text is never lost. Each
/// field has its own slot, so typing in one editor never cancels the other's save.
@MainActor public final class DebouncedSaves {
    public typealias Save = @MainActor (_ immediately: Bool) -> Void
    let delay: Duration
    private var pending: [String: (task: Task<Void, Never>, token: UUID, save: Save)] = [:]

    public init(delay: Duration = .seconds(1)) { self.delay = delay }

    public var hasPending: Bool { !pending.isEmpty }

    /// Replaces any pending save of `field`.
    public func schedule(_ field: String, _ save: @escaping Save) {
        pending[field]?.task.cancel()
        let token = UUID(), delay = delay
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let p = self.pending[field], p.token == token else { return }
            self.pending[field] = nil
            p.save(false)
        }
        pending[field] = (task, token, save)
    }

    /// Drops a pending save (the caller is about to save the latest value itself).
    public func cancel(_ field: String) {
        pending[field]?.task.cancel()
        pending[field] = nil
    }

    /// Runs every pending save now, synchronously.
    public func flush() {
        let all = pending
        pending = [:]
        for (_, p) in all { p.task.cancel(); p.save(true) }
    }
}

/// What a collapsed editor shows next to its title, so saved text is never invisible.
public enum CollapsedEditorHint {
    public static func text(for content: String) -> String? {
        let words = content.split(whereSeparator: \.isWhitespace).count
        return words == 0 ? nil : words == 1 ? "1 word" : "\(words) words"
    }
}
