import Foundation

/// `/usr/bin/security`, for reading a secret another tool filed with it.
///
/// See `ClaudeCredentials.read` for why this goes through a subprocess instead
/// of `SecItemCopyMatching`: the item's access list names `security`, not us.
enum SecurityTool {
    struct Result {
        /// The tool's exit status, or -1 when it never ran or was timed out.
        let status: Int32
        let secret: Data?
    }

    /// Long enough for a cold start, short enough that a keychain waiting on
    /// an unlock dialogue nobody is there to answer does not hold a fetch open.
    static let timeout: TimeInterval = 10

    static func arguments(service: String, account: String?) -> [String] {
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty { arguments += ["-a", account] }
        // `-w` prints the secret alone, on standard output.
        return arguments + ["-w"]
    }

    /// Never call this on the main thread: it waits for a process.
    static func findGenericPassword(service: String, account: String?) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments(service: service, account: account)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, secret: nil)
        }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: a secret larger than the pipe buffer would
        // otherwise block the tool on a write nobody is draining.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let status = process.terminationReason == .exit ? process.terminationStatus : -1
            return Result(status: status, secret: nil)
        }
        return Result(status: 0, secret: trimmingNewline(data))
    }

    static func trimmingNewline(_ data: Data) -> Data {
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return trimmed
    }

    /// `security` prints a secret holding anything it deems unprintable as a
    /// run of hex digits. Nil when the data is not that.
    static func dataFromHex(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .ascii), !text.isEmpty, text.count.isMultiple(of: 2),
              text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// What an exit status means for the ring. `security` exits with the low
    /// byte of the OSStatus it met.
    static func error(forExitStatus status: Int32) -> UsageProviderError {
        switch status {
        case 44:
            // errSecItemNotFound: Claude Code has not signed in.
            return .needsAuth
        case 36, -1:
            // errSecInteractionNotAllowed (-25308, a Mac just woken or a
            // keychain still locked), or a read that timed out. The credential
            // is unaffected, so the last reading merely ages.
            return .credentialExpired
        default:
            return .accessDenied
        }
    }
}
