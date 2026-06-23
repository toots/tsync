import Foundation
import Testing

// MARK: - Encode / decode

@Test func journalEncodeDecodePut() throws {
    let ops = [JournalOp(op: "put", key: "foo.wav", size: 12345678)]
    let data = Journal.encode(ops)
    let decoded = Journal.decode(data)
    #expect(decoded.count == 1)
    #expect(decoded[0].op == "put")
    #expect(decoded[0].key == "foo.wav")
    #expect(decoded[0].size == 12345678)
    #expect(decoded[0].src == nil)
}

@Test func journalEncodeDecodeRename() throws {
    let ops = [JournalOp(op: "rename", key: "new.wav", src: "old.wav", size: 999)]
    let decoded = Journal.decode(Journal.encode(ops))
    #expect(decoded.count == 1)
    #expect(decoded[0].op == "rename")
    #expect(decoded[0].src == "old.wav")
    #expect(decoded[0].key == "new.wav")
    #expect(decoded[0].size == 999)
}

@Test func journalEncodeDecodeMultiple() throws {
    let ops = [
        JournalOp(op: "put", key: "a.wav", size: 100),
        JournalOp(op: "delete", key: "b.wav"),
        JournalOp(op: "mkdir", key: "subdir/"),
    ]
    let decoded = Journal.decode(Journal.encode(ops))
    #expect(decoded.count == 3)
    #expect(decoded[0].op == "put")
    #expect(decoded[1].op == "delete")
    #expect(decoded[2].op == "mkdir")
}

@Test func journalDecodeSkipsMalformedLines() throws {
    let ndjson = """
    {"op":"put","key":"foo.wav","size":1}
    not json at all
    {"op":"delete","key":"bar.wav"}
    """.data(using: .utf8)!
    let decoded = Journal.decode(ndjson)
    #expect(decoded.count == 2)
    #expect(decoded[0].op == "put")
    #expect(decoded[1].op == "delete")
}

@Test func journalEncodeProducesOneLinePerOp() throws {
    let ops = [
        JournalOp(op: "put", key: "a.wav", size: 1),
        JournalOp(op: "delete", key: "b.wav"),
    ]
    let str = String(data: Journal.encode(ops), encoding: .utf8)!
    let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    for line in lines {
        #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
    }
}

// MARK: - Entry key format

@Test func journalEntryKeyFormat() throws {
    let key = Journal.entryKey()
    // Format: <13-digit-ms>-<UUID>
    let dashIdx = key.index(key.startIndex, offsetBy: 13)
    let ts = String(key[..<dashIdx])
    let uuidPart = String(key[key.index(after: dashIdx)...])
    #expect(ts.count == 13)
    #expect(Int64(ts) != nil)
    #expect(UUID(uuidString: uuidPart) != nil)
}

@Test func journalTimestampFromFilename() throws {
    let filename = "1705312200123-550E8400-E29B-41D4-A716-446655440000"
    #expect(Journal.timestampMs(fromFilename: filename) == 1705312200123)
}

@Test func journalClientUUIDFromFilename() throws {
    let filename = "1705312200123-550E8400-E29B-41D4-A716-446655440000"
    #expect(Journal.clientUUID(fromFilename: filename) == "550E8400-E29B-41D4-A716-446655440000")
}

@Test func journalEntryKeysAreLexicographicallySortedByTime() throws {
    let k1 = Journal.entryKey()
    Thread.sleep(forTimeInterval: 0.01)
    let k2 = Journal.entryKey()
    #expect(k1 < k2)
}

// MARK: - Client UUID persistence

@Test func journalClientUUIDPersists() throws {
    let id1 = Journal.clientUUID()
    let id2 = Journal.clientUUID()
    #expect(id1 == id2)
    #expect(!id1.isEmpty)
    #expect(UUID(uuidString: id1) != nil)
}

// MARK: - Sync decision logic

@Test func syncFullResyncWhenLastSyncEmpty() {
    #expect(shouldFullResync(lastSyncKey: "", oldestJournalKey: nil))
    #expect(shouldFullResync(lastSyncKey: "", oldestJournalKey: "1705312200000-uuid"))
}

@Test func syncIncrementalWhenJournalCoversGap() {
    let lastSync = "1705312200000-550E8400-E29B-41D4-A716-446655440000"
    let oldest   = "1705312100000-550E8400-E29B-41D4-A716-446655440000"  // older
    #expect(!shouldFullResync(lastSyncKey: lastSync, oldestJournalKey: oldest))
}

@Test func syncFullResyncOnJournalGap() {
    let lastSync = "1705312200000-550E8400-E29B-41D4-A716-446655440000"
    let oldest   = "1705312300000-550E8400-E29B-41D4-A716-446655440000"  // newer
    #expect(shouldFullResync(lastSyncKey: lastSync, oldestJournalKey: oldest))
}

@Test func syncIncrementalWhenJournalEmpty() {
    #expect(!shouldFullResync(lastSyncKey: "1705312200000-uuid", oldestJournalKey: nil))
}

// MARK: - Own-UUID filtering

@Test func syncFiltersOwnUUID() {
    let myUUID = "AAAAAAAA-0000-0000-0000-000000000000"
    let foreign = "BBBBBBBB-0000-0000-0000-000000000001"
    let entries = [
        JournalEntry(s3Key: "j/0000000000001-\(myUUID)", clientUUID: myUUID,
                     timestampMs: 1, ops: [JournalOp(op: "put", key: "own.wav", size: 1)]),
        JournalEntry(s3Key: "j/0000000000002-\(foreign)", clientUUID: foreign,
                     timestampMs: 2, ops: [JournalOp(op: "put", key: "theirs.wav", size: 2)]),
    ]
    let foreignEntries = entries.filter { $0.clientUUID != myUUID }
    #expect(foreignEntries.count == 1)
    #expect(foreignEntries[0].ops[0].key == "theirs.wav")
}

@Test func syncCollectsUniqueKeysIncludingSrc() {
    let ops = [
        JournalOp(op: "rename", key: "new.wav", src: "old.wav", size: 100),
        JournalOp(op: "put",    key: "new.wav", size: 100),
        JournalOp(op: "delete", key: "gone.wav"),
    ]
    var keys = Set<String>()
    for op in ops {
        keys.insert(op.key)
        if let src = op.src { keys.insert(src) }
    }
    #expect(keys == ["new.wav", "old.wav", "gone.wav"])
}

// MARK: - Helper mirroring Sync.run decision logic

private func shouldFullResync(lastSyncKey: String, oldestJournalKey: String?) -> Bool {
    guard !lastSyncKey.isEmpty else { return true }
    guard let oldest = oldestJournalKey else { return false }
    let oldestMs = Journal.timestampMs(fromFilename: oldest.components(separatedBy: "/").last ?? oldest)
    let lastMs   = Journal.timestampMs(fromFilename: lastSyncKey.components(separatedBy: "/").last ?? lastSyncKey)
    return oldestMs > lastMs
}
