import Foundation

public struct RunRecord: Codable, Sendable, Hashable {
    public var at: Date
    public var routine: Bool
    public var results: [ItemResult]
}

/// Local history in SQLite: every scan's item sizes, decisions, and runs.
public final class HistoryStore: @unchecked Sendable {
    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sweep/history.db").path

    private let db: SQLiteDB
    private let lock = NSLock()

    public init(path: String = HistoryStore.defaultPath) throws {
        db = try SQLiteDB(path: path)
        try db.exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS scans(id INTEGER PRIMARY KEY, at REAL NOT NULL, free INTEGER NOT NULL, total INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS item_sizes(scan_id INTEGER NOT NULL, item_id TEXT NOT NULL, category TEXT, title TEXT, bytes INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS item_sizes_item ON item_sizes(item_id);
        CREATE TABLE IF NOT EXISTS decisions(item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, created REAL NOT NULL, expires REAL);
        CREATE TABLE IF NOT EXISTS decision_log(item_id TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, at REAL NOT NULL, routine INTEGER NOT NULL, json TEXT NOT NULL);
        """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    public func record(_ report: ScanReport) throws {
        try locked {
            try db.exec("BEGIN")
            do {
                try db.query("INSERT INTO scans(at, free, total) VALUES(?,?,?)",
                             [.double(report.scannedAt.timeIntervalSince1970), .int(report.volume.freeBytes), .int(report.volume.totalBytes)])
                let scan = db.lastInsertID
                for i in report.items {
                    try db.query("INSERT INTO item_sizes(scan_id, item_id, category, title, bytes) VALUES(?,?,?,?,?)",
                                 [.int(scan), .text(i.id), .text(i.category), .text(i.title), .int(i.physicalBytes)])
                }
                try db.exec("COMMIT")
            } catch { try? db.exec("ROLLBACK"); throw error }
        }
    }

    public func series(itemID: String, since: Date) throws -> [SeriesPoint] {
        try locked {
            try db.query("SELECT s.at AS at, i.bytes AS bytes FROM item_sizes i JOIN scans s ON s.id = i.scan_id WHERE i.item_id = ? AND s.at >= ? ORDER BY s.at",
                         [.text(itemID), .double(since.timeIntervalSince1970)])
                .map { SeriesPoint(date: Date(timeIntervalSince1970: $0["at"]?.double ?? 0), bytes: $0["bytes"]?.int ?? 0) }
        }
    }

    public func freeSeries(since: Date) throws -> [SeriesPoint] {
        try locked {
            try db.query("SELECT at, free FROM scans WHERE at >= ? ORDER BY at", [.double(since.timeIntervalSince1970)])
                .map { SeriesPoint(date: Date(timeIntervalSince1970: $0["at"]?.double ?? 0), bytes: $0["free"]?.int ?? 0) }
        }
    }

    /// Growth rate (bytes/day) for each item seen in the window.
    public func growthRates(since: Date) throws -> [String: Double] {
        let rows = try locked {
            try db.query("SELECT i.item_id AS id, s.at AS at, i.bytes AS bytes FROM item_sizes i JOIN scans s ON s.id = i.scan_id WHERE s.at >= ? ORDER BY s.at",
                         [.double(since.timeIntervalSince1970)])
        }
        var byItem: [String: [SeriesPoint]] = [:]
        for r in rows {
            guard let id = r["id"]?.text else { continue }
            byItem[id, default: []].append(SeriesPoint(date: Date(timeIntervalSince1970: r["at"]?.double ?? 0), bytes: r["bytes"]?.int ?? 0))
        }
        return byItem.compactMapValues(Growth.ratePerDay)
    }

    /// Item sizes from the scan before the latest one (for spike alerts).
    public func previousSizes() throws -> [String: Int64] {
        try locked {
            let scans = try db.query("SELECT id FROM scans ORDER BY at DESC LIMIT 2")
            guard scans.count == 2, let prev = scans[1]["id"]?.int else { return [:] }
            var out: [String: Int64] = [:]
            for r in try db.query("SELECT item_id, bytes FROM item_sizes WHERE scan_id = ?", [.int(prev)]) {
                if let id = r["item_id"]?.text { out[id] = r["bytes"]?.int ?? 0 }
            }
            return out
        }
    }

    public func setDecision(_ d: Decision) throws {
        try locked {
            try db.query("INSERT OR REPLACE INTO decisions(item_id, kind, created, expires) VALUES(?,?,?,?)",
                         [.text(d.itemID), .text(d.kind.rawValue), .double(d.createdAt.timeIntervalSince1970),
                          d.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null])
            try db.query("INSERT INTO decision_log(item_id, kind, at) VALUES(?,?,?)",
                         [.text(d.itemID), .text(d.kind.rawValue), .double(d.createdAt.timeIntervalSince1970)])
        }
    }

    public func clearDecision(_ itemID: String) throws {
        try locked { try db.query("DELETE FROM decisions WHERE item_id = ?", [.text(itemID)]) }
    }

    public func decisions(now: Date = Date()) throws -> [String: Decision] {
        try locked {
            var out: [String: Decision] = [:]
            for r in try db.query("SELECT * FROM decisions") {
                guard let id = r["item_id"]?.text, let kind = r["kind"]?.text.flatMap(DecisionKind.init) else { continue }
                let d = Decision(itemID: id, kind: kind, createdAt: Date(timeIntervalSince1970: r["created"]?.double ?? 0),
                                 expiresAt: r["expires"]?.double.map(Date.init(timeIntervalSince1970:)))
                if d.isActive(at: now) { out[id] = d }
            }
            return out
        }
    }

    /// How many times the user chose "keep" or "never ask" per item (fed to insights as prior decisions).
    public func declineCounts() throws -> [String: Int] {
        try locked {
            var out: [String: Int] = [:]
            for r in try db.query("SELECT item_id, COUNT(*) AS n FROM decision_log GROUP BY item_id") {
                if let id = r["item_id"]?.text { out[id] = Int(r["n"]?.int ?? 0) }
            }
            return out
        }
    }

    public func recordRun(_ results: [ItemResult], at: Date, routine: Bool) throws {
        let json = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        try locked {
            try db.query("INSERT INTO runs(at, routine, json) VALUES(?,?,?)", [.double(at.timeIntervalSince1970), .int(routine ? 1 : 0), .text(json)])
        }
    }

    public func recentRuns(limit: Int) throws -> [RunRecord] {
        try locked {
            try db.query("SELECT at, routine, json FROM runs ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { r in
                guard let j = r["json"]?.text, let results = try? JSONDecoder().decode([ItemResult].self, from: Data(j.utf8)) else { return nil }
                return RunRecord(at: Date(timeIntervalSince1970: r["at"]?.double ?? 0), routine: r["routine"]?.int == 1, results: results)
            }
        }
    }
}
