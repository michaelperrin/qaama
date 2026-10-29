/// Carries a non-Sendable framework object across an isolation boundary when the framework guarantees
/// a single hand-over (PhotoKit completion handlers). Use only where that guarantee is documented.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
