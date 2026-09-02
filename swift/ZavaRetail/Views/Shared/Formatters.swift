import Foundation

enum Formatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    static func usd(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// "2025-06-27T18:20:00Z" → "2025-06-27 18:20"
    static func dateTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        return "\(iso.prefix(10)) \(iso.dropFirst(11).prefix(5))"
    }
}
