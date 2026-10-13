import Foundation

struct LifecycleFilter: Equatable, Sendable {
    var prefix: String?
    var tags: [ObjectTag] = []
    var sizeGreaterThan: Int64?
    var sizeLessThan: Int64?
    var isKnown = true

    static let all = LifecycleFilter()
    static let unknown = LifecycleFilter(isKnown: false)
}

struct LifecycleTransitionDisplay: Identifiable, Equatable, Sendable {
    var id: String { "\(days.map(String.init) ?? "unknown")-\(date?.timeIntervalSince1970 ?? -1)-\(storageClass)" }
    let days: Int?
    let storageClass: String
    var date: Date? = nil

    var scheduleDescription: String {
        LifecyclePolicy.scheduleDescription(days: days, date: date) ?? "Schedule unknown"
    }
}

struct LifecycleRuleDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let expirationDays: Int?
    let transitions: [LifecycleTransitionDisplay]
    var expirationDate: Date? = nil
    var filter: LifecycleFilter = .all
    var minimumObjectSizePolicy: String? = nil
    var additionalActions: [String] = []

    var isEnabled: Bool { status == "Enabled" }
    var expirationDescription: String? {
        LifecyclePolicy.scheduleDescription(days: expirationDays, date: expirationDate)
    }
}

struct LifecycleTransition: Identifiable, Equatable, Sendable {
    let transitionDate: Date
    let targetStorageClass: String
    var id: String { "\(transitionDate.timeIntervalSince1970)-\(targetStorageClass)" }
}

enum LifecyclePrediction: Equatable, Sendable {
    case next(LifecycleTransition)
    case none
    case unknown
}

/// Evaluates current-object rules only. A missing input never means a matching filter.
/// Dates describe estimated eligibility; S3 executes eligible actions asynchronously.
enum LifecyclePolicy {
    enum Eligibility: Equatable { case matches, doesNotMatch, unknown }

    static func eligibility(
        filter: LifecycleFilter, key: String, size: Int64?, tags: [ObjectTag]?
    ) -> Eligibility {
        guard filter.isKnown else { return .unknown }
        if let prefix = filter.prefix, !key.utf8.starts(with: prefix.utf8) { return .doesNotMatch }
        var unknown = false
        if !filter.tags.isEmpty {
            if let tags {
                for required in filter.tags {
                    guard tags.contains(where: {
                        $0.key.utf8.elementsEqual(required.key.utf8)
                            && $0.value.utf8.elementsEqual(required.value.utf8)
                    }) else { return .doesNotMatch }
                }
            } else { unknown = true }
        }
        if let lower = filter.sizeGreaterThan, lower < 0 { return .unknown }
        if let upper = filter.sizeLessThan, upper < 0 { return .unknown }
        if let lower = filter.sizeGreaterThan, let upper = filter.sizeLessThan, lower >= upper {
            return .unknown
        }
        if filter.sizeGreaterThan != nil || filter.sizeLessThan != nil {
            if let size, size >= 0 {
                if let lower = filter.sizeGreaterThan, size <= lower { return .doesNotMatch }
                if let upper = filter.sizeLessThan, size >= upper { return .doesNotMatch }
            } else { unknown = true }
        }
        return unknown ? .unknown : .matches
    }

    /// AWS adds days then selects midnight UTC of the following day, independent of locale/DST.
    static func eligibilityDate(created: Date, days: Int?, date: Date?) -> Date? {
        guard (days == nil) != (date == nil) else { return nil }
        if let date { return date.timeIntervalSince1970.isFinite ? date : nil }
        guard let days, days >= 0, created.timeIntervalSince1970.isFinite else { return nil }
        let offset = Double(days) * 86_400
        let result = (floor((created.timeIntervalSince1970 + offset) / 86_400) + 1) * 86_400
        guard result.isFinite else { return nil }
        return Date(timeIntervalSince1970: result)
    }

    static func scheduleDescription(days: Int?, date: Date?) -> String? {
        var parts: [String] = []
        if let days { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd 'UTC'"
            parts.append(formatter.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func prediction(
        key: String, created: Date, size: Int64?, tags: [ObjectTag]?,
        currentStorageClass: String?, rules: [LifecycleRuleDisplay], now: Date,
        replicationStatus: String? = nil
    ) -> LifecyclePrediction {
        guard created.timeIntervalSince1970.isFinite, created <= now else { return .unknown }
        if replicationStatus == "PENDING" || replicationStatus == "FAILED" { return .none }
        if let replicationStatus, !["COMPLETE", "COMPLETED", "REPLICA"].contains(replicationStatus) { return .unknown }
        var candidates: [LifecycleTransition] = []
        var expirations: [Date] = []
        var unknown = false
        for rule in rules where (!rule.transitions.isEmpty || rule.expirationDays != nil || rule.expirationDate != nil) && rule.status != "Disabled" {
            guard rule.isEnabled else { unknown = true; continue }
            switch eligibility(filter: rule.filter, key: key, size: size, tags: tags) {
            case .doesNotMatch: continue
            case .unknown: unknown = true; continue
            case .matches: break
            }
            if rule.expirationDays != nil || rule.expirationDate != nil {
                if let expiration = eligibilityDate(created: created, days: rule.expirationDays, date: rule.expirationDate) {
                    expirations.append(expiration)
                } else { unknown = true }
            }
            for transition in rule.transitions {
                guard let currentStorageClass else { unknown = true; continue }
                if currentStorageClass == transition.storageClass { continue }
                switch storageEligibility(from: currentStorageClass, to: transition.storageClass) {
                case .doesNotMatch: continue
                case .unknown: unknown = true; continue
                case .matches: break
                }
                switch sizeEligibility(size, transition: transition.storageClass, rule: rule) {
                case .doesNotMatch: continue
                case .unknown: unknown = true; continue
                case .matches: break
                }
                guard var date = eligibilityDate(created: created, days: transition.days, date: transition.date) else {
                    unknown = true; continue
                }
                if ["STANDARD_IA", "ONEZONE_IA"].contains(transition.storageClass),
                   let minimumAge = eligibilityDate(created: created, days: 30, date: nil) {
                    date = max(date, minimumAge)
                }
                // Past date rules still apply to new matching objects, until disabled.
                candidates.append(LifecycleTransition(transitionDate: max(date, created), targetStorageClass: transition.storageClass))
            }
        }
        // An unresolved rule could precede the known candidate, so do not label it "next".
        if unknown { return .unknown }
        if let expiration = expirations.min() {
            candidates.removeAll { $0.transitionDate >= expiration }
        }
        guard let first = candidates.min(by: { $0.transitionDate < $1.transitionDate }) else { return .none }
        return .next(first)
    }

    private static func sizeEligibility(_ size: Int64?, transition: String, rule: LifecycleRuleDisplay) -> Eligibility {
        // Explicit size filters override the bucket's default minimum size behavior.
        if rule.filter.sizeGreaterThan != nil || rule.filter.sizeLessThan != nil { return .matches }
        guard let size, size >= 0 else { return .unknown }
        if size >= 128 * 1_024 { return .matches }
        switch rule.minimumObjectSizePolicy {
        case "all_storage_classes_128K": return .doesNotMatch
        case "varies_by_storage_class":
            return ["GLACIER", "DEEP_ARCHIVE"].contains(transition) ? .matches : .doesNotMatch
        default: return .unknown
        }
    }

    private static func storageEligibility(from: String, to: String) -> Eligibility {
        guard ["STANDARD_IA", "INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"].contains(to) else {
            return .unknown
        }
        let supported: [String: Set<String>] = [
            "STANDARD": ["STANDARD_IA", "INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"],
            "STANDARD_IA": ["INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"],
            "ONEZONE_IA": ["GLACIER", "DEEP_ARCHIVE"],
            "GLACIER_IR": ["GLACIER", "DEEP_ARCHIVE"],
            "GLACIER": ["DEEP_ARCHIVE"],
            "DEEP_ARCHIVE": [],
        ]
        // Intelligent-Tiering transitions depend on an access tier unavailable in HEAD.
        if from == "INTELLIGENT_TIERING" {
            return to == "DEEP_ARCHIVE" ? .matches : .unknown
        }
        guard let destinations = supported[from] else { return .unknown }
        return destinations.contains(to) ? .matches : .doesNotMatch
    }
}
