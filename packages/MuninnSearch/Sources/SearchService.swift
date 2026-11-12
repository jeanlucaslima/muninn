import Foundation
import UniformTypeIdentifiers
import MuninnCore
import MuninnStore

/// The one search engine (design §4.7, invariant 7). The panel and the CLI
/// both reach it through the helper; neither has search logic of its own.
public struct SearchService: Sendable {
    private let pool: ReaderPool

    public init(pool: ReaderPool) {
        self.pool = pool
    }

    /// Text query and/or filters. Blank query plus filters is ordered by recency.
    public func search(_ request: SearchRequest, now: Date = Date()) async throws -> ItemPage {
        if let limit = request.limit, limit <= 0 {
            throw SearchError.invalidLimit(limit)
        }
        return try await pool.read { db in
            try db.readTransaction { try SearchEngine.run(request, now: now, db: db) }
        }
    }

    /// Items by most recent capture: a search with no query.
    public func list(limit: Int? = MuninnLimits.defaultResultLimit, excludeProtected: Bool = true) async throws -> ItemPage {
        try await search(SearchRequest(limit: limit, excludeProtected: excludeProtected))
    }
}

public enum SearchError: Error, Sendable, Equatable {
    case invalidLimit(Int)
}

/// Ranking weights (§4.7). Relevance is primary: every boost multiplies it,
/// so a better text match is never outranked by recency alone.
public enum RankingWeights {
    /// Recency decays exponentially with this time constant.
    public static let recencyTimeConstant: TimeInterval = 7 * 24 * 3600
    public static let recency = 1.0
    public static let pinned = 0.5
    /// Multiplied by ln(capture_count).
    public static let captureCount = 0.1
    public static let exactPhrase = 0.5
}

// MARK: - Query parsing

struct ParsedQuery: Equatable {
    /// FTS5 MATCH expression: each term of ≥ 3 characters as a quoted phrase, ANDed.
    var match: String?
    /// LIKE patterns for terms under 3 characters, which trigrams can't index.
    var likePatterns: [String]
    /// LIKE pattern for the whole query, for the exact-phrase boost (multi-term queries only).
    var phrasePattern: String?

    init?(_ raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let long = terms.filter { $0.unicodeScalars.count >= 3 }
        let short = terms.filter { $0.unicodeScalars.count < 3 }
        match = long.isEmpty ? nil : long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
        likePatterns = short.map { "%" + Self.escapeLike($0) + "%" }
        phrasePattern = terms.count > 1 ? "%" + Self.escapeLike(trimmed) + "%" : nil
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - Engine

enum SearchEngine {
    static func run(_ request: SearchRequest, now: Date, db: Database) throws -> ItemPage {
        // Structured filters, applied in SQL to `ci` (content_items).
        var filters: [String] = []
        var filterArgs: [SQLValue] = []

        if request.excludeProtected {
            filters.append("ci.is_protected = 0")
        }
        if let pinned = request.pinned {
            filters.append("ci.is_pinned = ?")
            filterArgs.append(.int(pinned ? 1 : 0))
        }
        if request.since != nil || request.until != nil {
            var range: [String] = []
            if let since = request.since {
                range.append("e.captured_at >= ?")
                filterArgs.append(.int(ms(since)))
            }
            if let until = request.until {
                range.append("e.captured_at <= ?")
                filterArgs.append(.int(ms(until)))
            }
            filters.append("EXISTS (SELECT 1 FROM capture_events e WHERE e.content_item_id = ci.id AND "
                           + range.joined(separator: " AND ") + ")")
        }
        if let app = request.app?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            filters.append("""
                EXISTS (SELECT 1 FROM capture_events e WHERE e.content_item_id = ci.id
                        AND (e.source_bundle_id = ? COLLATE NOCASE OR e.source_app_name = ? COLLATE NOCASE))
                """)
            filterArgs += [.text(app), .text(app)]
        }
        if let type = request.type?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            if ItemKind(rawValue: type) == .other {
                filters.append("ci.primary_kind = 'other'")
            } else {
                let utis = try matchingUTIs(db, type: type)
                guard !utis.isEmpty else { return ItemPage(items: [], total: 0, hasMore: false) }
                filters.append("EXISTS (SELECT 1 FROM representations r WHERE r.content_item_id = ci.id AND r.uti IN ("
                               + Array(repeating: "?", count: utis.count).joined(separator: ",") + "))")
                filterArgs += utis.map(SQLValue.text)
            }
        }
        let whereSQL = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        let limitSQL = request.limit.map { "LIMIT \($0)" } ?? ""

        let ids: [Int64]
        let total: Int

        if let query = ParsedQuery(request.query) {
            // Text matches, one row per item, from the FTS index.
            var matchConditions: [String] = []
            var matchArgs: [SQLValue] = []
            let phraseExpr: String
            if let phrase = query.phrasePattern {
                phraseExpr = "(text LIKE ? ESCAPE '\\')"
                matchArgs.append(.text(phrase))
            } else {
                phraseExpr = "0"
            }
            if let match = query.match {
                matchConditions.append("search_index MATCH ?")
                matchArgs.append(.text(match))
            }
            for pattern in query.likePatterns {
                matchConditions.append("text LIKE ? ESCAPE '\\'")
                matchArgs.append(.text(pattern))
            }
            let relevance = query.match != nil ? "bm25(search_index)" : "0.0"
            let stride = MuninnLimits.indexRowsPerItem
            // bm25() only works per FTS row, not inside an aggregate, so score
            // rows first (MATERIALIZED stops SQLite flattening this into the
            // GROUP BY), then keep each item's best row.
            let cte = """
                WITH hits AS MATERIALIZED (
                    SELECT rowid / \(stride) AS item_id, \(relevance) AS rel, \(phraseExpr) AS phrase
                    FROM search_index
                    WHERE \(matchConditions.joined(separator: " AND "))
                ),
                m AS (
                    SELECT item_id, MIN(rel) AS rel, MAX(phrase) AS phrase FROM hits GROUP BY item_id
                )
                """
            let score = """
                (-m.rel) * (1.0
                    + \(RankingWeights.recency) * exp(-(? - ci.last_captured_at) / \(RankingWeights.recencyTimeConstant * 1000))
                    + \(RankingWeights.pinned) * ci.is_pinned
                    + \(RankingWeights.captureCount) * ln(ci.capture_count)
                    + \(RankingWeights.exactPhrase) * m.phrase)
                """
            ids = try db.query("""
                \(cte)
                SELECT ci.id, \(score) AS score
                FROM m JOIN content_items ci ON ci.id = m.item_id
                \(whereSQL)
                ORDER BY score DESC, ci.last_captured_at DESC, ci.id DESC
                \(limitSQL)
                """, matchArgs + [.int(ms(now))] + filterArgs) { $0.int(0) }
            total = try db.queryOne("""
                \(cte)
                SELECT COUNT(*) FROM m JOIN content_items ci ON ci.id = m.item_id
                \(whereSQL)
                """, matchArgs + filterArgs) { Int($0.int(0)) } ?? 0
        } else {
            ids = try db.query("""
                SELECT ci.id FROM content_items ci
                \(whereSQL)
                ORDER BY ci.last_captured_at DESC, ci.id DESC
                \(limitSQL)
                """, filterArgs) { $0.int(0) }
            total = try db.queryOne("SELECT COUNT(*) FROM content_items ci \(whereSQL)", filterArgs) {
                Int($0.int(0))
            } ?? 0
        }

        let items = try ItemQueries.summaries(db, ids: ids)
        return ItemPage(items: items, total: total, hasMore: items.count < total)
    }

    /// UTIs present in the store that are, or conform to, the requested kind or UTI.
    private static func matchingUTIs(_ db: Database, type: String) throws -> [String] {
        let target = ItemKind(rawValue: type)?.conformanceUTI ?? type
        let targetType = UTType(target)
        let present = try db.query("SELECT DISTINCT uti FROM representations") { $0.text(0) ?? "" }
        return present.filter { uti in
            if uti == target { return true }
            guard let targetType, let type = UTType(uti) else { return false }
            return type.conforms(to: targetType)
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
