/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import FxA
import Account

private let KeyLength = 32

public class KeyBundle: Equatable {
    let encKey: NSData
    let hmacKey: NSData

    public class func fromKB(kB: NSData) -> KeyBundle {
        let salt = NSData()
        let contextInfo = FxAClient10.KW("oldsync")
        let len: UInt = 64               // KeyLength + KeyLength, without type nonsense.
        let derived = kB.deriveHKDFSHA256KeyWithSalt(salt, contextInfo: contextInfo, length: len)
        return KeyBundle(encKey: derived.subdataWithRange(NSRange(location: 0, length: KeyLength)),
                         hmacKey: derived.subdataWithRange(NSRange(location: KeyLength, length: KeyLength)))
    }

    public class func random() -> KeyBundle {
        // Bytes.generateRandomBytes uses SecRandomCopyBytes, which hits /dev/random, which
        // on iOS is populated by the OS from kernel-level sources of entropy.
        // That should mean that we don't need to seed or initialize anything before calling
        // this. That is probably not true on (some versions of) OS X.
        return KeyBundle(encKey: Bytes.generateRandomBytes(32), hmacKey: Bytes.generateRandomBytes(32))
    }

    public class var invalid: KeyBundle {
        return KeyBundle(encKeyB64: "deadbeef", hmacKeyB64: "deadbeef")
    }

    public init(encKeyB64: String, hmacKeyB64: String) {
        self.encKey = Bytes.decodeBase64(encKeyB64)
        self.hmacKey = Bytes.decodeBase64(hmacKeyB64)
    }

    public init(encKey: NSData, hmacKey: NSData) {
        self.encKey = encKey
        self.hmacKey = hmacKey
    }

    private func _hmac(ciphertext: NSData) -> (data: UnsafeMutablePointer<CUnsignedChar>, len: Int) {
        let hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        let digestLen: Int = Int(CC_SHA256_DIGEST_LENGTH)
        let result = UnsafeMutablePointer<CUnsignedChar>.alloc(digestLen)
        CCHmac(hmacAlgorithm, hmacKey.bytes, UInt(hmacKey.length), ciphertext.bytes, UInt(ciphertext.length), result)
        return (result, digestLen)
    }

    public func hmac(ciphertext: NSData) -> NSData {
        let (result, digestLen) = _hmac(ciphertext)
        var data = NSMutableData(bytes: result, length: digestLen)

        result.destroy()
        return data
    }

    /**
     * Returns a hex string for the HMAC.
     */
    public func hmacString(ciphertext: NSData) -> String {
        let (result, digestLen) = _hmac(ciphertext)
        var hash = NSMutableString()
        for i in 0..<digestLen {
            hash.appendFormat("%02x", result[i])
        }

        result.destroy()
        return String(hash)
    }

    public func encrypt(cleartext: NSData, iv: NSData?=nil) -> (ciphertext: NSData, iv: NSData)? {
        let iv = iv ?? Bytes.generateRandomBytes(16)

        let (success, b, copied) = self.crypt(cleartext, iv: iv, op: CCOperation(kCCEncrypt))
        if success == CCCryptorStatus(kCCSuccess) {
            // Hooray!
            let d = NSData(bytes: b, length: Int(copied))
            b.destroy()
            return (d, iv)
        }

        b.destroy()
        return nil
    }

    // You *must* verify HMAC before calling this.
    public func decrypt(ciphertext: NSData, iv: NSData) -> String? {
        let (success, b, copied) = self.crypt(ciphertext, iv: iv, op: CCOperation(kCCDecrypt))
        if success == CCCryptorStatus(kCCSuccess) {
            // Hooray!
            let d = NSData(bytesNoCopy: b, length: Int(copied))
            let s = NSString(data: d, encoding: NSUTF8StringEncoding)
            b.destroy()
            return s
        }

        b.destroy()
        return nil
    }


    private func crypt(input: NSData, iv: NSData, op: CCOperation) -> (status: CCCryptorStatus, buffer: UnsafeMutablePointer<CUnsignedChar>, count: UInt) {
        let resultSize = input.length + kCCBlockSizeAES128
        let result = UnsafeMutablePointer<CUnsignedChar>.alloc(resultSize)
        var copied: UInt = 0

        let success: CCCryptorStatus =
        CCCrypt(op,
                CCHmacAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                encKey.bytes,
                UInt(kCCKeySizeAES256),
                iv.bytes,
                input.bytes,
                UInt(input.length),
                result,
                UInt(resultSize),
                &copied
        );

        return (success, result, copied)
    }

    public func verify(#hmac: NSData, ciphertextB64: NSData) -> Bool {
        let expectedHMAC = hmac
        let computedHMAC = self.hmac(ciphertextB64)
        return expectedHMAC.isEqualToData(computedHMAC)
    }

    /**
     * Swift can't do functional factories. I would like to have one of the following
     * approaches be viable:
     *
     * 1. Derive the constructor from the consumer of the factory.
     * 2. Accept a type as input.
     *
     * Neither of these are viable, so we instead pass an explicit constructor closure.
     *
     * Most of these approaches produce either odd compiler errors, or -- worse --
     * compile and then yield runtime EXC_BAD_ACCESS (see Radar 20230159).
     *
     * For this reason, be careful trying to simplify or improve this code.
     */
    public func factory<T : CleartextPayloadJSON>(f: (JSON) -> T) -> (String) -> T? {
        return { (payload: String) -> T? in
            let potential = EncryptedJSON(json: payload, keyBundle: self)
            if !(potential.isValid()) {
                return nil
            }

            let cleartext = potential.cleartext
            if (cleartext == nil) {
                return nil
            }
            return f(cleartext!)
        }
    }
}

public func == (lhs: KeyBundle, rhs: KeyBundle) -> Bool {
    return lhs.encKey.isEqualToData(rhs.encKey) &&
           lhs.hmacKey.isEqualToData(rhs.hmacKey)
}

public class Keys {
    let valid: Bool
    let defaultBundle: KeyBundle
    var collectionKeys: [String: KeyBundle] = [String: KeyBundle]()

    public init(defaultBundle: KeyBundle) {
        self.defaultBundle = defaultBundle
        self.valid = true
    }

    public init(downloaded: EnvelopeJSON, master: KeyBundle) {
        let f = {
            (j: JSON) -> KeysPayload in
            return KeysPayload(j)
        }
        let keysRecord = Record<KeysPayload>.fromEnvelope(downloaded, payloadFactory: master.factory(f))
        if let payload: KeysPayload = keysRecord?.payload {
            if payload.isValid() {
                if let keys = payload.defaultKeys {
                    self.defaultBundle = keys
                    self.valid = true
                    return
                }
            }

            self.defaultBundle = KeyBundle.invalid
            self.valid = false
            return
        }

        self.defaultBundle = KeyBundle.invalid
        self.valid = true
    }

    public func forCollection(collection: String) -> KeyBundle {
        if let bundle = collectionKeys[collection] {
            return bundle
        }
        return defaultBundle
    }

    public func factory<T : CleartextPayloadJSON>(collection: String, f: (JSON) -> T) -> (String) -> T? {
        let bundle = forCollection(collection)
        return bundle.factory(f)
    }
}
