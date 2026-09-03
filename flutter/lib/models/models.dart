import 'dart:math';

/// Models mirror the retail benchmark's document shapes 1:1 (snake_case field
/// names match the collection fields exactly, so the document → model mapping
/// stays visible — these apps teach the SDK, not hide it). Required fields
/// throw loudly on null/missing (matching the Swift/Kotlin decode contract);
/// optional fields default to null.

class AppError implements Exception {
  AppError(this.message);
  final String message;
  @override
  String toString() => message;
}

class Store {
  Store({
    required this.id,
    required this.store_id,
    required this.store_name,
    this.rls_user_id,
    required this.is_online,
    required this.location,
    required this.deleted,
  });

  final String id;
  final String store_id;
  final String store_name;
  final String? rls_user_id;
  final bool is_online;
  final StoreLocation location;
  final bool deleted;

  factory Store.fromJson(Map<String, dynamic> j) => Store(
        id: j['_id'] as String,
        store_id: j['store_id'] as String,
        store_name: j['store_name'] as String,
        rls_user_id: j['rls_user_id'] as String?,
        is_online: j['is_online'] as bool,
        location: StoreLocation.fromJson(j['location'] as Map<String, dynamic>),
        deleted: j['deleted'] as bool,
      );
}

class StoreLocation {
  StoreLocation({required this.address, required this.city, required this.state, required this.zip});
  final String address;
  final String city;
  final String state;
  final String zip;
  factory StoreLocation.fromJson(Map<String, dynamic> j) => StoreLocation(
        address: j['address'] as String,
        city: j['city'] as String,
        state: j['state'] as String,
        zip: j['zip'] as String,
      );
}

class Category {
  Category({required this.id, required this.category_id, required this.category_name, this.seasonal_multipliers, required this.deleted});
  final String id;
  final String category_id;
  final String category_name;
  final Map<String, double>? seasonal_multipliers;
  final bool deleted;
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['_id'] as String,
        category_id: j['category_id'] as String,
        category_name: j['category_name'] as String,
        seasonal_multipliers: (j['seasonal_multipliers'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, (v as num).toDouble())),
        deleted: j['deleted'] as bool,
      );
}

class Product {
  Product({
    required this.id,
    required this.product_id,
    required this.sku,
    required this.product_name,
    required this.category_id,
    required this.cost,
    required this.base_price,
    required this.gross_margin_percent,
    required this.deleted,
  });
  final String id;
  final String product_id;
  final String sku;
  final String product_name;
  final String category_id;
  final double cost;
  final double base_price;
  final double gross_margin_percent;
  final bool deleted;
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['_id'] as String,
        product_id: j['product_id'] as String,
        sku: j['sku'] as String,
        product_name: j['product_name'] as String,
        category_id: j['category_id'] as String,
        cost: (j['cost'] as num).toDouble(),
        base_price: (j['base_price'] as num).toDouble(),
        gross_margin_percent: (j['gross_margin_percent'] as num).toDouble(),
        deleted: j['deleted'] as bool,
      );
}

class Customer {
  Customer({
    required this.id,
    required this.customer_id,
    required this.first_name,
    required this.last_name,
    required this.email,
    this.phone,
    required this.primary_store_id,
    required this.created_at,
    required this.deleted,
  });
  final String id;
  final String customer_id;
  final String first_name;
  final String last_name;
  final String email;
  final String? phone;
  final String primary_store_id;
  final String created_at;
  final bool deleted;
  String get displayName => '$first_name $last_name';
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['_id'] as String,
        customer_id: j['customer_id'] as String,
        first_name: j['first_name'] as String,
        last_name: j['last_name'] as String,
        email: j['email'] as String,
        phone: j['phone'] as String?,
        primary_store_id: j['primary_store_id'] as String,
        created_at: j['created_at'] as String,
        deleted: j['deleted'] as bool,
      );
}

/// inventory._id is a composite document: {store_id, product_id} — the
/// composite-key teaching moment (subfield queries + explicit index).
class InventoryItem {
  InventoryItem({
    required this.id,
    required this.store_id,
    required this.product_id,
    required this.stock_level,
    required this.location,
    this.last_counted,
    this.notes,
    required this.deleted,
  });
  final InventoryCompositeId id;
  final String store_id;
  final String product_id;
  final int stock_level;
  final BinLocation location;
  final String? last_counted;
  final String? notes;
  final bool deleted;
  factory InventoryItem.fromJson(Map<String, dynamic> j) => InventoryItem(
        id: InventoryCompositeId.fromJson(j['_id'] as Map<String, dynamic>),
        store_id: j['store_id'] as String,
        product_id: j['product_id'] as String,
        stock_level: (j['stock_level'] as num).toInt(),
        location: BinLocation.fromJson(j['location'] as Map<String, dynamic>),
        last_counted: j['last_counted'] as String?,
        notes: j['notes'] as String?,
        deleted: j['deleted'] as bool,
      );
}

class InventoryCompositeId {
  InventoryCompositeId({required this.store_id, required this.product_id});
  final String store_id;
  final String product_id;
  factory InventoryCompositeId.fromJson(Map<String, dynamic> j) => InventoryCompositeId(
        store_id: j['store_id'] as String,
        product_id: j['product_id'] as String,
      );
  String get key => '$store_id|$product_id';
}

class BinLocation {
  BinLocation({required this.aisle, required this.shelf, required this.bin});
  final String aisle;
  final String shelf;
  final String bin;
  factory BinLocation.fromJson(Map<String, dynamic> j) => BinLocation(
        aisle: j['aisle'] as String,
        shelf: j['shelf'] as String,
        bin: j['bin'] as String,
      );
}

class Order {
  Order({
    required this.id,
    required this.order_id,
    required this.customer_id,
    required this.store_id,
    required this.order_date,
    required this.customer_name,
    this.customer_email,
    required this.store_name,
    required this.item_count,
    required this.subtotal,
    required this.total,
    required this.status,
    required this.deleted,
  });
  final String id;
  final String order_id;
  final String customer_id;
  final String store_id;
  final String order_date;
  final String customer_name;
  final String? customer_email;
  final String store_name;
  final int item_count;
  final double subtotal;
  final double total;
  final String status;
  final bool deleted;
  factory Order.fromJson(Map<String, dynamic> j) => Order(
        id: j['_id'] as String,
        order_id: j['order_id'] as String,
        customer_id: j['customer_id'] as String,
        store_id: j['store_id'] as String,
        order_date: j['order_date'] as String,
        customer_name: j['customer_name'] as String,
        customer_email: j['customer_email'] as String?,
        store_name: j['store_name'] as String,
        item_count: (j['item_count'] as num).toInt(),
        subtotal: (j['subtotal'] as num).toDouble(),
        total: (j['total'] as num).toDouble(),
        status: j['status'] as String,
        deleted: j['deleted'] as bool,
      );
}

class OrderItem {
  OrderItem({
    required this.id,
    required this.order_id,
    required this.store_id,
    required this.product_id,
    required this.sku,
    required this.product_name,
    required this.quantity,
    required this.unit_price,
    required this.discount_percent,
    required this.line_total,
    required this.deleted,
  });
  final String id;
  final String order_id;
  final String store_id;
  final String product_id;
  final String sku;
  final String product_name;
  final int quantity;
  final double unit_price;
  final double discount_percent;
  final double line_total;
  final bool deleted;
  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        id: j['_id'] as String,
        order_id: j['order_id'] as String,
        store_id: j['store_id'] as String,
        product_id: j['product_id'] as String,
        sku: j['sku'] as String,
        product_name: j['product_name'] as String,
        quantity: (j['quantity'] as num).toInt(),
        unit_price: (j['unit_price'] as num).toDouble(),
        discount_percent: (j['discount_percent'] as num).toDouble(),
        line_total: (j['line_total'] as num).toDouble(),
        deleted: j['deleted'] as bool,
      );
}

/// Single-row shape of `SELECT COUNT(*) AS count …` queries.
class CountRow {
  CountRow(this.count);
  final int count;
  factory CountRow.fromJson(Map<String, dynamic> j) => CountRow((j['count'] as num).toInt());
}

/// Aggregate rows decode with nullable group keys/aggregates: DQL omits them
/// on an empty match set (a degenerate `{"orders": 0}` row arrives). Screens
/// filter those rows rather than render fake zeros.
class StatusRevenueRow {
  StatusRevenueRow(this.status, this.orders, this.revenue);
  final String? status;
  final int orders;
  final double? revenue;
  factory StatusRevenueRow.fromJson(Map<String, dynamic> j) => StatusRevenueRow(
        j['status'] as String?,
        (j['orders'] as num).toInt(),
        (j['revenue'] as num?)?.toDouble(),
      );
}

class MonthTrendRow {
  MonthTrendRow(this.month, this.orders, this.revenue);
  final String? month;
  final int orders;
  final double? revenue;
  factory MonthTrendRow.fromJson(Map<String, dynamic> j) => MonthTrendRow(
        j['month'] as String?,
        (j['orders'] as num).toInt(),
        (j['revenue'] as num?)?.toDouble(),
      );
}

class TopProductRow {
  TopProductRow(this.product_id, this.revenue);
  final String? product_id;
  final double? revenue;
  factory TopProductRow.fromJson(Map<String, dynamic> j) => TopProductRow(
        j['product_id'] as String?,
        (j['revenue'] as num?)?.toDouble(),
      );
}

/// Page math for the list screens (pure — unit-tested). DQL supports
/// `LIMIT … OFFSET …`; the ints come from our own controls and are
/// interpolated into the query string (never user text).
class Paging {
  static String pageQuery(String base, String orderBy, int page, int pageSize) =>
      '$base ORDER BY $orderBy LIMIT $pageSize OFFSET ${(page - 1) * pageSize}';

  static int pageCount(int total, int pageSize) => max(1, (total / pageSize).ceil());

  static int clampPage(int page, int total, int pageSize) =>
      min(max(1, page), pageCount(total, pageSize));
}

/// Row shape of `system:data_sync_info` (the sync status virtual collection).
class SyncStatusInfo {
  SyncStatusInfo({required this.id, required this.isDittoServer, required this.syncSessionStatus, this.syncedUpToLocalCommitId});
  final String id;
  final bool isDittoServer;
  final String syncSessionStatus;
  final int? syncedUpToLocalCommitId;

  static SyncStatusInfo? from(Map<String, dynamic> row) {
    final id = row['_id'] as String?;
    if (id == null) return null;
    final documents = row['documents'] as Map<String, dynamic>?;
    return SyncStatusInfo(
      id: id,
      isDittoServer: row['is_ditto_server'] as bool? ?? false,
      syncSessionStatus: documents?['sync_session_status'] as String? ?? 'Unknown',
      syncedUpToLocalCommitId: (documents?['synced_up_to_local_commit_id'] as num?)?.toInt(),
    );
  }
}

/// Row shape of `system:indexes`.
class IndexInfo {
  IndexInfo({required this.id, required this.collection, required this.definition});
  final String id;
  final String collection;
  final String definition;

  static IndexInfo? from(Map<String, dynamic> row) {
    final rawId = row['_id'] as String?;
    if (rawId == null) return null;
    return IndexInfo(
      id: rawId,
      collection: row['collection'] as String? ?? rawId.split(':').firstOrNull ?? '?',
      definition: row['fields']?.toString() ?? '',
    );
  }
}

extension FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
