/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import FxA
import Shared

// The version of the state schema we persist.
let StateSchemaVersion = 1

// We want an enum because the set of states is closed.  However, each state has state-specific
// behaviour, and the state's behaviour accumulates, so each state is a class.  Switch on the
// label to get exhaustive cases.
public enum FxAStateLabel: String {
    case EngagedBeforeVerified = "engagedBeforeVerified"
    case EngagedAfterVerified = "engagedAfterVerified"
    case CohabitingBeforeKeyPair = "cohabitingBeforeKeyPair"
    case CohabitingAfterKeyPair = "cohabitingAfterKeyPair"
    case Married = "married"
    case Separated = "separated"
    case Doghouse = "doghouse"

    // See http://stackoverflow.com/a/24137319
    static let allValues: [FxAStateLabel] = [
        EngagedBeforeVerified,
        EngagedAfterVerified,
        CohabitingBeforeKeyPair,
        CohabitingAfterKeyPair,
        Married,
        Separated,
        Doghouse,
    ]
}

public enum FxAActionNeeded {
    case None
    case NeedsVerification
    case NeedsPassword
    case NeedsUpgrade
}

func stateFromDictionary(dictionary: [String: AnyObject]) -> FxAState? {
    if let version = dictionary["version"] as? Int {
        if version == StateSchemaVersion {
            return stateFromDictionaryV1(dictionary)
        }
    }
    return nil
}

func stateFromDictionaryV1(dictionary: [String: AnyObject]) -> FxAState? {
    if let labelString = dictionary["label"] as? String {
        if let label = FxAStateLabel(rawValue:  labelString) {
            switch label {
            case .EngagedBeforeVerified:
                if let sessionToken = (dictionary["sessionToken"] as? String)?.hexDecodedData {
                    if let keyFetchToken = (dictionary["keyFetchToken"] as? String)?.hexDecodedData {
                        if let unwrapkB = (dictionary["unwrapkB"] as? String)?.hexDecodedData {
                            if let knownUnverifiedAt = dictionary["knownUnverifiedAt"] as? NSNumber {
                                if let lastNotifiedUserAt = dictionary["lastNotifiedUserAt"] as? NSNumber {
                                        return EngagedBeforeVerifiedState(
                                            knownUnverifiedAt: knownUnverifiedAt.longLongValue, lastNotifiedUserAt: lastNotifiedUserAt.longLongValue,
                                            sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
                                }
                            }
                        }
                    }
                }

            case .EngagedAfterVerified:
                if let sessionToken = (dictionary["sessionToken"] as? String)?.hexDecodedData {
                    if let keyFetchToken = (dictionary["keyFetchToken"] as? String)?.hexDecodedData {
                        if let unwrapkB = (dictionary["unwrapkB"] as? String)?.hexDecodedData {
                            return EngagedAfterVerifiedState(sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
                        }
                    }
                }

            case .CohabitingBeforeKeyPair:
                if let sessionToken = (dictionary["sessionToken"] as? String)?.hexDecodedData {
                    if let kA = (dictionary["kA"] as? String)?.hexDecodedData {
                        if let kB = (dictionary["kB"] as? String)?.hexDecodedData {
                            return CohabitingBeforeKeyPairState(sessionToken: sessionToken, kA: kA, kB: kB)
                        }
                    }
                }

            case .CohabitingAfterKeyPair:
                if let sessionToken = (dictionary["sessionToken"] as? String)?.hexDecodedData {
                    if let kA = (dictionary["kA"] as? String)?.hexDecodedData {
                        if let kB = (dictionary["kB"] as? String)?.hexDecodedData {
                            if let keyPairJSON = dictionary["keyPair"] as? [String: AnyObject] {
                                if let keyPair = RSAKeyPair(JSONRepresentation: keyPairJSON) {
                                    if let keyPairExpiresAt = dictionary["keyPairExpiresAt"] as? NSNumber {
                                        return CohabitingAfterKeyPairState(sessionToken: sessionToken, kA: kA, kB: kB,
                                            keyPair: keyPair, keyPairExpiresAt: keyPairExpiresAt.longLongValue)
                                    }
                                }
                            }
                        }
                    }
                }

            case .Married:
                if let sessionToken = (dictionary["sessionToken"] as? String)?.hexDecodedData {
                    if let kA = (dictionary["kA"] as? String)?.hexDecodedData {
                        if let kB = (dictionary["kB"] as? String)?.hexDecodedData {
                            if let keyPairJSON = dictionary["keyPair"] as? [String: AnyObject] {
                                if let keyPair = RSAKeyPair(JSONRepresentation: keyPairJSON) {
                                    if let keyPairExpiresAt = dictionary["keyPairExpiresAt"] as? NSNumber {
                                        if let certificate = dictionary["certificate"] as? String {
                                            if let certificateExpiresAt = dictionary["certificateExpiresAt"] as? NSNumber {
                                                return MarriedState(sessionToken: sessionToken, kA: kA, kB: kB,
                                                    keyPair: keyPair, keyPairExpiresAt: keyPairExpiresAt.longLongValue,
                                                    certificate: certificate, certificateExpiresAt: certificateExpiresAt.longLongValue)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            case .Separated:
                return SeparatedState()

            case .Doghouse:
                return DoghouseState()

            default: return nil
            }
        }
    }
    return nil
}

public protocol FxAState {
    var label: FxAStateLabel { get }
    var actionNeeded: FxAActionNeeded { get }
    func asDictionary() -> [String: AnyObject]
}

// Not an externally facing state!
public class WithLabel: FxAState {
    public var label: FxAStateLabel { return FxAStateLabel.Separated } // This is bogus, but we have to do something!

    public var actionNeeded: FxAActionNeeded {
        // Kind of nice to have this in one place.
        switch label {
        case .EngagedBeforeVerified: return .NeedsVerification
        case .EngagedAfterVerified: return .None
        case .CohabitingBeforeKeyPair: return .None
        case .CohabitingAfterKeyPair: return .None
        case .Married: return .None
        case .Separated: return .NeedsPassword
        case .Doghouse: return .NeedsUpgrade
        }
    }

    public func asDictionary() -> [String: AnyObject] {
        return [
            "version": StateSchemaVersion,
            "label": self.label.rawValue
        ]
    }
}

public class SeparatedState: WithLabel {
    override public var label: FxAStateLabel { return FxAStateLabel.Separated }

    override public init() {
        super.init()
    }
}

// Not an externally facing state!
public class ReadyForKeys: WithLabel {
    let sessionToken: NSData
    let keyFetchToken: NSData
    let unwrapkB: NSData

    init(sessionToken: NSData, keyFetchToken: NSData, unwrapkB: NSData) {
        self.sessionToken = sessionToken
        self.keyFetchToken = keyFetchToken
        self.unwrapkB = unwrapkB
        super.init()
    }

    public override func asDictionary() -> [String: AnyObject] {
        var d = super.asDictionary()
        d["sessionToken"] = sessionToken.hexEncodedString
        d["keyFetchToken"] = keyFetchToken.hexEncodedString
        d["unwrapkB"] = unwrapkB.hexEncodedString
        return d
    }
}

public class EngagedBeforeVerifiedState: ReadyForKeys {
    override public var label: FxAStateLabel { return FxAStateLabel.EngagedBeforeVerified }

    // Timestamp, in milliseconds after the epoch, when we first knew the account was unverified.
    // Use this to avoid nagging the user to verify her account immediately after connecting.
    let knownUnverifiedAt: Int64
    let lastNotifiedUserAt: Int64

    public init(knownUnverifiedAt: Int64, lastNotifiedUserAt: Int64, sessionToken: NSData, keyFetchToken: NSData, unwrapkB: NSData) {
        self.knownUnverifiedAt = knownUnverifiedAt
        self.lastNotifiedUserAt = lastNotifiedUserAt
        super.init(sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
    }

    public override func asDictionary() -> [String: AnyObject] {
        var d = super.asDictionary()
        d["knownUnverifiedAt"] = NSNumber(longLong: knownUnverifiedAt)
        d["lastNotifiedUserAt"] = NSNumber(longLong: lastNotifiedUserAt)
        return d
    }

    func withUnwrapKey(unwrapkB: NSData) -> EngagedBeforeVerifiedState {
        return EngagedBeforeVerifiedState(
            knownUnverifiedAt: knownUnverifiedAt, lastNotifiedUserAt: lastNotifiedUserAt,
            sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
    }
}

public class EngagedAfterVerifiedState: ReadyForKeys {
    override public var label: FxAStateLabel { return FxAStateLabel.EngagedAfterVerified }

    override public init(sessionToken: NSData, keyFetchToken: NSData, unwrapkB: NSData) {
        super.init(sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
    }

    func withUnwrapKey(unwrapkB: NSData) -> EngagedAfterVerifiedState {
        return EngagedAfterVerifiedState(sessionToken: sessionToken, keyFetchToken: keyFetchToken, unwrapkB: unwrapkB)
    }
}

// Not an externally facing state!
public class TokenAndKeys: WithLabel {
    let sessionToken: NSData
    public let kA: NSData
    public let kB: NSData

    init(sessionToken: NSData, kA: NSData, kB: NSData) {
        self.sessionToken = sessionToken
        self.kA = kA
        self.kB = kB
        super.init()
    }

    public override func asDictionary() -> [String: AnyObject] {
        var d = super.asDictionary()
        d["sessionToken"] = sessionToken.hexEncodedString
        d["kA"] = kA.hexEncodedString
        d["kB"] = kB.hexEncodedString
        return d
    }
}

public class CohabitingBeforeKeyPairState: TokenAndKeys {
    override public var label: FxAStateLabel { return FxAStateLabel.CohabitingBeforeKeyPair }
}

// Not an externally facing state!
public class TokenKeysAndKeyPair: TokenAndKeys {
    let keyPair: KeyPair
    // Timestamp, in milliseconds after the epoch, when keyPair expires.  After this time, generate a new keyPair.
    let keyPairExpiresAt: Int64

    init(sessionToken: NSData, kA: NSData, kB: NSData, keyPair: KeyPair, keyPairExpiresAt: Int64) {
        self.keyPair = keyPair
        self.keyPairExpiresAt = keyPairExpiresAt
        super.init(sessionToken: sessionToken, kA: kA, kB: kB)
    }

    public override func asDictionary() -> [String: AnyObject] {
        var d = super.asDictionary()
        d["keyPair"] = keyPair.JSONRepresentation()
        d["keyPairExpiresAt"] = NSNumber(longLong: keyPairExpiresAt)
        return d
    }

    func isKeyPairExpired(now: Int64) -> Bool {
        return keyPairExpiresAt < now
    }
}

public class CohabitingAfterKeyPairState: TokenKeysAndKeyPair {
    override public var label: FxAStateLabel { return FxAStateLabel.CohabitingAfterKeyPair }
}

public class MarriedState: TokenKeysAndKeyPair {
    override public var label: FxAStateLabel { return FxAStateLabel.Married }

    let certificate: String
    let certificateExpiresAt: Int64

    init(sessionToken: NSData, kA: NSData, kB: NSData, keyPair: KeyPair, keyPairExpiresAt: Int64, certificate: String, certificateExpiresAt: Int64) {
        self.certificate = certificate
        self.certificateExpiresAt = certificateExpiresAt
        super.init(sessionToken: sessionToken, kA: kA, kB: kB, keyPair: keyPair, keyPairExpiresAt: keyPairExpiresAt)
    }

    public override func asDictionary() -> [String: AnyObject] {
        var d = super.asDictionary()
        d["certificate"] = certificate
        d["certificateExpiresAt"] = NSNumber(longLong: certificateExpiresAt)
        return d
    }

    func isCertificateExpired(now: Int64) -> Bool {
        return certificateExpiresAt < now
    }

    func withoutKeyPair() -> CohabitingBeforeKeyPairState {
        let newState = CohabitingBeforeKeyPairState(sessionToken: sessionToken,
            kA: kA, kB: kB)
        return newState
    }

    func withoutCertificate() -> CohabitingAfterKeyPairState {
        let newState = CohabitingAfterKeyPairState(sessionToken: sessionToken,
            kA: kA, kB: kB,
            keyPair: keyPair, keyPairExpiresAt: keyPairExpiresAt)
        return newState
    }

    public func generateAssertionForAudience(audience: String) -> String {
        let assertion = JSONWebTokenUtils.createAssertionWithPrivateKeyToSignWith(keyPair.privateKey,
            certificate: certificate, audience: audience)
        return assertion
    }
}

public class DoghouseState: WithLabel {
    override public var label: FxAStateLabel { return FxAStateLabel.Doghouse }

    override public init() {
        super.init()
    }
}
