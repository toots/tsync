import Foundation

/// Which range a partial fetch actually reads.
///
/// The system hands over an alignment the answer must respect in both start and
/// length, except at end of file where a short length is expected (checked
/// against `documentSize`). The alignment is a power of two and is not stable
/// across reboots, so it can never be baked in.
///
/// Rounding goes outwards only: missing even one requested byte leaves the
/// application reading a hole as content. Growing is free, since a chunk the
/// range reaches into had to be fetched whole anyway.
enum PartialRange {
    /// The aligned range covering `requested`, clamped to the file.
    static func aligned(covering requested: NSRange,
                        alignment: Int,
                        documentSize: Int64) -> NSRange {
        let size = Int(clamping: max(0, documentSize))
        // Zero would divide by zero; one aligns to nothing.
        let unit = max(1, alignment)

        let wantStart = max(0, requested.location)
        let start = wantStart - (wantStart % unit)
        let wantEnd = min(size, wantStart + max(0, requested.length))

        // Explicit, because clamping the start first would round back into the
        // file and answer with its last few bytes as if they were the range
        // asked for.
        guard start < size, wantEnd > start else {
            return NSRange(location: min(start, size), length: 0)
        }

        let rounded = wantEnd.isMultiple(of: unit)
            ? wantEnd
            : (wantEnd / unit + 1) * unit
        return NSRange(location: start, length: min(rounded, size) - start)
    }
}
