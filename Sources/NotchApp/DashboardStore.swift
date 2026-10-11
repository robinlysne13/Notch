import Foundation

/// One row of the dashboard's `kv` table — the same table every page of the web app keeps its
/// data in. `updatedAt` is the version: a write only lands if the server still holds the one it
/// was read against.
struct KVRow {
    let value: String
    let updatedAt: Int64
    let isDeleted: Bool
}

/// Reads and writes the dashboard's `kv` table over Supabase's REST API.
///
/// The web app treats its own `localStorage` as the source of truth and mirrors it up
/// (life-dashboard-app/lib/sync.ts); this is the other end of the same arrangement, minus the
/// mirror — the notch holds nothing of its own, it reads a key when it needs it and writes back
/// what it has added.
///
/// Every write is a compare-and-swap against the version it read, so a notch that has been
/// asleep can never paste over an edit made on the phone in between. On a miss the caller re-reads
/// and tries again, which for an append is all the reconciling needed: the web's own merge keys
/// list items by `id` (lib/merge.ts), so a session added here survives whatever it collided with.
@MainActor
final class DashboardStore {
    private let account: DashboardAccount

    init(account: DashboardAccount) {
        self.account = account
    }

    private var endpoint: String { "\(Dashboard.url)/rest/v1/kv" }

    /// Milliseconds since the epoch — what the table's `updated_at` counts in, and what the web
    /// app's `Date.now()` writes.
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Reading

    func read(_ key: String) async throws -> KVRow? {
        struct Row: Decodable {
            let value: String?
            let updated_at: Int64?
            let deleted_at: Int64?
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "key", value: "eq.\(key)"),
            URLQueryItem(name: "select", value: "value,updated_at,deleted_at"),
        ]
        guard let url = components?.url else { throw DashboardError.requestFailed("bad read URL") }

        let data = try await send(request(url, method: "GET"))
        let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
        guard let row = rows.first, let value = row.value else { return nil }
        return KVRow(
            value: value,
            updatedAt: row.updated_at ?? 0,
            isDeleted: row.deleted_at != nil
        )
    }

    // MARK: Writing

    /// Create a key that has never been written. `false` means somebody else got there first,
    /// which the caller settles by reading and updating instead.
    func insert(_ key: String, value: String, updatedAt: Int64) async throws -> Bool {
        guard let url = URL(string: endpoint) else {
            throw DashboardError.requestFailed("bad write URL")
        }
        var request = self.request(url, method: "POST")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": key, "value": value, "updated_at": updatedAt,
        ])
        do {
            _ = try await send(request)
            return true
        } catch DashboardError.requestFailed(let why) where why.contains("23505") {
            return false // the key already exists
        }
    }

    /// Replace a key's value, but only while the server still holds `ifUpdatedAt`. `false` means
    /// the row moved under us — another device wrote, or it is gone.
    ///
    /// `deleted_at` is cleared on the way through: writing a key again is how the web app undoes
    /// a deletion, and a write that left the tombstone standing would be invisible to it.
    func update(
        _ key: String,
        value: String,
        updatedAt: Int64,
        ifUpdatedAt agreed: Int64
    ) async throws -> Bool {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "key", value: "eq.\(key)"),
            URLQueryItem(name: "updated_at", value: "eq.\(agreed)"),
            URLQueryItem(name: "select", value: "key"),
        ]
        guard let url = components?.url else {
            throw DashboardError.requestFailed("bad write URL")
        }
        var request = self.request(url, method: "PATCH")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "value": value, "updated_at": updatedAt, "deleted_at": NSNull(),
        ])

        struct Touched: Decodable { let key: String }
        let data = try await send(request)
        let touched = (try? JSONDecoder().decode([Touched].self, from: data)) ?? []
        return !touched.isEmpty
    }

    // MARK: Plumbing

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Dashboard.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await account.accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardError.requestFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DashboardError.requestFailed(Self.reason(in: data, status: http.statusCode))
        }
        return data
    }

    /// PostgREST says what it objected to, and the SQLSTATE it says it with is what tells an
    /// "already exists" apart from a genuine failure.
    private static func reason(in data: Data, status: Int) -> String {
        struct Problem: Decodable {
            let message: String?
            let code: String?
            let details: String?
        }
        if let problem = try? JSONDecoder().decode(Problem.self, from: data) {
            let parts = [problem.code, problem.message].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return "HTTP \(status)"
    }
}
