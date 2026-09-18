import Foundation
import KubixCore
import Testing

@Suite struct ResourceUsageFormatTests {
    /// Every suffix the metrics API was seen to use on a live cluster, and the rest of the format.
    @Test(arguments: [
        ("0", Decimal(0)), ("1", 1), ("1.5", Decimal(string: "1.5")!), ("-1", -1),
        ("1234567n", Decimal(string: "0.001234567")!), ("15u", Decimal(string: "0.000015")!), ("250m", Decimal(string: "0.25")!),
        ("2k", 2000), ("3M", 3_000_000), ("1G", 1_000_000_000),
        ("131072Ki", 134_217_728), ("128Mi", 134_217_728), ("2Gi", 2_147_483_648),
        ("1e3", 1000), ("5E-2", Decimal(string: "0.05")!),
    ])
    func quantitiesParseExactly(_ text: String, _ expected: Decimal) {
        #expect(ResourceQuantity.parse(text) == expected)
    }

    @Test(arguments: ["", "Mi", "abc", "1.2.3", "1Xi", "1-2", "--1", "1e", "e3"])
    func malformedQuantitiesAreRejectedRatherThanTruncated(_ text: String) {
        #expect(ResourceQuantity.parse(text) == nil)
    }

    @Test(arguments: [
        ("13.155s", 13.155), ("1m0s", 60), ("500ms", 0.5), ("1h2m3.5s", 3723.5), ("0", 0), ("0s", 0), ("250us", 0.00025),
    ])
    func goDurationsParse(_ text: String, _ expected: Double) throws {
        let parsed = try #require(GoDuration.parse(text))
        #expect(abs(parsed - expected) < 1e-9)
    }

    @Test(arguments: ["", "s", "5x", "1.2.3s", "m5"])
    func malformedDurationsAreRejected(_ text: String) {
        #expect(GoDuration.parse(text) == nil)
    }

    /// `kubectl top` rounds CPU up to a whole millicore and memory down to a whole mebibyte.
    @Test func usageReadsAsKubectlTopPrintsIt() {
        #expect(UsageFormat.cpu(0) == "0m")
        #expect(UsageFormat.cpu(1_234_567) == "2m")
        #expect(UsageFormat.cpu(250_000_000) == "250m")
        #expect(UsageFormat.cpu(250_400_000) == "251m")
        #expect(UsageFormat.memory(134_217_728) == "128Mi")
        #expect(UsageFormat.memory(134_217_727) == "127Mi")
        #expect(UsageFormat.memory(0) == "0Mi")
    }

    /// The same table `duration.HumanDuration` produces, including the observed live values
    /// `6h44m`, `23h`, `99m` and `3h9m` a server-printed Age showed.
    @Test(arguments: [
        (-2.0, "<invalid>"), (-1, "0s"), (0, "0s"), (59, "59s"), (119, "119s"),
        (120, "2m"), (125, "2m5s"), (599, "9m59s"), (600, "10m"), (5940, "99m"), (10799, "179m"),
        (10800, "3h"), (11340, "3h9m"), (24240, "6h44m"), (28800, "8h"), (82800, "23h"), (169_200, "47h"),
        (172_800, "2d"), (180_000, "2d2h"), (687_600, "7d23h"), (691_200, "8d"), (34_560_000, "400d"),
        (63_072_000, "2y"), (63_504_000, "2y5d"), (252_288_000, "8y"),
    ])
    func agesReadAsKubectlPrintsThem(_ seconds: Double, _ expected: String) {
        #expect(HumanDuration.format(seconds) == expected)
    }
}
