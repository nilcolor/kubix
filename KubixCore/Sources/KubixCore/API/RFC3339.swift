import Foundation

public enum RFC3339 {
    public static func date(from value: String) -> Date? {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        // ISO8601DateFormatter normalizes impossible dates (e.g. February 30); reject them first.
        let calendarValidator = DateFormatter()
        calendarValidator.locale = Locale(identifier: "en_US_POSIX")
        calendarValidator.calendar = Calendar(identifier: .gregorian)
        calendarValidator.timeZone = TimeZone(secondsFromGMT: 0)
        calendarValidator.isLenient = false
        calendarValidator.dateFormat = "yyyy-MM-dd"
        guard calendarValidator.date(from: String(value.prefix(10))) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
