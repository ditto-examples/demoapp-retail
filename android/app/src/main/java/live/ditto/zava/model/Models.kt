package live.ditto.zava.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/// system:* rows arrive as sorted compact JSON strings (observeRawJson);
/// screens parse them to JsonObject, then to a plain map for SyncStatusInfo /
/// IndexInfo.
fun JsonElement.toPlain(): Any? = when (this) {
    is JsonNull -> null
    is JsonObject -> mapValues { it.value.toPlain() }
    is JsonArray -> map { it.toPlain() }
    is kotlinx.serialization.json.JsonPrimitive ->
        if (isString) content else longOrNull ?: doubleOrNull ?: booleanOrNull ?: content
}

fun JsonObject.toPlainMap(): Map<String, Any?> = mapValues { it.value.toPlain() }

// Models mirror the retail-joins benchmark's document shapes 1:1 (snake_case
// property names match the collection fields exactly, so the document → model
// mapping stays visible — these apps teach the SDK, not hide it). The schema
// is NORMALIZED (Ditto SDK 5.1+ JOINs): orders carry no customer/store display
// fields, order_items carry no store_id/sku/product_name — cross-collection
// display goes through INNER JOIN queries at the call sites. All models are
// immutable value types: they cross from Ditto observer callbacks to the
// main-thread UI state. Nullable fields default to null so documents missing
// the key decode identically to the Swift models (explicit nulls are treated
// as absent; a null/missing required field fails loudly).

@Serializable
data class Store(
    val _id: String,
    val store_id: String,
    val store_name: String,
    val rls_user_id: String? = null,
    val is_online: Boolean,
    val location: Location,
    val deleted: Boolean,
    /** Stamped by scripts/load_data.py on the store with the fewest orders in
     * the loaded slice — the apps' first-launch default. */
    val demo_default: Boolean? = null,
) {
    @Serializable
    data class Location(
        val address: String,
        val city: String,
        val state: String,
        val zip: String,
    )

    val id: String get() = _id
}

@Serializable
data class Category(
    val _id: String,
    val category_id: String,
    val category_name: String,
    val seasonal_multipliers: Map<String, Double>? = null,
    val deleted: Boolean,
) {
    val id: String get() = _id
}

@Serializable
data class ProductType(
    val _id: String,
    val type_id: String,
    val category_id: String,
    val type_name: String,
    val deleted: Boolean,
) {
    val id: String get() = _id
}

@Serializable
data class Product(
    val _id: String,
    val product_id: String,
    val sku: String,
    val product_name: String,
    val category_id: String,
    val type_id: String? = null,
    val cost: Double,
    val base_price: Double,
    val gross_margin_percent: Double,
    val deleted: Boolean,
) {
    val id: String get() = _id
}

@Serializable
data class Customer(
    val _id: String,
    val customer_id: String,
    val first_name: String,
    val last_name: String,
    val email: String,
    val phone: String? = null,
    val primary_store_id: String,
    val created_at: String,
    val deleted: Boolean,
) {
    val id: String get() = _id
    val displayName: String get() = "$first_name $last_name"
}

@Serializable
data class InventoryItem(
    val _id: CompositeID,
    val store_id: String,
    val product_id: String,
    val stock_level: Int,
    val location: BinLocation,
    val last_counted: String? = null,
    val notes: String? = null,
    val deleted: Boolean,
) {
    /// inventory._id is a composite document: {store_id, product_id} — the
    /// composite-key teaching moment (subfield queries + explicit index).
    @Serializable
    data class CompositeID(
        val store_id: String,
        val product_id: String,
    )

    @Serializable
    data class BinLocation(
        val aisle: String,
        val shelf: String,
        val bin: String,
    )

    val id: String get() = "${_id.store_id}|${_id.product_id}"
}

@Serializable
data class Order(
    val _id: String,
    val order_id: String,
    val customer_id: String,
    val store_id: String,
    val order_date: String,
    val item_count: Int,
    val subtotal: Double,
    val total: Double,
    val status: String,
    val deleted: Boolean,
) {
    val id: String get() = _id
}

@Serializable
data class OrderItem(
    val _id: String,
    val order_item_id: String? = null,
    val order_id: String,
    val product_id: String,
    val quantity: Int,
    val unit_price: Double,
    val discount_percent: Double,
    val discount_amount: Double? = null,
    val line_total: Double,
    val deleted: Boolean,
) {
    val id: String get() = _id
}

/** Row shape of the orders screen's INNER JOIN (orders ⨝ customers) — the
 * normalized replacement for v5.0's denormalized orders.customer_name: the
 * customer's display name comes from the join, not the order document. */
@Serializable
data class OrderSummaryRow(
    val order_id: String,
    val store_id: String,
    val order_date: String,
    val status: String,
    val subtotal: Double,
    val total: Double,
    val item_count: Int,
    val customer_id: String,
    val first_name: String? = null,
    val last_name: String? = null,
) {
    /** == the order doc's `_id` (order ids are `order_…` slugs) — NOT
     *  deserialized: observer emissions on JOINs namespace `_id` per alias. */
    val _id: String get() = order_id
    val id: String get() = _id
    val customerName: String get() = listOfNotNull(first_name, last_name).joinToString(" ")
}

/** Row shape of the order-detail JOIN (order_items ⨝ products) — the
 * normalized replacement for denormalized order_items.product_name/sku. */
@Serializable
data class OrderLineRow(
    val _id: String,
    val order_id: String,
    val product_id: String,
    val quantity: Int,
    val unit_price: Double,
    val discount_percent: Double,
    val discount_amount: Double? = null,
    val line_total: Double,
    val product_name: String? = null,
    val sku: String? = null,
) {
    val id: String get() = _id
}

/// Single-row shape of `SELECT COUNT(*) AS count …` queries.
@Serializable
data class CountRow(val count: Int)

/// Aggregate rows decode with nullable group keys/aggregates: DQL omits them
/// on an empty match set (a degenerate `{"orders": 0}` row arrives). Screens
/// filter those rows rather than render fake zeros.
@Serializable
data class StatusRevenueRow(val status: String? = null, val orders: Int, val revenue: Double? = null)

@Serializable
data class MonthTrendRow(val month: String? = null, val orders: Int, val revenue: Double? = null)

@Serializable
data class TopProductRow(val product_id: String? = null, val revenue: Double? = null)

/// Page math for the list screens (pure — unit-tested). DQL supports
/// `LIMIT … OFFSET …`; the ints come from our own controls and are
/// interpolated into the query string (never user text).
object Paging {
    fun pageQuery(base: String, orderBy: String, page: Int, pageSize: Int): String =
        "$base ORDER BY $orderBy LIMIT $pageSize OFFSET ${(page - 1) * pageSize}"

    fun pageCount(total: Int, pageSize: Int): Int =
        max(1, ceil(total.toDouble() / pageSize).toInt())

    fun clampPage(page: Int, total: Int, pageSize: Int): Int =
        min(max(1, page), pageCount(total, pageSize))
}

/// Row shape of `system:data_sync_info` (the sync status virtual collection).
data class SyncStatusInfo(
    val id: String,
    val isDittoServer: Boolean,
    val syncSessionStatus: String,
    val syncedUpToLocalCommitId: Long?,
) {
    companion object {
        fun from(row: Map<String, Any?>): SyncStatusInfo? {
            val id = row["_id"] as? String ?: return null
            val documents = row["documents"] as? Map<*, *>
            return SyncStatusInfo(
                id = id,
                isDittoServer = row["is_ditto_server"] as? Boolean ?: false,
                syncSessionStatus = documents?.get("sync_session_status") as? String ?: "Unknown",
                syncedUpToLocalCommitId = (documents?.get("synced_up_to_local_commit_id") as? Number)?.toLong(),
            )
        }
    }
}

/// Row shape of `system:indexes`.
data class IndexInfo(
    val id: String,
    val collection: String,
    val definition: String,
) {
    companion object {
        fun from(row: Map<String, Any?>): IndexInfo? {
            // system:indexes rows carry an _id like "orders:zava_orders_store".
            val rawId = row["_id"] as? String ?: return null
            return IndexInfo(
                id = rawId,
                collection = row["collection"] as? String ?: rawId.split(":").firstOrNull() ?: "?",
                definition = row["fields"]?.toString() ?: "",
            )
        }
    }
}
