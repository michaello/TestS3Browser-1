import Foundation
import AWSS3

extension S3Service {
    /// Preserves unknown eligibility rather than presenting an unrelated rule as a prediction.
    func lifecyclePrediction(
        objectKey: String, objectCreated: Date, rules: [LifecycleRuleDisplay],
        objectSize: Int64? = nil, objectTags: [ObjectTag]? = nil,
        currentStorageClass: String? = nil, now: Date = Date(), replicationStatus: String? = nil
    ) -> LifecyclePrediction {
        LifecyclePolicy.prediction(
            key: objectKey, created: objectCreated, size: objectSize, tags: objectTags,
            currentStorageClass: currentStorageClass, rules: rules, now: now, replicationStatus: replicationStatus
        )
    }

    /// Compatibility accessor for callers that only render a known transition.
    func calculateNextTransition(
        objectKey: String,
        objectCreated: Date,
        rules: [LifecycleRuleDisplay],
        objectSize: Int64? = nil, objectTags: [ObjectTag]? = nil,
        currentStorageClass: String? = nil
    ) -> LifecycleTransition? {
        if case .next(let transition) = lifecyclePrediction(
            objectKey: objectKey, objectCreated: objectCreated, rules: rules,
            objectSize: objectSize, objectTags: objectTags, currentStorageClass: currentStorageClass
        ) {
            return transition
        }
        return nil
    }

    /// SDK fields feed the same production policy exercised by local tests.
    static func lifecycleDisplayRules(_ output: GetBucketLifecycleConfigurationOutput) -> [LifecycleRuleDisplay] {
        (output.rules ?? []).enumerated().map { index, rule in
            var additional: [String] = []
            if rule.expiration?.expiredObjectDeleteMarker == true { additional.append("Remove expired delete markers") }
            if let days = rule.noncurrentVersionExpiration?.noncurrentDays {
                additional.append("Expire noncurrent versions after \(days) days")
            }
            for transition in rule.noncurrentVersionTransitions ?? [] {
                additional.append("Noncurrent transition: \(transition.storageClass?.rawValue ?? "unknown class") after \(transition.noncurrentDays.map(String.init) ?? "unknown") days")
            }
            if let days = rule.abortIncompleteMultipartUpload?.daysAfterInitiation {
                additional.append("Abort incomplete multipart uploads after \(days) days")
            }
            return LifecycleRuleDisplay(
                id: rule.id ?? "Rule \(index + 1)", status: rule.status?.rawValue ?? "Unknown",
                expirationDays: rule.expiration?.days,
                transitions: (rule.transitions ?? []).map {
                    LifecycleTransitionDisplay(days: $0.days, storageClass: $0.storageClass?.rawValue ?? "Unknown", date: $0.date)
                },
                expirationDate: rule.expiration?.date,
                filter: lifecycleFilter(rule),
                minimumObjectSizePolicy: output.transitionDefaultMinimumObjectSize?.rawValue,
                additionalActions: additional
            )
        }
    }

    private static func lifecycleFilter(_ rule: S3ClientTypes.LifecycleRule) -> LifecycleFilter {
        guard let source = rule.filter else {
            // The legacy Prefix field remains supported, including an empty bucket-wide prefix.
            return rule.prefix.map { LifecycleFilter(prefix: $0) } ?? .unknown
        }
        if rule.prefix != nil { return .unknown }
        let variants = [source.and != nil, source.prefix != nil, source.tag != nil,
                        source.objectSizeGreaterThan != nil, source.objectSizeLessThan != nil]
        guard variants.filter({ $0 }).count <= 1 else { return .unknown }
        if let and = source.and {
            let conditionCount = [and.prefix != nil, and.objectSizeGreaterThan != nil, and.objectSizeLessThan != nil].filter { $0 }.count + (and.tags ?? []).count
            guard conditionCount >= 2 else { return .unknown }
            let tags = (and.tags ?? []).compactMap { tag -> ObjectTag? in
                guard let key = tag.key, let value = tag.value else { return nil }
                return ObjectTag(key: key, value: value)
            }
            guard tags.count == (and.tags ?? []).count else { return .unknown }
            return LifecycleFilter(prefix: and.prefix, tags: tags,
                                   sizeGreaterThan: and.objectSizeGreaterThan.map(Int64.init),
                                   sizeLessThan: and.objectSizeLessThan.map(Int64.init))
        }
        var tags: [ObjectTag] = []
        if let tag = source.tag {
            guard let key = tag.key, let value = tag.value else { return .unknown }
            tags = [ObjectTag(key: key, value: value)]
        }
        return LifecycleFilter(prefix: source.prefix, tags: tags,
                               sizeGreaterThan: source.objectSizeGreaterThan.map(Int64.init),
                               sizeLessThan: source.objectSizeLessThan.map(Int64.init))
    }
}
