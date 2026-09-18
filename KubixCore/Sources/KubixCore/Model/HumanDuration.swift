import Foundation

/// An age exactly as `kubectl get` prints it (`k8s.io/apimachinery/pkg/util/duration.HumanDuration`),
/// so a computed Age reads the same as the server's printed one it replaces: seconds under two
/// minutes, then progressively coarser units with a second component only where it still matters.
public enum HumanDuration {
    public static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.towardZero))
        // Up to two seconds in the future is clock skew between this machine and the cluster.
        if seconds < -1 { return "<invalid>" }
        if seconds < 0 { return "0s" }
        if seconds < 120 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 10 {
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m\(remainder)s"
        }
        if minutes < 180 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 8 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
        }
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        if hours < 24 * 8 {
            let remainder = hours % 24
            return remainder == 0 ? "\(days)d" : "\(days)d\(remainder)h"
        }
        if hours < 24 * 365 * 2 { return "\(days)d" }
        let years = days / 365
        if hours < 24 * 365 * 8 {
            let remainder = days % 365
            return remainder == 0 ? "\(years)y" : "\(years)y\(remainder)d"
        }
        return "\(years)y"
    }
}
