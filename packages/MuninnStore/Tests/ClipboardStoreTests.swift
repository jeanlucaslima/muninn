import Testing
import Foundation
import MuninnCore
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

    @Test("Search treats percent as literal character")
    func searchEscapesPercent() throws {
        let store = try makeStore()
        try store.insert("100% done")
        try store.insert("nothing here")
        try store.insert("50% complete")

        let results = try store.search(query: "%")
        #expect(results.count == 2)
        #expect(results[0].content == "50% complete")
        #expect(results[1].content == "100% done")
    }

    @Test("Search treats underscore as literal character")
    func searchEscapesUnderscore() throws {
        let store = try makeStore()
        try store.insert("snake_case")
        try store.insert("snakeXcase")

        let results = try store.search(query: "_")
        #expect(results.count == 1)
        #expect(results[0].content == "snake_case")
    }

    @Test("Search treats backslash as literal character")
    func searchEscapesBackslash() throws {
        let store = try makeStore()
        try store.insert("C:\\Users\\file")
        try store.insert("no slash here")

        let results = try store.search(query: "\\")
        #expect(results.count == 1)
        #expect(results[0].content == "C:\\Users\\file")
    }

    @Test("Search finds matches in multiline content")
    func searchMultilineContent() throws {
        let store = try makeStore()
        try store.insert("line one\nline two\nline three")
        try store.insert("single line")

        let results = try store.search(query: "two")
        #expect(results.count == 1)
        #expect(results[0].content.contains("line two"))
    }

    @Test("Search works with single character query")
    func searchSingleCharQuery() throws {
        let store = try makeStore()
        try store.insert("apple")
        try store.insert("xyz")
        try store.insert("banana")

        let results = try store.search(query: "a")
        #expect(results.count == 2)
        #expect(results[0].content == "banana")
        #expect(results[1].content == "apple")
    }

    @Test("Search applies default limit of 20")
    func searchDefaultLimit() throws {
        let store = try makeStore()
        for i in 1...25 {
            try store.insert("item \(i)")
        }

        let results = try store.search(query: "item")
        #expect(results.count == 20)
    }

    @Test("Search order is stable and newest-first")
    func searchOrderStable() throws {
        let store = try makeStore()
        try store.insert("alpha match")
        try store.insert("beta match")
        try store.insert("gamma match")

        let run1 = try store.search(query: "match")
        let run2 = try store.search(query: "match")

        #expect(run1.count == 3)
        #expect(run1.map(\.content) == run2.map(\.content))
        #expect(run1[0].content == "gamma match")
        #expect(run1[1].content == "beta match")
        #expect(run1[2].content == "alpha match")
    }

    // MARK: - Get

    @Test("Get returns exact stored content")
    func getReturnsExactContent() throws {
        let store = try makeStore()
        try store.insert("hello world")

        let entry = try store.list().entries[0]
        let fetched = try store.get(id: entry.id)
        #expect(fetched != nil)
        #expect(fetched?.content == "hello world")
    }

    @Test("Get preserves multiline content")
    func getPreservesMultiline() throws {
        let store = try makeStore()
        let multiline = "line one\nline two\n\nline four"
        try store.insert(multiline)

        let entry = try store.list().entries[0]
        let fetched = try store.get(id: entry.id)
        #expect(fetched?.content == multiline)
    }

    @Test("Get returns nil for unknown id")
    func getUnknownId() throws {
        let store = try makeStore()

        let fetched = try store.get(id: 999)
        #expect(fetched == nil)
    }

    @Test("Get returns metadata including pinned state")
    func getIncludesMetadata() throws {
        let store = try makeStore()
        try store.insert("metadata test")

        let entry = try store.list().entries[0]
        try store.pin(id: entry.id)

        let fetched = try store.get(id: entry.id)
        #expect(fetched != nil)
        #expect(fetched?.id == entry.id)
        #expect(fetched?.isPinned == true)
        #expect(fetched?.createdAt != nil)
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

    @Test("Repeated delete returns false on second attempt")
    func deleteRepeated() throws {
        let store = try makeStore()
        try store.insert("once only")

        let entry = try store.list().entries[0]
        let first = try store.delete(id: entry.id)
        #expect(first == true)

        let second = try store.delete(id: entry.id)
        #expect(second == false)
    }

    @Test("Delete works on pinned entries")
    func deletePinned() throws {
        let store = try makeStore()
        try store.insert("pinned entry")

        let entry = try store.list().entries[0]
        try store.pin(id: entry.id)

        let deleted = try store.delete(id: entry.id)
        #expect(deleted == true)
        #expect(try store.get(id: entry.id) == nil)
    }

    @Test("Delete does not affect other entries")
    func deleteDoesNotAffectOthers() throws {
        let store = try makeStore()
        try store.insert("keep one")
        try store.insert("to remove")
        try store.insert("keep two")

        let entries = try store.list().entries
        let removeId = entries.first { $0.content == "to remove" }!.id
        try store.delete(id: removeId)

        let remaining = try store.list()
        #expect(remaining.total == 2)
        #expect(remaining.entries.map(\.content).contains("keep one"))
        #expect(remaining.entries.map(\.content).contains("keep two"))
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

    // MARK: - Entry Kinds

    @Test("Text entries have kind text")
    func textEntryKind() throws {
        let store = try makeStore()
        try store.insert("hello")

        let entry = try store.list().entries[0]
        #expect(entry.kind == .text)
        #expect(entry.metadata == nil)
    }

    @Test("Insert image entry with dimensions")
    func insertImage() throws {
        let store = try makeStore()
        let meta = EntryMetadata(width: 1440, height: 900)
        let result = try store.insert(kind: .image, content: "", metadata: meta)

        guard case .stored(let entry) = result else { Issue.record("expected stored"); return }
        #expect(entry.kind == .image)
        #expect(entry.metadata?.width == 1440)
        #expect(entry.metadata?.height == 900)
        #expect(entry.content == "<image 1440\u{00D7}900>")
    }

    @Test("Insert file entry with name")
    func insertFile() throws {
        let store = try makeStore()
        let meta = EntryMetadata(name: "report.pdf", path: "/Users/test/report.pdf")
        let result = try store.insert(kind: .file, content: "", metadata: meta)

        guard case .stored(let entry) = result else { Issue.record("expected stored"); return }
        #expect(entry.kind == .file)
        #expect(entry.metadata?.name == "report.pdf")
        #expect(entry.content == "<file: report.pdf>")
    }

    @Test("Insert files entry with count")
    func insertFiles() throws {
        let store = try makeStore()
        let meta = EntryMetadata(count: 3, names: ["a.txt", "b.txt", "c.txt"])
        let result = try store.insert(kind: .files, content: "", metadata: meta)

        guard case .stored(let entry) = result else { Issue.record("expected stored"); return }
        #expect(entry.kind == .files)
        #expect(entry.metadata?.count == 3)
        #expect(entry.content == "<files: 3 items>")
    }

    @Test("Insert rich text, html, and unknown entries")
    func insertOtherKinds() throws {
        let store = try makeStore()

        try store.insert(kind: .richText, content: "", metadata: nil)
        try store.insert(kind: .html, content: "", metadata: nil)
        try store.insert(kind: .unknown, content: "", metadata: nil)

        let entries = try store.list().entries
        #expect(entries.count == 3)
        #expect(entries[0].kind == .unknown)
        #expect(entries[0].content == "<clipboard item>")
        #expect(entries[1].kind == .html)
        #expect(entries[1].content == "<html>")
        #expect(entries[2].kind == .richText)
        #expect(entries[2].content == "<rich text>")
    }

    @Test("Dedup consecutive identical non-text entries")
    func dedupNonText() throws {
        let store = try makeStore()
        let meta = EntryMetadata(width: 800, height: 600)

        let e1 = try store.insert(kind: .image, content: "", metadata: meta)
        let e2 = try store.insert(kind: .image, content: "", metadata: meta)

        guard case .stored = e1 else { Issue.record("expected stored"); return }
        guard case .deduplicated = e2 else { Issue.record("expected deduplicated"); return }
        #expect(try store.count() == 1)
    }

    @Test("Different metadata is not deduplicated")
    func differentMetadataNotDeduped() throws {
        let store = try makeStore()

        try store.insert(kind: .file, content: "", metadata: EntryMetadata(name: "a.txt"))
        try store.insert(kind: .file, content: "", metadata: EntryMetadata(name: "b.txt"))

        #expect(try store.count() == 2)
    }

    @Test("Non-text then text then same non-text is not deduplicated")
    func nonTextInterleaved() throws {
        let store = try makeStore()
        let meta = EntryMetadata(width: 100, height: 100)

        try store.insert(kind: .image, content: "", metadata: meta)
        try store.insert("some text")
        let e3 = try store.insert(kind: .image, content: "", metadata: meta)

        guard case .stored = e3 else { Issue.record("expected stored after interleave"); return }
        #expect(try store.count() == 3)
    }

    @Test("Search finds file entries by placeholder name")
    func searchFindsFileByName() throws {
        let store = try makeStore()
        try store.insert("hello world")
        try store.insert(kind: .file, content: "", metadata: EntryMetadata(name: "report.pdf"))

        let results = try store.search(query: "report")
        #expect(results.count == 1)
        #expect(results[0].kind == .file)
    }

    @Test("Get returns kind and metadata for non-text entries")
    func getNonTextEntry() throws {
        let store = try makeStore()
        try store.insert(kind: .image, content: "", metadata: EntryMetadata(width: 1920, height: 1080))

        let entry = try store.list().entries[0]
        let fetched = try store.get(id: entry.id)
        #expect(fetched?.kind == .image)
        #expect(fetched?.metadata?.width == 1920)
        #expect(fetched?.metadata?.height == 1080)
    }
}
