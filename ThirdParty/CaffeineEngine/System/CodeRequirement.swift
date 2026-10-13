import Foundation
import Security

/// Code requirements as the recovery LaunchAgent pins them. The agent runs
/// `codesign --verify --strict -R=<text>` on the app bundle before it
/// executes the backstop.sh sealed inside (LaunchdBackstop, install.sh).
/// This type reads that text and runs the same check in process.
///
/// For an ad-hoc signature the designated requirement is the cdhash of the
/// signed code, `cdhash H"..."`, one per architecture slice, so it changes
/// with every build and no other bundle satisfies it. For a Developer ID
/// signature it names the bundle identifier and the team, so an upgrade
/// signed by the same team still satisfies it.
///
/// `SecRequirementCopyString` prints the same text as `codesign -d -r-`,
/// which install.sh reads; the two must agree for the app to recognise the
/// plist install.sh wrote (PackagingTests checks this on a scratch bundle).
enum CodeRequirement {
    struct ReadError: LocalizedError {
        let path: String
        let step: String
        let status: OSStatus
        var errorDescription: String? {
            "could not read the code requirement of \(path) (\(step)): \(CodeRequirement.message(for: status))"
        }
    }

    /// The agent's check failed: the code at `path` does not satisfy
    /// `requirement` right now (edited sealed resource, another build, or
    /// no valid signature).
    struct VerifyError: LocalizedError {
        let path: String
        let requirement: String
        let reason: String
        var errorDescription: String? {
            "\(path) does not satisfy the code requirement \(requirement): \(reason)"
        }
    }

    /// The code this process runs: the path the kernel loaded it from (the
    /// bundle, for a bundled app) and its designated requirement.
    struct RunningCode {
        let path: URL
        let requirement: String
    }

    /// `codesign --verify --strict`: all architectures, strict validation,
    /// resources included.
    private static let strictFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))

    /// Designated requirement text of the code at `url` (a bundle or a bare
    /// executable). Throws when the path is not signed or cannot be read.
    /// Reading it does not validate the code: a bundle whose sealed script
    /// was edited after signing still reads its old requirement.
    static func designated(ofCodeAt url: URL) throws -> String {
        try designated(of: staticCode(at: url), path: url.path)
    }

    /// The agent's own check, in process: the code at `url` passes strict
    /// static validation (resource seal included) and satisfies
    /// `requirement`. Throws VerifyError with codesign's reason otherwise.
    static func verify(codeAt url: URL, satisfies requirement: String) throws {
        let code = try staticCode(at: url)
        var parsed: SecRequirement?
        let made = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
        guard made == errSecSuccess, let parsed else {
            throw VerifyError(path: url.path, requirement: requirement, reason: "the requirement does not parse (\(message(for: made)))")
        }
        var error: Unmanaged<CFError>?
        let checked = SecStaticCodeCheckValidityWithErrors(code, strictFlags, parsed, &error)
        guard checked == errSecSuccess else {
            throw VerifyError(path: url.path, requirement: requirement, reason: reason(for: checked, error?.takeRetainedValue()))
        }
    }

    /// Identity of the running process, from the kernel's view of it
    /// (SecCodeCopySelf). The requirement is read only after
    /// SecCodeCheckValidity confirmed that the code on disk at that path is
    /// still the code that is running; a bundle re-signed since launch fails
    /// that check instead of handing out its new requirement.
    ///
    /// The requirement is then read from the path, not from the running
    /// code object: for a universal binary the latter describes only the
    /// slice that is running (one cdhash), while codesign, and so the agent
    /// and install.sh, verify every slice and print `cdhash A or cdhash B`.
    static func running() throws -> RunningCode {
        var dynamic: SecCode?
        let got = SecCodeCopySelf([], &dynamic)
        guard got == errSecSuccess, let dynamic else {
            throw ReadError(path: "this process", step: "SecCodeCopySelf", status: got)
        }
        var code: SecStaticCode?
        let copied = SecCodeCopyStaticCode(dynamic, [], &code)
        guard copied == errSecSuccess, let code else {
            throw ReadError(path: "this process", step: "SecCodeCopyStaticCode", status: copied)
        }
        var cfPath: CFURL?
        let located = SecCodeCopyPath(code, [], &cfPath)
        guard located == errSecSuccess, let path = cfPath as URL? else {
            throw ReadError(path: "this process", step: "SecCodeCopyPath", status: located)
        }
        let valid = SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), nil)
        guard valid == errSecSuccess else {
            throw ReadError(path: path.path, step: "SecCodeCheckValidity, the code on disk is not the code that is running", status: valid)
        }
        return RunningCode(path: path, requirement: try designated(ofCodeAt: path))
    }

    /// What LaunchdBackstop pins for `bundle`, read at every arm().
    ///
    /// When this process runs from an app bundle (`mainBundle` ends in
    /// `.app`), that bundle must be `bundle` and the requirement is the
    /// running code's own, so a bundle replaced and re-signed under the app
    /// since it started is refused rather than re-pinned. A process outside
    /// any bundle (a `swift run` development build arming the agent for the
    /// installed app) has no identity to compare with and reads the
    /// requirement from the bundle on disk.
    ///
    /// Either way the bundle must pass the agent's own check against the
    /// result right now, so a sealed script edited after signing fails here,
    /// while the app can still report it, instead of at every run of the
    /// agent.
    static func pin(
        bundle: URL,
        running: () throws -> RunningCode = CodeRequirement.running,
        mainBundle: URL = Bundle.main.bundleURL
    ) throws -> String {
        let requirement: String
        if mainBundle.pathExtension == "app" {
            let me = try running()
            guard me.path.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath() else {
                throw VerifyError(path: bundle.path, requirement: me.requirement, reason: "this process runs from \(me.path.path), not from that bundle")
            }
            requirement = me.requirement
        } else {
            requirement = try designated(ofCodeAt: bundle)
        }
        try verify(codeAt: bundle, satisfies: requirement)
        return requirement
    }

    // MARK: Security framework plumbing

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            throw ReadError(path: url.path, step: "SecStaticCodeCreateWithPath", status: created)
        }
        return code
    }

    private static func designated(of code: SecStaticCode, path: String) throws -> String {
        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard copied == errSecSuccess, let requirement else {
            throw ReadError(path: path, step: "SecCodeCopyDesignatedRequirement", status: copied)
        }
        var text: CFString?
        let printed = SecRequirementCopyString(requirement, [], &text)
        guard printed == errSecSuccess, let text else {
            throw ReadError(path: path, step: "SecRequirementCopyString", status: printed)
        }
        return text as String
    }

    /// codesign's wording for the status, plus the sealed resource it names
    /// when one was altered, added or is missing.
    private static func reason(for status: OSStatus, _ error: CFError?) -> String {
        var text = message(for: status)
        if let info = error.map({ CFErrorCopyUserInfo($0) as NSDictionary }) {
            for (key, label) in [(kSecCFErrorResourceAltered, "altered"), (kSecCFErrorResourceMissing, "missing"), (kSecCFErrorResourceAdded, "added")] {
                if let named = info[key as String] {
                    text += " (\(label): \(named))"
                }
            }
        }
        return text
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
    }
}
