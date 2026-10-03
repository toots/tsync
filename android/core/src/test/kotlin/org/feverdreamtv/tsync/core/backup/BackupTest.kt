package org.feverdreamtv.tsync.core.backup

import org.feverdreamtv.tsync.core.Parameters
import java.time.Instant
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val paris = ZoneId.of("Europe/Paris")
private val noon = Instant.parse("2026-08-16T12:31:04Z").toEpochMilli()
private const val DAY_MS = 24 * 3_600_000L
private const val NOON_TARGET = "Camera Uploads/2026/2026-08-16 14.31.04.jpg"

private fun row(id: Long, taken: Long = noon, size: Long = 100, generation: Long? = id, name: String = "IMG_$id.JPG", modified: Long = taken / 1000) =
    MediaRow(id, name, size, modified, taken / 1000, taken, generation)

/** Applies changes the way the record store does: one row per media id. */
private fun apply(records: Map<Long, Record>, changes: List<RecordChange>): Map<Long, Record> {
    val result = records.toMutableMap()
    for (change in changes) when (change) {
        is RecordChange.Put -> result[change.record.mediaId] = change.record
        is RecordChange.Rekey -> result[change.to] = result.remove(change.from)!!.copy(mediaId = change.to)
        is RecordChange.Delete -> result.remove(change.mediaId)
    }
    assertEquals(result.size, result.values.map { it.target }.toSet().size, "targets are unique")
    return result
}

private class Phone(var records: Map<Long, Record> = emptyMap(), var mark: Mark = Mark()) {
    fun discover(rows: List<MediaRow>, version: String = "v1", now: Long = noon + DAY_MS, baseline: Boolean = false, zone: ZoneId = paris): DiscoveryStart {
        val start = DiscoveryStart.of(mark, version, rows.mapNotNull { it.generation }.maxOrNull(), now)
        val planner = DiscoveryPlanner("external_primary", records.values, start, zone, now, baseline)
        rows.filter { start.full || !start.mark.covers(it) }.forEach(planner::see)
        records = apply(records, planner.changes())
        mark = planner.mark()
        return start
    }

    fun finish(id: Long, now: Long = noon + DAY_MS) {
        val record = records.getValue(id)
        records = records + (id to Processing.uploaded(record, row(id, size = record.size, modified = record.modifiedSeconds), record.target, "etag$id", now))
    }

    fun states() = records.values.sortedBy { it.mediaId }.map { it.mediaId to it.state }
}

class DiscoveryTest {
    @Test
    fun everythingRecordsEveryRowAsPendingWithFrozenNames() {
        val phone = Phone()
        phone.discover(listOf(row(1), row(2), row(3, name = "VID_3.mp4"), row(4, taken = noon + 1000)))
        assertEquals(
            listOf(NOON_TARGET, NOON_TARGET.replace(".jpg", " (1).jpg"), NOON_TARGET.replace(".jpg", ".mp4"), "Camera Uploads/2026/2026-08-16 14.31.05.jpg"),
            phone.records.values.sortedBy { it.mediaId }.map { it.target },
        )
        assertTrue(phone.records.values.all { it.state == State.PENDING })
        assertEquals(Mark(4, (noon + 1000) / 1000, "v1", noon + DAY_MS), phone.mark)
    }

    @Test
    fun fromNowOnUploadsNothingThatExisted() {
        val phone = Phone()
        phone.discover(listOf(row(1), row(2)), baseline = true)
        phone.discover(listOf(row(1), row(2), row(3, taken = noon + 5000)))
        assertEquals(listOf(1L to State.BASELINE, 2L to State.BASELINE, 3L to State.PENDING), phone.states())
        assertEquals(listOf(3L), Processing.due(phone.records.values, noon + DAY_MS).map { it.mediaId })
    }

    @Test
    fun noRowIsEverBehindTheMarkWithoutARecord() {
        val phone = Phone()
        val unsettled = row(1).copy(pending = true)
        phone.discover(listOf(unsettled))
        assertEquals(State.PENDING, phone.records.getValue(1).state)
        phone.discover(listOf(unsettled))
        assertEquals(listOf(1L), Processing.due(phone.records.values, noon).map { it.mediaId })
    }

    @Test
    fun aChangedDoneItemIsUploadedAgainToTheSameTargetWithItsBase() {
        val phone = Phone()
        phone.discover(listOf(row(1)))
        phone.finish(1)
        phone.discover(listOf(row(1, size = 150, generation = 9)))
        val record = phone.records.getValue(1)
        assertEquals(State.PENDING to NOON_TARGET, record.state to record.target)
        assertEquals("etag1", Processing.base(record))
        assertEquals(150, record.size)
    }

    @Test
    fun anUnchangedRowRewritesNothing() {
        val phone = Phone()
        phone.discover(listOf(row(1), row(2)))
        phone.finish(1)
        val start = DiscoveryStart.of(phone.mark.copy(fullDiscoveryAt = null), "v1", 2, noon)
        val planner = DiscoveryPlanner("external_primary", phone.records.values, start, paris, noon)
        listOf(row(1), row(2)).forEach(planner::see)
        assertEquals(emptyList(), planner.changes())
    }

    @Test
    fun aTimeZoneChangeDoesNotRenameWhatWasSeen() {
        val phone = Phone()
        phone.discover(listOf(row(1)))
        phone.mark = phone.mark.copy(fullDiscoveryAt = null)
        phone.discover(listOf(row(1)), zone = ZoneId.of("Asia/Tokyo"))
        assertEquals(listOf(NOON_TARGET), phone.records.values.map { it.target })
    }

    @Test
    fun aRebuildLosesNoPhotoAndReuploadsNone() {
        val phone = Phone()
        phone.discover(listOf(row(1), row(2, taken = noon + 1000, size = 200), row(3, taken = noon + 2000, size = 300)), baseline = false)
        phone.finish(1)
        phone.finish(2)
        val before = phone.records.values.associate { it.target to it.state }
        // Every id now names another item; id 2 is reused by what was id 3.
        val rebuilt = listOf(row(7, size = 100, generation = 1), row(8, taken = noon + 1000, size = 200, generation = 2), row(2, taken = noon + 2000, size = 300, generation = 3))
        for (version in listOf("v2")) {
            val start = phone.discover(rebuilt, version = version)
            assertTrue(start.rebuilt && start.full)
        }
        assertEquals(before, phone.records.values.associate { it.target to it.state })
        assertEquals(listOf(2L to State.PENDING, 7L to State.DONE, 8L to State.DONE), phone.states())
        assertEquals("v2", phone.mark.version)
        assertFalse(phone.discover(rebuilt, version = "v2").rebuilt)
        assertEquals(before, phone.records.values.associate { it.target to it.state })
    }

    @Test
    fun aLowerGenerationIsARebuildToo() {
        val start = DiscoveryStart.of(Mark(generation = 50, dateAdded = 9, version = "v1", fullDiscoveryAt = noon), "v1", 3, noon)
        assertTrue(start.rebuilt)
        assertEquals(Mark(0, 0, "v1", noon), start.mark)
        assertFalse(DiscoveryStart.of(Mark(50, 9, null, noon), "v1", 60, noon).rebuilt)
    }

    @Test
    fun renumberedIdsAreRecognisedAndDifferentContentGetsASequenceName() {
        val phone = Phone()
        phone.discover(listOf(row(1)))
        phone.finish(1)
        phone.discover(listOf(row(11, generation = 20), row(12, size = 999, generation = 21)))
        assertEquals(listOf(11L to State.DONE, 12L to State.PENDING), phone.states())
        assertEquals(NOON_TARGET, phone.records.getValue(11).target)
        assertEquals(NOON_TARGET.replace(".jpg", " (1).jpg"), phone.records.getValue(12).target)
    }

    @Test
    fun recordsAndMarksWithoutOptionalPartsAreUsedAsTheyAre() {
        val week = 7 * DAY_MS
        val old = Record(1, "external_primary", NOON_TARGET, 100, noon / 1000, State.DONE, updatedAt = noon)
        val failed = Record(2, "external_primary", "Camera Uploads/2026/x.jpg", 5, 5, State.FAILED, attempts = 3, lastError = "x", updatedAt = noon + 1)
        val phone = Phone(mapOf(1L to old, 2L to failed), Mark(generation = 10, dateAdded = (noon + week) / 1000))
        assertEquals(listOf(2L), Processing.due(phone.records.values, noon).map { it.mediaId })
        assertNull(Processing.base(old))
        val beforeBackup = row(5, taken = noon - 30 * DAY_MS)
        val duringBackup = row(6, taken = noon + DAY_MS)
        val start = phone.discover(listOf(row(1, generation = 10), beforeBackup, duringBackup), now = noon + week)
        assertTrue(start.full && !start.rebuilt)
        assertEquals(State.BASELINE, phone.records.getValue(5).state)
        assertEquals(State.PENDING, phone.records.getValue(6).state)
        assertEquals(old, phone.records.getValue(1))
        assertEquals("v1" to noon + week, phone.mark.version to phone.mark.fullDiscoveryAt)
        // A DONE record without an etag that changed: uploaded again to its target, with no base and not exclusively.
        phone.discover(listOf(row(1, size = 101, generation = 30)), now = noon + week)
        val again = phone.records.getValue(1)
        assertEquals(Triple(State.PENDING, NOON_TARGET, ""), Triple(again.state, again.target, again.etag))
        assertNull(Processing.base(again))
    }

    @Test
    fun aMarkWithoutRecordsOrVersionIsNeitherAMismatchNorABackfill() {
        val phone = Phone(mark = Mark(generation = 10, dateAdded = noon / 1000))
        val start = phone.discover(listOf(row(3), row(20, taken = noon + 1000)))
        assertFalse(start.rebuilt)
        assertEquals(listOf(3L to State.BASELINE, 20L to State.PENDING), phone.states())
    }

    @Test
    fun thePlannerIsDeterministic() {
        val rows = (1L..40L).map { row(it, taken = noon + (it % 5) * 1000, size = 100 + it % 3) }
        fun plan(): List<RecordChange> {
            val start = DiscoveryStart.of(Mark(), "v1", 40, noon)
            return DiscoveryPlanner("external_primary", emptyList(), start, paris, noon).also { rows.forEach(it::see) }.changes()
        }
        assertEquals(plan(), plan())
        assertEquals(40, plan().map { (it as RecordChange.Put).record.target }.toSet().size)
    }
}

class ProcessingTest {
    private val record = Record(1, "external_primary", NOON_TARGET, 100, noon / 1000, State.PENDING, updatedAt = noon)

    @Test
    fun anUnsettledItemWaitsAndAGoneOneIsForgotten() {
        val now = noon + 60_000
        assertEquals(Step.FORGET, Processing.step(null, now))
        assertEquals(Step.WAIT, Processing.step(row(1).copy(pending = true), now))
        assertEquals(Step.WAIT, Processing.step(row(1, size = 0), now))
        assertEquals(Step.WAIT, Processing.step(row(1, modified = (now - 9_000) / 1000 + 1), now))
        assertEquals(Step.UPLOAD, Processing.step(row(1, modified = (now - Parameters.SETTLE_TIME_MS) / 1000), now))
    }

    @Test
    fun aFailureIsRetriedWithABoundedBackoffUntilItSucceeds() {
        var current = record
        val delays = (1..8).map {
            current = Processing.failed(current, "boom", noon)
            assertEquals(State.FAILED, current.state)
            current.nextAttemptAt!! - noon
        }
        val quarter = 15 * 60_000L
        assertEquals(listOf(quarter, 2 * quarter, 4 * quarter, 8 * quarter, 16 * quarter, 24 * quarter, 24 * quarter, 24 * quarter), delays)
        assertEquals(8 to "boom", current.attempts to current.lastError)
        assertEquals(emptyList(), Processing.due(listOf(current), noon + 24 * quarter - 1))
        assertEquals(listOf(current), Processing.due(listOf(current), noon + 24 * quarter))
        val done = Processing.uploaded(current, row(1, size = 120), NOON_TARGET, "e", noon)
        assertEquals(State.DONE to "e", done.state to done.etag)
        assertEquals(120L to null, done.size to done.nextAttemptAt)
        assertTrue(Processing.settled(listOf(done)) && !Processing.settled(listOf(current)))
        assertEquals(emptyList(), Processing.due(listOf(done, done.copy(state = State.BASELINE)), noon * 2))
    }

    @Test
    fun dueRecordsComeInCaptureOrder() {
        val later = record.copy(mediaId = 1, target = "Camera Uploads/2026/2026-08-17 09.00.00.jpg")
        val earlier = record.copy(mediaId = 9, target = NOON_TARGET)
        assertEquals(listOf(9L, 1L), Processing.due(listOf(later, earlier), noon).map { it.mediaId })
    }

    @Test
    fun anotherWritersStateReadsAsFailed() {
        assertEquals(State.FAILED, State.of("QUARANTINED"))
        assertEquals(State.BASELINE, State.of("BASELINE"))
    }

    @Test
    fun theGateAndTheBudgets() {
        val all = BackupSettings(enabled = true, unmeteredOnly = true, whenBatteryOk = true)
        val wifi = Device(networkPresent = true, networkMetered = false, charging = false, batteryPercent = 80)
        assertNull(Processing.gate(all, wifi))
        assertEquals(Hold.WIFI, Processing.gate(all, wifi.copy(networkMetered = true)))
        assertEquals(Hold.WIFI, Processing.gate(all, wifi.copy(networkPresent = false)))
        assertNull(Processing.gate(all.copy(unmeteredOnly = false), wifi.copy(networkPresent = false)))
        assertEquals(Hold.BATTERY, Processing.gate(all, wifi.copy(batteryPercent = 14)))
        assertNull(Processing.gate(all, wifi.copy(batteryPercent = 14, charging = true)))
        assertNull(Processing.gate(all, wifi.copy(batteryPercent = 15)))
        assertNull(Processing.gate(all.copy(whenBatteryOk = false), wifi.copy(batteryPercent = 1)))
        val budget = Parameters.STAGED_BYTES_BUDGET
        assertTrue(Processing.withinBudget(budget - 1, 0, 200, 100))
        assertFalse(Processing.withinBudget(budget, 0, 200, 100))
        assertFalse(Processing.withinBudget(0, Parameters.PASS_TIME_BUDGET_MS, 200, 100))
        assertFalse(Processing.withinBudget(0, 0, 199, 100))
    }
}
