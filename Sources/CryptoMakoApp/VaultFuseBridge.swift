import CryptoMakoVault
import Foundation

/// Bridges async `VaultSession` into synchronous macFUSE callbacks.
final class VaultFuseBridge: @unchecked Sendable {
    private let session: VaultSession
    private let lock = NSLock()

    init(session: VaultSession) {
        self.session = session
    }

    func call<T>(_ work: @escaping (VaultSession) async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [session] in
            do {
                box.value = .success(try await work(session))
            } catch {
                box.value = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try box.value!.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
}
