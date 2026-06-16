import Foundation
import AWSS3

extension S3Service {
    /// Calculates the next lifecycle transition for an object based on the bucket's lifecycle rules and object creation date.
    /// - Parameters:
    ///   - objectKey: The S3 object key
    ///   - objectCreated: The object's creation/last-modified date
    ///   - rules: The bucket's lifecycle rules
    /// - Returns: LifecycleTransition describing the next transition, or nil if no transition applies.
    func calculateNextTransition(
        objectKey: String,
        objectCreated: Date,
        rules: [LifecycleRuleDisplay]
    ) -> LifecycleTransition? {
        let now = Date()
        var candidates: [LifecycleTransition] = []

        for rule in rules {
            guard rule.isEnabled else { continue }

            for transition in rule.transitions {
                guard let days = transition.days else { continue }

                let transitionDate = Calendar.current.date(byAdding: .day, value: days, to: objectCreated) ?? Date.distantFuture
                if transitionDate > now {
                    candidates.append(LifecycleTransition(
                        transitionDate: transitionDate,
                        targetStorageClass: transition.storageClass
                    ))
                }
            }
        }

        guard !candidates.isEmpty else { return nil }

        candidates.sort { $0.transitionDate < $1.transitionDate }
        return candidates.first
    }
}
