import Testing
import Foundation
@testable import MuninnStore

@Suite("ClipboardStore")
struct ClipboardStoreTests {
    func makeStore() throws -> ClipboardStore {
        // Use an in-memory database for tests
        try ClipboardStore(path: ":memory:")
    }

    @Test("Insert and list entries")
    func insertAndList() throws {
        let store = try makeStore()

        let e1 = try store.insert("hello")
        let e2 = try store.insert("world")
        let e3 = try store.insert("foo")

        guard case .stored = e1 else { Issue.record("expected stored"); return }
        guard case .stored = e2 else { Issue.record("expected stored"); return }
        guard case .stored = e3 else { Issue.record("expected stored"); return }

        let result = try store.list(limit: 10, offset: 0)
        #expect(result.total == 3)
        #expect(result.entries.count == 3)
        // Newest first
        #expect(result.entries[0].content == "foo")
        #expect(result.entries[1].content == "world")
        #expect(result.entries[2].content == "hello")
    }

    @Test("Deduplication of consecutive identical content")
    func deduplication() throws {
        let store = try makeStore()

        let e1 = try store.insert("same")
        let e2 = try store.insert("same")

        guard case .stored = e1 else { Issue.record("expected stored"); return }
        guard case .deduplicated = e2 else { Issue.record("expected deduplicated"); return }
        #expect(try store.count() == 1)
    }

    @Test("Different content is not deduplicated")
    func differentContent() throws {
        let store = try makeStore()

        try store.insert("a")
        try store.insert("b")

        #expect(try store.count() == 2)
    }

    @Test("Re-copying after different content creates new entry")
    func recopySameContent() throws {
        let store = try makeStore()

        try store.insert("a")
        try store.insert("b")
        let e3 = try store.insert("a")

        guard case .stored = e3 else { Issue.record("expected stored"); return }
        #expect(try store.count() == 3)
    }

    @Test("List with pagination")
    func listPagination() throws {
        let store = try makeStore()

        for i in 1...5 {
            try store.insert("entry \(i)")
        }

        let page1 = try store.list(limit: 2, offset: 0)
        #expect(page1.entries.count == 2)
        #expect(page1.total == 5)
        #expect(page1.entries[0].content == "entry 5")
        #expect(page1.entries[1].content == "entry 4")

        let page2 = try store.list(limit: 2, offset: 2)
        #expect(page2.entries.count == 2)
        #expect(page2.entries[0].content == "entry 3")
        #expect(page2.entries[1].content == "entry 2")
    }

    @Test("Content over 1MB is rejected with size info")
    func largeContent() throws {
        let store = try makeStore()
        let big = String(repeating: "x", count: 1_000_001)
        let result = try store.insert(big)
        guard case .skippedTooLarge(let contentSize, let maxSize) = result else {
            Issue.record("expected skippedTooLarge"); return
        }
        #expect(contentSize == 1_000_001)
        #expect(maxSize == 1_000_000)
        #expect(try store.count() == 0)
    }

    @Test("Content exactly at size limit is accepted")
    func contentAtLimit() throws {
        let store = try makeStore()
        let exact = String(repeating: "x", count: 1_000_000)
        let result = try store.insert(exact)
        guard case .stored = result else { Issue.record("expected stored"); return }
        #expect(try store.count() == 1)
    }

    // MARK: - Search

    @Test("Search finds substring matches")
    func searchFindsSubstring() throws {
        let store = try makeStore()
        try store.insert("hello world")
        try store.insert("goodbye")
        try store.insert("hello again")

        let results = try store.search(query: "hello")
        #expect(results.count == 2)
        #expect(results[0].content == "hello again")
        #expect(results[1].content == "hello world")
    }

    @Test("Search is case-insensitive")
    func searchCaseInsensitive() throws {
        let store = try makeStore()
        try store.insert("Hello World")

        let results = try store.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].content == "Hello World")
    }

    @Test("Search respects limit")
    func searchRespectsLimit() throws {
        let store = try makeStore()
        for i in 1...5 {
            try store.insert("match \(i)")
        }

        let results = try store.search(query: "match", limit: 2)
        #expect(results.count == 2)
    }

    @Test("Search returns empty for no matches")
    func searchNoMatches() throws {
        let store = try makeStore()
        try store.insert("hello")

        let results = try store.search(query: "zzz")
        #expect(results.isEmpty)
    }

    // MARK: - Delete

    @Test("Delete removes existing entry")
    func deleteExistingEntry() throws {
        let store = try makeStore()
        try store.insert("to delete")

        let entries = try store.list().entries
        let deleted = try store.delete(id: entries[0].id)
        #expect(deleted == true)
        #expect(try store.count() == 0)
    }

    @Test("Delete non-existent entry returns false")
    func deleteNonExistent() throws {
        let store = try makeStore()

        let deleted = try store.delete(id: 999)
        #expect(deleted == false)
    }

    @Test("Deleted entry no longer appears in list or search")
    func deleteRemovesFromListAndSearch() throws {
        let store = try makeStore()
        try store.insert("keep this")
        try store.insert("remove this")

        let entries = try store.list().entries
        let removeId = entries.first { $0.content == "remove this" }!.id
        try store.delete(id: removeId)

        let list = try store.list()
        #expect(list.total == 1)
        #expect(list.entries[0].content == "keep this")

        let search = try store.search(query: "remove")
        #expect(search.isEmpty)
    }

    // MARK: - Pin / Unpin

    @Test("Pin and unpin entry")
    func pinAndUnpin() throws {
        let store = try makeStore()
        try store.insert("pin me")

        let entry = try store.list().entries[0]
        #expect(entry.isPinned == false)

        let pinned = try store.pin(id: entry.id)
        #expect(pinned == true)

        let afterPin = try store.get(id: entry.id)
        #expect(afterPin?.isPinned == true)

        let unpinned = try store.unpin(id: entry.id)
        #expect(unpinned == true)

        let afterUnpin = try store.get(id: entry.id)
        #expect(afterUnpin?.isPinned == false)
    }

    @Test("Pin non-existent entry returns false")
    func pinNonExistent() throws {
        let store = try makeStore()

        let pinned = try store.pin(id: 999)
        #expect(pinned == false)
    }

    @Test("Repeated pin is safe")
    func repeatedPin() throws {
        let store = try makeStore()
        try store.insert("pin me")
        let entry = try store.list().entries[0]

        try store.pin(id: entry.id)
        // Second pin still returns true (row exists, update succeeds even if value unchanged)
        let pinned = try store.pin(id: entry.id)
        #expect(pinned == true)

        let after = try store.get(id: entry.id)
        #expect(after?.isPinned == true)
    }

    @Test("Pinned state appears in list and search results")
    func pinnedStateInResults() throws {
        let store = try makeStore()
        try store.insert("pinned entry")
        let entry = try store.list().entries[0]
        try store.pin(id: entry.id)

        let listed = try store.list().entries[0]
        #expect(listed.isPinned == true)

        let searched = try store.search(query: "pinned")
        #expect(searched[0].isPinned == true)
    }
}
