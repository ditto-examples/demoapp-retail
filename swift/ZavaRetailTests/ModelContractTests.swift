import XCTest
@testable import ZavaRetail

/// Data-contract tests: every app model must decode every document the
/// benchmark dataset actually contains (including explicit-null fields —
/// compactMapValues strips them before decode, so a *required* model field
/// that is null/missing in data fails with "The data couldn't be read
/// because it is missing"). Skips when the benchmark repo isn't checked out.
final class ModelContractTests: XCTestCase {
    private var datasetDir: URL?

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZavaRetailTests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("../dql-metrics-benchmark/benchmarks/retail")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: dir.path) else {
            datasetDir = nil
            throw XCTSkip("benchmark dataset repo not checked out next to this repo")
        }
        datasetDir = dir
    }

    /// Streams an NDJSON file (every `stride`-th line) decoding into T; fails
    /// the test on the FIRST undecodable doc with its index + error.
    private func assertAllDecode<T: Decodable>(
        _ type: T.Type, file: String, stride: Int = 1
    ) throws {
        guard let datasetDir else { return } // skipped in setUp
        let url = datasetDir.appendingPathComponent(file)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var index = 0
        var checked = 0
        while let line = try handle.nextLine() {
            index += 1
            guard index % stride == 0 else { continue }
            checked += 1
            guard let doc = line.data(using: .utf8) else { continue }
            XCTAssertNoThrow(
                try JSONDecoder().decode(T.self, from: doc),
                "\(file) line \(index) must decode as \(T.self)"
            )
            if checked >= 2000 {
                break
            } // bound runtime; stride covers the range
        }
        XCTAssertGreaterThan(checked, 0, "\(file) should yield samples")
    }

    func testStoresDecode() throws {
        try assertAllDecode(Store.self, file: "stores.ndjson")
    }

    func testCategoriesDecode() throws {
        try assertAllDecode(Category.self, file: "categories.ndjson")
    }

    func testProductsDecode() throws {
        try assertAllDecode(Product.self, file: "products.ndjson")
    }

    func testCustomersDecode() throws {
        try assertAllDecode(Customer.self, file: "customers.ndjson", stride: 17)
    }

    func testInventoryDecodes() throws {
        try assertAllDecode(InventoryItem.self, file: "inventory-full.ndjson")
    }

    func testOrdersDecode() throws {
        try assertAllDecode(Order.self, file: "orders-full.ndjson", stride: 53)
    }

    func testOrderItemsDecode() throws {
        try assertAllDecode(OrderItem.self, file: "order_items-full.ndjson", stride: 101)
    }
}

private extension FileHandle {
    func nextLine() throws -> String? {
        var bytes = Data()
        while true {
            guard let byte = try read(upToCount: 1)?.first else {
                return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
            }
            if byte == 0x0A {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
        }
    }
}
