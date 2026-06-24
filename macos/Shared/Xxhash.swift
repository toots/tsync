import CXXHash
import Foundation

enum Xxhash {
    static func hashHex(_ data: Data, seed: UInt64) -> String {
        data.withUnsafeBytes { ptr in
            let hash = XXH3_64bits_withSeed(ptr.baseAddress, ptr.count, seed)
            return String(format: "%016llx", hash)
        }
    }
}
