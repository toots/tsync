import Foundation

/// Which range a partial fetch actually reads.
///
/// The system asks for the range an application touched and hands over an
/// alignment it wants the answer to respect: the start a multiple of it, and the
/// length too — except at the end of the file, the one place a short length is
/// expected, checked against the item's `documentSize`. The alignment is a power
/// of two and is not stable across reboots, so it can never be baked in.
///
/// Rounding goes outwards, never inwards. An answer that missed even one
/// requested byte would leave the application reading a hole and calling it
/// content, so growing the range is the only safe direction — and it is free
/// here, since a chunk the range now reaches into had to be fetched whole
/// regardless.
enum PartialRange {
    /// The aligned range covering `requested`, clamped to the file.
    static func aligned(covering requested: NSRange,
                        alignment: Int,
                        documentSize: Int64) -> NSRange {
        let size = Int(clamping: max(0, documentSize))
        // An alignment of zero would divide by zero, and one aligns to nothing.
        let unit = max(1, alignment)

        let wantStart = max(0, requested.location)
        let start = wantStart - (wantStart % unit)
        let wantEnd = min(size, wantStart + max(0, requested.length))

        // Nothing to serve past the end of the file. Said explicitly, because
        // clamping the start to the file first would instead round back into it
        // and answer with its last few bytes — bytes nobody asked for, reported
        // as though they were the range that was.
        guard start < size, wantEnd > start else {
            return NSRange(location: min(start, size), length: 0)
        }

        let rounded = wantEnd.isMultiple(of: unit)
            ? wantEnd
            : (wantEnd / unit + 1) * unit
        return NSRange(location: start, length: min(rounded, size) - start)
    }
}
