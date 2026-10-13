import Foundation
import Testing
@testable import AuditCore

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func rule(filter: LifecycleFilter = .all, status: String = "Enabled") -> LifecycleRuleDisplay {
    LifecycleRuleDisplay(
        id: "archive", status: status, expirationDays: nil,
        transitions: [LifecycleTransitionDisplay(days: 3, storageClass: "GLACIER")],
        filter: filter, minimumObjectSizePolicy: "all_storage_classes_128K"
    )
}

private func prediction(
    _ rules: [LifecycleRuleDisplay], key: String = "logs/one.txt", size: Int64? = 1_000_000,
    tags: [ObjectTag]? = [], storage: String? = "STANDARD"
) -> LifecyclePrediction {
    LifecyclePolicy.prediction(
        key: key, created: date("2026-10-01T10:30:00Z"), size: size, tags: tags,
        currentStorageClass: storage, rules: rules, now: date("2026-10-02T12:00:00Z")
    )
}

struct AuditN26 {
    @Test func prefixAndStatusExcludeUnrelatedObjects() {
        #expect(prediction([rule(filter: LifecycleFilter(prefix: "logs/"))], key: "images/one.jpg") == .none)
        #expect(prediction([rule(status: "Disabled")]) == .none)
        #expect(prediction([rule(status: "Unknown")]) == .unknown)
        #expect(prediction([rule(filter: .unknown)]) == .unknown)
        #expect(prediction([rule(filter: LifecycleFilter(prefix: "é/"))], key: "e\u{301}/file") == .none)
        if case .next = prediction([rule(filter: LifecycleFilter(prefix: "logs/"))]) {} else {
            Issue.record("Matching enabled prefix rule lost its transition")
        }
    }

    @Test func andFiltersRequireExactTagsAndStrictSizeBounds() {
        let filter = LifecycleFilter(prefix: "logs/", tags: [ObjectTag(key: "tier", value: "cold")], sizeGreaterThan: 100, sizeLessThan: 200)
        #expect(prediction([rule(filter: filter)], size: 150, tags: nil) == .unknown)
        #expect(prediction([rule(filter: filter)], size: 150, tags: []) == .none)
        #expect(prediction([rule(filter: filter)], size: 150, tags: [ObjectTag(key: "tier", value: "hot")]) == .none)
        let tags = [ObjectTag(key: "tier", value: "cold"), ObjectTag(key: "extra", value: "preserved")]
        #expect(prediction([rule(filter: filter)], size: 100, tags: tags) == .none)
        #expect(prediction([rule(filter: filter)], size: 200, tags: tags) == .none)
        #expect(prediction([rule(filter: filter)], size: nil, tags: tags) == .unknown)
        if case .next = prediction([rule(filter: filter)], size: 150, tags: tags) {} else {
            Issue.record("All matching AND conditions did not produce a transition")
        }
    }

    @Test func missingTagsDoNotHideKnownPrefixMismatch() {
        let filter = LifecycleFilter(prefix: "private/", tags: [ObjectTag(key: "a", value: "b")])
        #expect(prediction([rule(filter: filter)], tags: nil) == .none)
    }

    @Test func invalidSizeBoundsAndByteDistinctTagsRemainSafe() {
        #expect(prediction([rule(filter: LifecycleFilter(sizeGreaterThan: 200, sizeLessThan: 100))]) == .unknown)
        #expect(prediction([rule(filter: LifecycleFilter(sizeLessThan: -1))]) == .unknown)
        let filter = LifecycleFilter(tags: [ObjectTag(key: "tag", value: "é")])
        #expect(prediction([rule(filter: filter)], tags: [ObjectTag(key: "tag", value: "e\u{301}")]) == .none)
    }

    @Test func defaultMinimumAndCurrentStorageClassAffectTransitions() {
        #expect(prediction([rule()], size: 128 * 1_024 - 1) == .none)
        if case .next = prediction([rule()], size: 128 * 1_024) {} else { Issue.record("Minimum size boundary excluded") }
        #expect(prediction([rule()], size: nil) == .unknown)
        #expect(prediction([rule()], storage: nil) == .unknown)
        #expect(prediction([rule()], storage: "GLACIER") == .none)
        #expect(prediction([rule()], storage: "DEEP_ARCHIVE") == .none)
        var legacy = rule();legacy.minimumObjectSizePolicy = "varies_by_storage_class"
        if case .next = prediction([legacy], size: 100) {} else { Issue.record("Legacy Glacier size policy lost") }
        var unknown = rule();unknown.minimumObjectSizePolicy = nil
        #expect(prediction([unknown], size: 100) == .unknown)
    }

    @Test func unknownEarlierRuleCannotCertifyAnotherAsNext() {
        let tagged = rule(filter: LifecycleFilter(tags: [ObjectTag(key: "tier", value: "cold")]))
        #expect(prediction([rule(), tagged], tags: nil) == .unknown)
    }

    @Test func replicationAndMinimumAgePreventPrematurePrediction() {
        for replication in ["PENDING", "FAILED"] {
            #expect(LifecyclePolicy.prediction(key: "logs/a", created: date("2026-10-01T10:30:00Z"), size: 1_000_000, tags: [], currentStorageClass: "STANDARD", rules: [rule()], now: date("2026-10-02T00:00:00Z"), replicationStatus: replication) == .none)
        }
        let young = LifecycleRuleDisplay(id: "IA-date", status: "Enabled", expirationDays: nil, transitions: [LifecycleTransitionDisplay(days: nil, storageClass: "STANDARD_IA", date: date("2026-10-02T00:00:00Z"))])
        #expect(prediction([young]) == .next(LifecycleTransition(transitionDate: date("2026-11-01T00:00:00Z"), targetStorageClass: "STANDARD_IA")))
    }
}

struct AuditN27 {
    @Test(arguments: [
        ("2014-01-15T10:30:00Z", 3, "2014-01-19T00:00:00Z"),
        ("2026-03-08T09:30:00Z", 1, "2026-03-10T00:00:00Z"),
        ("2026-10-01T23:59:59Z", 0, "2026-10-02T00:00:00Z"),
        ("2026-10-01T00:00:00Z", 0, "2026-10-02T00:00:00Z"),
    ])
    func dayEligibilityUsesNextUTCMidnight(fixture: (String, Int, String)) {
        #expect(LifecyclePolicy.eligibilityDate(created: date(fixture.0), days: fixture.1, date: nil) == date(fixture.2))
    }

    @Test func invalidAndConflictingSchedulesAreUnknown() {
        #expect(LifecyclePolicy.eligibilityDate(created: .now, days: -1, date: nil) == nil)
        #expect(LifecyclePolicy.eligibilityDate(created: .now, days: nil, date: nil) == nil)
        #expect(LifecyclePolicy.eligibilityDate(created: .now, days: 1, date: .now) == nil)
    }
}

struct AuditN29 {
    @Test func dateOnlySchedulesRemainVisibleAndCalculable() throws {
        let transitionDate = date("2026-11-01T00:00:00Z")
        let expirationDate = date("2026-12-01T00:00:00Z")
        let transition = LifecycleTransitionDisplay(days: nil, storageClass: "GLACIER", date: transitionDate)
        let policy = LifecycleRuleDisplay(id: "by-date", status: "Enabled", expirationDays: nil, transitions: [transition], expirationDate: expirationDate)
        #expect(transition.scheduleDescription == "2026-11-01 UTC")
        #expect(policy.expirationDescription == "2026-12-01 UTC")
        #expect(prediction([policy]) == .next(LifecycleTransition(transitionDate: transitionDate, targetStorageClass: "GLACIER")))
    }

    @Test func daysAndDatesCoexistAcrossRulesAndExpireFirstWins() {
        let absolute = LifecycleRuleDisplay(id: "absolute", status: "Enabled", expirationDays: nil, transitions: [LifecycleTransitionDisplay(days: nil, storageClass: "DEEP_ARCHIVE", date: date("2026-11-01T00:00:00Z"))])
        #expect(prediction([absolute, rule()]) == .next(LifecycleTransition(transitionDate: date("2026-10-05T00:00:00Z"), targetStorageClass: "GLACIER")))
        var expiresFirst = rule();expiresFirst.expirationDate = date("2026-10-04T00:00:00Z")
        #expect(prediction([expiresFirst]) == .none)
        let separateExpiration = LifecycleRuleDisplay(id: "expire", status: "Enabled", expirationDays: 1, transitions: [])
        #expect(prediction([rule(), separateExpiration]) == .none)
    }

    @Test func pastDateRulesContinueApplyingToNewMatchingObjects() {
        let absolute = LifecycleRuleDisplay(id: "past-date", status: "Enabled", expirationDays: nil, transitions: [LifecycleTransitionDisplay(days: nil, storageClass: "GLACIER", date: date("2026-01-01T00:00:00Z"))])
        #expect(prediction([absolute]) == .next(LifecycleTransition(transitionDate: date("2026-10-01T10:30:00Z"), targetStorageClass: "GLACIER")))
        #expect(LifecycleTransitionDisplay(days: 30, storageClass: "GLACIER").scheduleDescription == "30 days")
    }
}
