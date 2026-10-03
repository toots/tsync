import Foundation

/// §6.8: the range served for a partial fetch. It only grows outwards, starts
/// aligned, has an aligned length except at end of file, and is empty past it.
func alignedRange(_ requested: NSRange, alignment: Int, documentSize: Int64) -> (
    start: Int64, length: Int64
) {
    let size = max(0, documentSize)
    let unit = Int64(max(1, alignment))
    let wantStart = Int64(max(0, requested.location == NSNotFound ? 0 : requested.location))
    let start = wantStart - wantStart % unit
    let wantEnd = min(size, wantStart + Int64(max(0, requested.length)))
    if start >= size || wantEnd <= start { return (min(start, size), 0) }
    let roundedEnd = (wantEnd + unit - 1) / unit * unit
    let end = min(roundedEnd, size)
    return (start, end - start)
}
