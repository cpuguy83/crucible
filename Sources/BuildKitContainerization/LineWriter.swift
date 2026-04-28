import Foundation
import BuildKitCore
@preconcurrency import Containerization
import ContainerizationOCI
import ContainerizationExtras
import SystemPackage

/// `Writer` adapter that captures bytes from a guest process and forwards
/// each newline-delimited line to a continuation as a `String`.
///
/// Used to feed buildkitd's stdout/stderr into `BuildKitBackend.logStream`.
final class LineWriter: @unchecked Sendable, Containerization.Writer {
    private let continuation: AsyncStream<String>.Continuation
    private let prefix: String
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init(prefix: String, continuation: AsyncStream<String>.Continuation) {
        self.prefix = prefix
        self.continuation = continuation
    }

    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        buffer.append(data)
        flushLines()
    }

    func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if !buffer.isEmpty {
            if let s = String(data: buffer, encoding: .utf8) {
                continuation.yield("\(prefix) \(s)")
            }
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func flushLines() {
        let nl = UInt8(0x0A)
        while let i = buffer.firstIndex(of: nl) {
            let line = buffer.subdata(in: 0..<i)
            buffer.removeSubrange(0...i)
            if let s = String(data: line, encoding: .utf8) {
                continuation.yield("\(prefix) \(s)")
            }
        }
    }
}
