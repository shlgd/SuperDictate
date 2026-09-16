import Foundation
import Security

enum UpdateSigning {
    static func validateUpgrade(from installed: URL, to candidate: URL) throws {
        let current = try code(at: installed)
        let next = try code(at: candidate)
        guard try hasCertificate(next) else { throw SuperDictateUpdateInstallerError.signingIdentityChanged }
        // Legacy ad-hoc releases need one migration; subsequent releases must keep the identity.
        guard try hasCertificate(current) else { return }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(next, [], requirement) == errSecSuccess else {
            throw SuperDictateUpdateInstallerError.signingIdentityChanged
        }
    }

    private static func code(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw SuperDictateUpdateInstallerError.invalidBundle("invalid code signature")
        }
        return code
    }

    private static func hasCertificate(_ code: SecStaticCode) throws -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let information = information as? [String: Any] else {
            throw SuperDictateUpdateInstallerError.invalidBundle("missing signing information")
        }
        return !(information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []).isEmpty
    }
}
