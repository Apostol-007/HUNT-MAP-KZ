import Foundation
import CryptoKit
import HuntCore

/// Awaited work with cancellation propagation; never runs file IO on MainActor.
enum HuntBackgroundWork {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let job = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler(operation: {
            let value = try await job.value
            try Task.checkCancellation()
            return value
        }, onCancel: { job.cancel() })
    }
    static func digest(_ file: URL, pmtiles: Bool = false) async throws -> String {
        try await run {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            if pmtiles {
                let magic = try handle.read(upToCount: 8) ?? Data()
                guard magic.count == 8, Data(magic.prefix(7)) == Data("PMTiles".utf8), magic[7] == 3 else {
                    throw NSError(domain: "Protomaps", code: 6, userInfo: [NSLocalizedDescriptionKey: "Не PMTiles v3"])
                }
                try handle.seek(toOffset: 0)
            }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
                if bytes.isEmpty { break }
                hash.update(data: bytes)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    static func append(_ source: URL, to destination: URL) async throws {
        try await run {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            try output.seekToEnd()
            while true {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: 1_048_576) ?? Data()
                if bytes.isEmpty { break }
                try output.write(contentsOf: bytes)
            }
            try output.synchronize()
        }
    }
}
