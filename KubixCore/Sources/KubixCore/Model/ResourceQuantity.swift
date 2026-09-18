import Foundation

/// Kubernetes `resource.Quantity` text as an exact number. The metrics API reports CPU in nanocores
/// (`1234567n`), microcores (`15u`) and bare cores (`0`), and memory in `Ki` or `Mi`, so every
/// suffix the format allows is accepted rather than only the ones a person usually types.
public enum ResourceQuantity {
    public static func parse(_ text: String) -> Decimal? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        let sign = rest.first == "-" || rest.first == "+" ? String(rest.removeFirst()) : ""
        let digits = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        // `Decimal(string:)` reads the longest prefix it can, so `1-2` would quietly become 1; the
        // shape is checked first so that a malformed quantity is rejected rather than truncated.
        guard digits.contains(where: \.isNumber), digits.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: sign + digits, locale: Locale(identifier: "en_US_POSIX")),
              let scale = scale(String(rest.dropFirst(digits.count))) else { return nil }
        return value * scale
    }

    private static let suffixes: [String: Decimal] = [
        "": 1,
        "n": power(10, -9), "u": power(10, -6), "m": power(10, -3),
        "k": power(10, 3), "M": power(10, 6), "G": power(10, 9), "T": power(10, 12), "P": power(10, 15), "E": power(10, 18),
        "Ki": power(1024, 1), "Mi": power(1024, 2), "Gi": power(1024, 3),
        "Ti": power(1024, 4), "Pi": power(1024, 5), "Ei": power(1024, 6),
    ]

    private static func scale(_ suffix: String) -> Decimal? {
        if let scale = suffixes[suffix] { return scale }
        // Decimal exponent form, `1e3` or `5E-2`. A bare `E` was exa above, so it needs digits.
        guard let first = suffix.first, first == "e" || first == "E",
              let exponent = Int(suffix.dropFirst()), abs(exponent) <= 30 else { return nil }
        return power(10, exponent)
    }

    private static func power(_ base: Int, _ exponent: Int) -> Decimal {
        if base == 10 { return Decimal(sign: .plus, exponent: exponent, significand: 1) }
        var result: Decimal = 1
        for _ in 0..<exponent { result *= Decimal(base) }
        return result
    }
}

/// Go `time.Duration` text, which is how the metrics API writes a sample's window: `13.155s`,
/// `1m0s`, `500ms`.
public enum GoDuration {
    public static func parse(_ text: String) -> TimeInterval? {
        var rest = Substring(text)
        var total: TimeInterval = 0
        guard !rest.isEmpty else { return nil }
        if rest == "0" { return 0 }
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            guard !digits.isEmpty, let value = TimeInterval(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            let unit = rest.prefix { !$0.isNumber && $0 != "." }
            guard let scale = unitScale(String(unit)) else { return nil }
            rest = rest.dropFirst(unit.count)
            total += value * scale
        }
        return total
    }

    private static func unitScale(_ unit: String) -> TimeInterval? {
        switch unit {
        case "ns": 1e-9
        case "us", "µs", "μs": 1e-6
        case "ms": 1e-3
        case "s": 1
        case "m": 60
        case "h": 3600
        default: nil
        }
    }
}

/// Usage as `kubectl top` prints it, so the numbers read the same in both places: CPU in whole
/// millicores rounded up, memory in whole mebibytes rounded down.
public enum UsageFormat {
    public static func millicores(_ nanocores: Decimal) -> Decimal {
        var value = nanocores / 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        return rounded
    }

    public static func mebibytes(_ bytes: Decimal) -> Decimal {
        var value = bytes / 1_048_576
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .down)
        return rounded
    }

    public static func cpu(_ nanocores: Decimal) -> String { "\(millicores(nanocores))m" }
    public static func memory(_ bytes: Decimal) -> String { "\(mebibytes(bytes))Mi" }
}
