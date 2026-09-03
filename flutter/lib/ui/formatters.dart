/// 1:1 with the Swift reference's Formatters.
class Formatters {
  /// US currency. Manual (no intl dependency): $ + thousands-grouped dollars
  /// + two decimals.
  static String usd(double value) {
    final negative = value < 0;
    final totalCents = (value.abs() * 100).round();
    final dollars = totalCents ~/ 100;
    final cents = totalCents % 100;
    final out = StringBuffer(negative ? '-\$' : '\$');
    final digits = dollars.toString();
    for (var i = 0; i < digits.length; i++) {
      final remaining = digits.length - i;
      out.write(digits[i]);
      if (remaining > 1 && remaining % 3 == 1) out.write(',');
    }
    return '$out.${cents.toString().padLeft(2, '0')}';
  }

  /// "2025-06-27T18:20:00Z" → "2025-06-27 18:20" — string surgery only
  /// (ISO strings sort lexicographically; no date math needed).
  static String dateTime(String iso) =>
      iso.length >= 16 ? '${iso.substring(0, 10)} ${iso.substring(11, 16)}' : iso;
}
