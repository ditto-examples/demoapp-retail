import Foundation

// Models mirror the retail benchmark's document shapes 1:1 (snake_case
// property names match the collection fields exactly, so the document → model
// mapping stays visible — these apps teach the SDK, not hide it).
// All models are immutable Sendable value types: they cross from the
// DittoManager actor / observer delivery queues to @MainActor UI state.

struct Store: Sendable, Codable, Identifiable, Equatable {
    struct Location: Sendable, Codable, Equatable {
        let address: String
        let city: String
        let state: String
        let zip: String
    }

    let _id: String
    let store_id: String
    let store_name: String
    let rls_user_id: String?
    let is_online: Bool
    let location: Location
    let deleted: Bool

    var id: String {
        _id
    }
}

struct Category: Sendable, Codable, Identifiable, Equatable {
    let _id: String
    let category_id: String
    let category_name: String
    let seasonal_multipliers: [String: Double]?
    let deleted: Bool

    var id: String {
        _id
    }
}

struct Product: Sendable, Codable, Identifiable, Equatable {
    let _id: String
    let product_id: String
    let sku: String
    let product_name: String
    let category_id: String
    let cost: Double
    let base_price: Double
    let gross_margin_percent: Double
    let deleted: Bool

    var id: String {
        _id
    }
}

struct Customer: Sendable, Codable, Identifiable, Equatable {
    let _id: String
    let customer_id: String
    let first_name: String
    let last_name: String
    let email: String
    let phone: String?
    let primary_store_id: String
    let created_at: String
    let deleted: Bool

    var id: String {
        _id
    }

    var displayName: String {
        "\(first_name) \(last_name)"
    }
}

struct InventoryItem: Sendable, Codable, Identifiable, Equatable {
    struct CompositeID: Sendable, Codable, Equatable, Hashable {
        let store_id: String
        let product_id: String
    }

    struct BinLocation: Sendable, Codable, Equatable {
        let aisle: String
        let shelf: String
        let bin: String
    }

    let _id: CompositeID
    let store_id: String
    let product_id: String
    let stock_level: Int
    let location: BinLocation
    let last_counted: String?
    let notes: String?
    let deleted: Bool

    var id: String {
        "\(_id.store_id)|\(_id.product_id)"
    }
}

struct Order: Sendable, Codable, Identifiable, Equatable {
    let _id: String
    let order_id: String
    let customer_id: String
    let store_id: String
    let order_date: String
    let customer_name: String
    let customer_email: String?
    let store_name: String
    let item_count: Int
    let subtotal: Double
    let total: Double
    let status: String
    let deleted: Bool

    var id: String {
        _id
    }
}

struct OrderItem: Sendable, Codable, Identifiable, Equatable {
    let _id: String
    let order_id: String
    let store_id: String
    let product_id: String
    let sku: String
    let product_name: String
    let quantity: Int
    let unit_price: Double
    let discount_percent: Double
    let line_total: Double
    let deleted: Bool

    var id: String {
        _id
    }
}

/// Single-row shape of `SELECT COUNT(*) AS count …` queries.
struct CountRow: Sendable, Decodable {
    let count: Int
}

/// Page math for the list screens (pure — unit-tested). DQL supports
/// `LIMIT … OFFSET …`; the ints come from our own controls and are
/// interpolated into the query string (never user text).
enum Paging {
    static func pageQuery(base: String, orderBy: String, page: Int, pageSize: Int) -> String {
        "\(base) ORDER BY \(orderBy) LIMIT \(pageSize) OFFSET \((page - 1) * pageSize)"
    }

    static func pageCount(total: Int, pageSize: Int) -> Int {
        max(1, Int(ceil(Double(total) / Double(pageSize))))
    }

    static func clampPage(_ page: Int, total: Int, pageSize: Int) -> Int {
        min(max(1, page), pageCount(total: total, pageSize: pageSize))
    }
}

/// Row shape of `system:data_sync_info` (the sync status virtual collection).
struct SyncStatusInfo: Sendable, Equatable, Identifiable {
    let id: String
    let isDittoServer: Bool
    let syncSessionStatus: String
    let syncedUpToLocalCommitId: Int?

    init?(from dictionary: [String: Any?]) {
        guard let id = dictionary["_id"] as? String else { return nil }
        self.id = id
        isDittoServer = dictionary["is_ditto_server"] as? Bool ?? false
        let documents = dictionary["documents"] as? [String: Any?]
        syncSessionStatus = documents?["sync_session_status"] as? String ?? "Unknown"
        syncedUpToLocalCommitId = (documents?["synced_up_to_local_commit_id"] as? NSNumber)?.intValue
    }
}

/// Row shape of `system:indexes`.
struct IndexInfo: Sendable, Equatable, Identifiable {
    let id: String
    let collection: String
    let definition: String

    init?(from dictionary: [String: Any?]) {
        // system:indexes rows carry an _id like "orders:zava_orders_store".
        guard let rawId = dictionary["_id"] as? String else { return nil }
        id = rawId
        collection = dictionary["collection"] as? String
            ?? rawId.split(separator: ":").first.map(String.init) ?? "?"
        // The index fields arrive as an array of small objects; render the
        // raw value for display (the System tab is a debugging surface).
        if let fields = dictionary["fields"] {
            definition = String(describing: fields)
        } else {
            definition = ""
        }
    }
}
