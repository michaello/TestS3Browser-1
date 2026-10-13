import Foundation
import Testing
@testable import AuditCore

@MainActor
struct AuditN41 {
    struct ServiceFailure: Error, Equatable { let code: String }
    enum Failure: Error { case offline }
    private func code(_ error: any Error) -> String? { (error as? ServiceFailure)?.code }
    private var identity: AdministrationIdentity {
        AdministrationIdentity(configuration: ServiceConfiguration(account: "a", credentialRevision: "revision", bucket: "bucket", prefix: ""))
    }

    @Test(arguments: BucketAdministrationResource.allCases)
    func onlyTheExactOperationAbsenceCodeReturnsAnAbsentResult(_ resource: BucketAdministrationResource) async throws {
        let absent: [String] = try await BucketAdministrationRead.perform(resource, absent: [], serviceCode: code) {
            throw ServiceFailure(code: resource.absenceCode)
        }
        #expect(absent.isEmpty)
        for other in BucketAdministrationResource.allCases where other != resource {
            await #expect(throws: ServiceFailure(code: other.absenceCode)) {
                try await BucketAdministrationRead.perform(resource, absent: [String](), serviceCode: code) {
                    throw ServiceFailure(code: other.absenceCode)
                }
            }
        }
    }

    @Test(arguments: BucketAdministrationResource.allCases, ["AccessDenied", "NoSuchBucket", "PermanentRedirect", "NotFound", "UnknownFailure"])
    func deniedWrongBucketAndUnknownServiceFailuresRemainErrors(_ resource: BucketAdministrationResource, _ failure: String) async {
        await #expect(throws: ServiceFailure(code: failure)) {
            try await BucketAdministrationRead.perform(resource, absent: [String](), serviceCode: code) {
                throw ServiceFailure(code: failure)
            }
        }
    }

    @Test func networkAndMalformedResponsesCannotBecomeKnownAbsence() async {
        await #expect(throws: Failure.offline) {
            try await BucketAdministrationRead.perform(.cors, absent: [String](), serviceCode: code) { throw Failure.offline }
        }
        await #expect(throws: BucketAdministrationReadError.invalidResponse(.lifecycle)) {
            try await BucketAdministrationRead.perform(.lifecycle, absent: [String](), serviceCode: code) {
                throw BucketAdministrationReadError.invalidResponse(.lifecycle)
            }
        }
    }

    @Test func cancellationCannotPublishAnAbsentConfiguration() async {
        await #expect(throws: CancellationError.self) {
            try await BucketAdministrationRead.perform(.policy, absent: String?.none,
                serviceCode: { _ in BucketAdministrationResource.policy.absenceCode }) { throw CancellationError() }
        }
    }

    @Test func loadedAbsentAndFailedStatesStayDistinctAndFailureCanRetry() async {
        let section = AdministrationSection<[String]>()
        let key = identity
        await section.load(key, expanded: true) {
            try await BucketAdministrationRead.perform(.cors, absent: [], serviceCode: code) { throw ServiceFailure(code: "AccessDenied") }
        }
        #expect(section.hasLoaded == false)
        #expect(section.value == nil)
        #expect(section.error != nil)
        await section.load(key, expanded: true, force: true) {
            try await BucketAdministrationRead.perform(.cors, absent: [], serviceCode: code) { throw ServiceFailure(code: "NoSuchCORSConfiguration") }
        }
        #expect(section.hasLoaded)
        #expect(section.value == [])
        #expect(section.error == nil)
        await section.load(key, expanded: true, force: true) {
            try await BucketAdministrationRead.perform(.cors, absent: [], serviceCode: code) { ["configured-rule"] }
        }
        #expect(section.value == ["configured-rule"])
    }

    @Test func failedRefreshRetainsGoodRulesWhilePublishingARetryableFailure() async {
        let section = AdministrationSection<[String]>()
        let key = identity
        await section.load(key, expanded: true) { ["saved-rule"] }
        await section.load(key, expanded: true, force: true) {
            try await BucketAdministrationRead.perform(.lifecycle, absent: [], serviceCode: code) { throw Failure.offline }
        }
        #expect(section.value == ["saved-rule"])
        #expect(section.error != nil)
        #expect(section.isLoading == false)
    }
}
