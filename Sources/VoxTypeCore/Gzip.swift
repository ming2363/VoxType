import CGZip
import Foundation

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            var dst: UnsafeMutablePointer<UInt8>?
            var length = 0
            let code = voxtype_gzip_compress(base, data.count, &dst, &length)
            guard code == 0, let dst else { return nil }
            defer { voxtype_free(dst) }
            return Data(bytes: dst, count: length)
        }
    }

    static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var dst: UnsafeMutablePointer<UInt8>?
            var length = 0
            let code = voxtype_gzip_decompress(base, data.count, &dst, &length)
            guard code == 0, let dst else { return nil }
            defer { voxtype_free(dst) }
            return Data(bytes: dst, count: length)
        }
    }
}
