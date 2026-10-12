import Foundation
import RemoteCore
import Testing
@testable import MacCastKit

struct PhoneFailureTests {
    private enum Sample: Error { case transport(String), hostKeyChanged(String), browse(String), forward(String), tooNew(String) }

    @Test func posixErrorsMapToTheirCauseAndKeepTheNumber() {
        let refused = PhoneFailure.cause(of: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)))
        #expect(refused.cause == .refused)
        #expect(refused.code == Int(ECONNREFUSED))
        #expect(PhoneFailure.cause(of: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).cause == .diskFull)
    }

    @Test func urlAndCocoaErrorsMapToTheirCause() {
        #expect(PhoneFailure.cause(of: URLError(.notConnectedToInternet)).cause == .offline)
        #expect(PhoneFailure.cause(of: URLError(.cannotFindHost)).cause == .dnsFailed)
        #expect(PhoneFailure.cause(of: CocoaError(.fileReadNoSuchFile)).cause == .notFound)
        #expect(PhoneFailure.cause(of: CancellationError()).cause == .cancelled)
    }

    @Test func anUnknownErrorIsOtherAndCarriesNoMessage() {
        let found = PhoneFailure.cause(of: Sample.transport("secret-host.local:22"))
        #expect(found.cause == .other)
    }

    @Test func aCaseNameOutsideTheAllowedSetBecomesOther() {
        #expect(PhoneFailure.caseName(of: Sample.tooNew("/Users/ann/x"), allowed: ["transport"]) == "other")
        #expect(PhoneFailure.caseName(of: Sample.transport("x"), allowed: ["transport"]) == "transport")
    }

    @Test func pairingInputMistakesHaveOneReasonEach() {
        #expect(PhoneFailure.pairingReason(.empty) == "empty")
        #expect(PhoneFailure.pairingReason(.shortAuthenticationCode) == "pairingCodeNotAnID")
        #expect(PhoneFailure.pairingReason(.unrecognisedCode) == "notAPairingCode")
        #expect(PhoneFailure.pairingReason(.notAnIdentifier("my own text")) == "notAnID")
    }

    @Test func aRefusedPairingIsAConfirmFailureAndAnUnsavedPinIsAPinStoreFailure() {
        #expect(PhoneFailure.pairingFailure(reason: .pairingRefused, stage: .pairing)?.stage == .confirm)
        #expect(PhoneFailure.pairingFailure(reason: .pairingNotSaved, stage: .pairing)?.stage == .pinStore)
    }

    @Test func aHandshakeFailureWhilePairingReadsAsACodeMismatchAndOutsideItIsNotPairing() {
        let inside = PhoneFailure.pairingFailure(reason: .handshake, stage: .pairing)
        #expect(inside?.stage == .commit)
        #expect(inside?.reason == "codeMismatch")
        #expect(PhoneFailure.pairingFailure(reason: .timedOut, stage: .connecting) == nil)
    }

    @Test func transferPropertiesCarryDirectionStageCauseAndASizeBucket() {
        let properties = PhoneFailure.transferProperties(
            direction: .up, stage: .send, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)), bytes: 50_000_000
        )
        #expect(properties["direction"] as? String == "up")
        #expect(properties["stage"] as? String == "send")
        #expect(properties["reason"] as? String == "hostClosed")
        #expect(properties["size_bucket"] as? String == "<100MB")
        #expect(properties["error_code"] as? Int == Int(EPIPE))
    }

    @Test func aTransferOfUnknownSizeSaysSo() {
        let properties = PhoneFailure.transferProperties(direction: .down, stage: .write, error: Sample.transport("x"), bytes: nil)
        #expect(properties["size_bucket"] as? String == "unknown")
    }

    @Test func sshFailuresNameTheirStageFromTheErrorCase() {
        #expect(PhoneFailure.sshFailure(Sample.hostKeyChanged("a"), after: false).stage == .hostKey)
        #expect(PhoneFailure.sshFailure(Sample.browse("/etc/passwd"), after: true).stage == .sftp)
        #expect(PhoneFailure.sshFailure(Sample.forward("db:5432"), after: true).reason == "forwardFailed")
        #expect(PhoneFailure.sshFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost), after: false).stage == .dns)
        #expect(PhoneFailure.sshFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)), after: false).stage == .connect)
        #expect(PhoneFailure.sshFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)), after: true).stage == .channel)
    }

    @Test func pushRegistrationRecognisesMissingEntitlementAndSimulator() {
        #expect(PhoneFailure.pushReason(NSError(domain: NSCocoaErrorDomain, code: 3000)).reason == "noEntitlement")
        #expect(PhoneFailure.pushReason(NSError(domain: NSCocoaErrorDomain, code: 3010)).reason == "simulator")
        #expect(PhoneFailure.pushReason(URLError(.notConnectedToInternet)).reason == "offline")
    }

    @Test func purchaseReasonFallsBackToTheCauseForAnErrorOfAnotherType() {
        #expect(PhoneFailure.purchaseReason(URLError(.timedOut)) == "timedOut")
    }

    @Test func pinStoreUnreadableDistinguishesAKeychainStatusFromBadContents() {
        let status = PhoneFailure.pinStoreProperties(status: -25308)
        #expect(status["reason"] as? String == "keychain")
        #expect(status["error_code"] as? Int == -25308)
        #expect(PhoneFailure.pinStoreProperties(status: nil)["reason"] as? String == "undecodable")
    }

    @Test func everyEventNameIsSnakeCaseAndUnique() {
        let names = PhoneFailure.Event.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLowercase || $0 == "_" } })
    }
}
