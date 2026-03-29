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

        #expect(e1 != nil)
        #expect(e2 != nil)
        #expect(e3 != nil)

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

        #expect(e1 != nil)
        #expect(e2 == nil)
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

        #expect(e3 != nil)
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

    @Test("Content over 1MB is rejected")
    func largeContent() throws {
        let store = try makeStore()
        let big = String(repeating: "x", count: 1_000_001)
        let result = try store.insert(big)
        #expect(result == nil)
        #expect(try store.count() == 0)
    }
}
