import Foundation
import XCTest
import zlib
@testable import ZavaRetail

/// Data-contract tests: every app model must decode every document in the
/// committed data bundle (including explicit-null fields — compactMapValues
/// strips them before decode, so a *required* model field that is
/// null/missing in data fails with "The data couldn't be read because it is
/// missing"). The bundle is shared/data/*.ndjson.gz — Microsoft's shipped
/// Zava dataset after the transform in scripts/prepare_data.py — so these
/// tests exercise the apps against Microsoft's actual rows. Skips when the
/// bundle is absent.
final class ModelContractTests: XCTestCase {
    private var datasetDir: URL?

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZavaRetailTests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("shared/data")
            .standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("manifest.json").path
        ) else {
            datasetDir = nil
            throw XCTSkip("shared/data bundle missing — run scripts/prepare_data.py")
        }
        datasetDir = dir
    }

    /// Streams a gzipped NDJSON file (every `stride`-th line), decoding into
    /// T; fails the test on the FIRST undecodable doc with its index + error.
    private func assertAllDecode<T: Decodable>(
        _ type: T.Type, collection: String, stride: Int = 1
    ) throws {
        guard let datasetDir else { return } // skipped in setUp
        let url = datasetDir.appendingPathComponent("\(collection).ndjson.gz")
        let lines = try GzLineReader(gunzipped: url)
        var index = 0
        var checked = 0
        while let line = lines.next() {
            index += 1
            guard index % stride == 0 else { continue }
            checked += 1
            guard let doc = line.data(using: .utf8) else { continue }
            XCTAssertNoThrow(
                try JSONDecoder().decode(T.self, from: doc),
                "\(collection) line \(index) must decode as \(T.self): \(line.prefix(120))"
            )
            if checked >= 2000 {
                break
            } // bound runtime; stride covers the range
        }
        XCTAssertGreaterThan(checked, 0, "\(collection) should yield samples")
    }

    func testStoresDecode() throws {
        try assertAllDecode(Store.self, collection: "stores")
    }

    func testCategoriesDecode() throws {
        try assertAllDecode(Category.self, collection: "categories")
    }

    func testProductsDecode() throws {
        try assertAllDecode(Product.self, collection: "products")
    }

    func testProductTypesDecode() throws {
        try assertAllDecode(ProductType.self, collection: "product_types")
    }

    func testCustomersDecode() throws {
        try assertAllDecode(Customer.self, collection: "customers", stride: 25)
    }

    func testInventoryDecodes() throws {
        try assertAllDecode(InventoryItem.self, collection: "inventory")
    }

    func testOrdersDecode() throws {
        try assertAllDecode(Order.self, collection: "orders", stride: 99)
    }

    func testOrderItemsDecodeMissingItemIdsAreAllowed() throws {
        try assertAllDecode(OrderItem.self, collection: "order_items", stride: 207)
    }
}

/// Lines of a `.ndjson.gz` via zlib's gzgets (Foundation has no gzip codec;
/// the bundle ships gzipped on purpose).
private final class GzLineReader {
    private let file: gzFile?

    init(gunzipped url: URL) throws {
        file = gzopen(url.path, "rb")
        if file == nil {
            throw NSError(
                domain: "GzLineReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "gzopen failed: \(url.path)"]
            )
        }
    }

    deinit { gzclose(file) }

    func next() -> String? {
        // Bundle docs are a few hundred bytes; 64 KB lines are far past it.
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        guard let file, gzgets(file, &buf, Int32(buf.count)) != nil else { return nil }
        return String(cString: buf).trimmingCharacters(in: .newlines)
    }
}
