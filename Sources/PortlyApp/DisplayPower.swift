import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

/// The lid, the built-in screen and system sleep, as `KeepAwake` needs them.
///
/// Blocking lid sleep (`pmset disablesleep 1`) keeps the Mac and its network up
/// with the lid closed, but macOS then also leaves the built-in screen lit
/// behind the closed lid, which heats the machine for nothing. These helpers
/// let the keep-awake loop notice the closed lid, put the screen out, and send
/// the Mac to sleep for real once the agents are done.
enum DisplayPower {
    /// True when the lid of a MacBook is closed. Desktops have no lid and
    /// always read open.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Another screen is connected: with the lid closed the Mac is in
    /// clamshell mode and in use, so its screens and sleep are left alone.
    static func hasExternalDisplay() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// The built-in screen is on and drawing.
    static func isBuiltInDisplayLit() -> Bool {
        guard let display = builtInDisplay() else { return false }
        return CGDisplayIsActive(display) != 0 && CGDisplayIsAsleep(display) == 0
    }

    /// Put every screen to sleep, as the Hot Corner does. The Mac stays awake.
    static func sleepDisplays() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Ask for system sleep now. Allowed for the console user.
    static func sleepSystem() {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else {
            run("/usr/bin/pmset", ["sleepnow"])
            return
        }
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess { run("/usr/bin/pmset", ["sleepnow"]) }
    }

    // MARK: - Brightness (fallback)

    /// The built-in screen's brightness, 0…1, when macOS lets us read it.
    static func builtInBrightness() -> Float? {
        guard let display = builtInDisplay(), let get = DisplayServices.shared.getBrightness else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setBuiltInBrightness(_ value: Float) -> Bool {
        guard let display = builtInDisplay(), let set = DisplayServices.shared.setBrightness else { return false }
        return set(display, min(max(value, 0), 1)) == 0
    }

    // MARK: - Private

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }
}

/// The private framework behind the brightness keys. Loaded at runtime so a
/// macOS without it simply has no brightness fallback, never a crash.
private final class DisplayServices {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static let shared = DisplayServices()

    let getBrightness: GetBrightness?
    let setBrightness: SetBrightness?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getBrightness = nil
            setBrightness = nil
            return
        }
        getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
    }
}
