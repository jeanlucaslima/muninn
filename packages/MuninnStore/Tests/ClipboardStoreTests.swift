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
}
