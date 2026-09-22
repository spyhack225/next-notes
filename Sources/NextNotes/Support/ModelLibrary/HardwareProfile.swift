import Foundation
import IOKit

/// What this Mac actually is, measured rather than assumed.
///
/// Everything here comes from `sysctl`, `ProcessInfo` and the IO registry, so it is correct
/// on a machine nobody anticipated — including an Intel Mac and a chip that does not exist
/// yet. The one judgement call is memory bandwidth, which Apple does not publish through any
/// API: `AppleSiliconFamily` holds a table of the figures Apple has stated publicly, and an
/// unknown chip gets a deliberately low default so an estimate built on it under-promises.
struct HardwareProfile: Sendable, Equatable {
    /// "Apple M3 Pro", or the Intel brand string.
    let chipName: String
    /// "Mac15,3".
    let modelIdentifier: String
    let performanceCores: Int
    let efficiencyCores: Int
    /// nil when the IO registry does not publish it (Intel, virtual machines).
    let gpuCores: Int?
    /// "MacBook Air (13-inch, M3, 2024)", from the device tree. nil in a virtual machine.
    let deviceTreeName: String?
    /// Unified memory, in bytes.
    let memoryBytes: Int64
    /// Free space on the volume the models are stored on, in bytes.
    let freeDiskBytes: Int64
    let macOSVersion: OperatingSystemVersion
    let isAppleSilicon: Bool
    let family: AppleSiliconFamily
    let thermalState: ProcessInfo.ThermalState
    let isLowPowerModeEnabled: Bool

    var totalCores: Int { performanceCores + efficiencyCores }

    /// Written out by hand because `OperatingSystemVersion` is not `Equatable`, and a
    /// synthesized conformance would fail to compile rather than skip it.
    static func == (lhs: HardwareProfile, rhs: HardwareProfile) -> Bool {
        lhs.chipName == rhs.chipName
            && lhs.modelIdentifier == rhs.modelIdentifier
            && lhs.performanceCores == rhs.performanceCores
            && lhs.efficiencyCores == rhs.efficiencyCores
            && lhs.gpuCores == rhs.gpuCores
            && lhs.deviceTreeName == rhs.deviceTreeName
            && lhs.memoryBytes == rhs.memoryBytes
            && lhs.freeDiskBytes == rhs.freeDiskBytes
            && lhs.macOSVersion.majorVersion == rhs.macOSVersion.majorVersion
            && lhs.macOSVersion.minorVersion == rhs.macOSVersion.minorVersion
            && lhs.macOSVersion.patchVersion == rhs.macOSVersion.patchVersion
            && lhs.isAppleSilicon == rhs.isAppleSilicon
            && lhs.family == rhs.family
            && lhs.thermalState == rhs.thermalState
            && lhs.isLowPowerModeEnabled == rhs.isLowPowerModeEnabled
    }

    /// Peak memory bandwidth in gigabytes per second. Token generation on a quantized model
    /// is bandwidth-bound almost everywhere, so this is the single number that decides
    /// whether a model will feel fast.
    var memoryBandwidthGBPerSecond: Double { family.memoryBandwidthGBPerSecond }

    /// Unified memory in the round form people recognise: "16 GB", not "17.18 GB".
    var memoryGigabytesLabel: String {
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        return "\(Int(gigabytes.rounded())) GB"
    }

    var freeDiskLabel: String {
        ByteCountFormatter.string(fromByteCount: freeDiskBytes, countStyle: .file)
    }

    var macOSLabel: String {
        let version = macOSVersion
        return version.patchVersion == 0
            ? "macOS \(version.majorVersion).\(version.minorVersion)"
            : "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The one-line summary at the top of the Models tab: "MacBook Air (13-inch, M3, 2024) ·
    /// 16 GB memory · 8.8 GB free".
    ///
    /// The chip is named only when the machine's own name does not already contain it —
    /// Apple puts it in some marketing names and not others, and "MacBook Air (13-inch, M3,
    /// 2024) · Apple M3" reads as a stutter.
    var plainSummary: String {
        var parts = [marketingName]
        let shortChip = chipName.replacingOccurrences(of: "Apple ", with: "")
        if !marketingName.localizedCaseInsensitiveContains(shortChip) { parts.append(chipName) }
        parts.append("\(memoryGigabytesLabel) memory")
        parts.append("\(freeDiskLabel) free")
        return parts.joined(separator: " · ")
    }

    /// What Apple calls this machine, so the card names it the way its owner does.
    ///
    /// Apple silicon reports `hw.model` as "Mac15,3", which names nothing a person
    /// recognises — the marketing name lives in the device tree instead, as
    /// "MacBook Air (13-inch, M3, 2024)". `deviceTreeName` is that string; the prefix table
    /// below is the fallback for a machine that does not publish it.
    var marketingName: String {
        if let name = deviceTreeName, !name.isEmpty { return name }
        let identifier = modelIdentifier.lowercased()
        if identifier.hasPrefix("macbookpro") { return "MacBook Pro" }
        if identifier.hasPrefix("macbookair") { return "MacBook Air" }
        if identifier.hasPrefix("macbook") { return "MacBook" }
        if identifier.hasPrefix("macmini") { return "Mac mini" }
        if identifier.hasPrefix("macstudio") { return "Mac Studio" }
        if identifier.hasPrefix("macpro") { return "Mac Pro" }
        if identifier.hasPrefix("imac") { return "iMac" }
        // Apple silicon laptops report "Mac14,7"-style identifiers on some builds; the
        // battery is the only way to tell a portable from a desktop without a table.
        if identifier.hasPrefix("mac") { return "Mac" }
        return "Mac"
    }

    /// Plain sentence for the "Your Mac" card's second line.
    var coreSummary: String {
        var parts: [String] = []
        if totalCores > 0 {
            if efficiencyCores > 0 {
                parts.append("\(totalCores)-core processor")
            } else {
                parts.append("\(totalCores) processor cores")
            }
        }
        if let gpuCores { parts.append("\(gpuCores)-core graphics") }
        parts.append(macOSLabel)
        return parts.joined(separator: " · ")
    }

    // MARK: - Reading the machine

    /// Reads the live machine. Cheap enough to call from a view's `onAppear`; free disk and
    /// thermal state are the only parts that move, so the Models tab re-reads on appear.
    static func current() -> HardwareProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Unknown processor"
        let model = sysctlString("hw.model") ?? "Mac"
        let memory = sysctlInt64("hw.memsize") ?? 0

        // perflevel0 is the performance cluster and perflevel1 the efficiency one on Apple
        // silicon. Intel has neither key, and reports everything through hw.physicalcpu.
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        let physical = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount

        let silicon = isRunningOnAppleSilicon()
        let info = ProcessInfo.processInfo

        return HardwareProfile(
            chipName: brand,
            modelIdentifier: model,
            performanceCores: performance ?? (efficiency == nil ? physical : 0),
            efficiencyCores: efficiency ?? 0,
            gpuCores: gpuCoreCount(),
            deviceTreeName: deviceTreeProductName(),
            memoryBytes: memory,
            freeDiskBytes: ModelDownloader.availableDiskBytes(),
            macOSVersion: info.operatingSystemVersion,
            isAppleSilicon: silicon,
            family: AppleSiliconFamily.parse(brandString: brand, isAppleSilicon: silicon),
            thermalState: info.thermalState,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled
        )
    }

    /// Rosetta reports an Intel brand string in a translated process, so the check is on the
    /// native architecture rather than on the name.
    private static func isRunningOnAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        // A translated build still runs on Apple silicon; sysctl.proc_translated says so.
        return sysctlInt("sysctl.proc_translated") == 1
        #endif
    }

    /// The GPU core count, from the first Apple GPU in the IO registry.
    ///
    /// There is no Metal API for this — `MTLDevice` exposes a name and nothing about the
    /// shader core count — so the registry property is the only source. It is absent on
    /// Intel and inside virtual machines, which is why the whole thing is optional.
    static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
            if let number = property?.takeRetainedValue() as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }

    /// The marketing name from `IODeviceTree:/product`.
    ///
    /// Stored as a null-terminated C string inside a data blob, which is why it is trimmed
    /// rather than decoded straight into a `String`.
    static func deviceTreeProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let property = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0)
        guard let data = property?.takeRetainedValue() as? Data else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return text.isEmpty ? nil : text
    }

    // MARK: - sysctl

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return Int(value) }
        return sysctlInt64(name).map(Int.init)
    }
}

/// Which Apple-silicon chip this is, and how fast its memory is.
///
/// Memory bandwidth is the number that decides token rate on a quantized model: every
/// generated token reads the whole active weight set out of memory once, so tokens per
/// second is close to bandwidth ÷ weight bytes. Apple states these figures in its own
/// press material; there is no API for them.
///
/// **An unknown chip gets `unknownAppleSilicon`, at 100 GB/s.** That is roughly an M2/M3
/// base chip, which is the slowest current Apple silicon — so a future M6 Max would be
/// under-promised rather than over-promised, and the verdict the user sees stays honest.
enum AppleSiliconFamily: String, Sendable, Equatable, CaseIterable {
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max, m4Ultra
    case m5, m5Pro, m5Max, m5Ultra
    case unknownAppleSilicon
    case intel

    /// Peak unified-memory bandwidth in GB/s, as Apple states it.
    ///
    /// The Max entries take the lower of the two configurations Apple ships where they
    /// differ (M3 Max is 300 or 400 GB/s depending on the CPU core count; M4 Max is 410 or
    /// 546), for the same reason the unknown default is low.
    var memoryBandwidthGBPerSecond: Double {
        switch self {
        case .m1: 68
        case .m1Pro: 200
        case .m1Max: 400
        case .m1Ultra: 800
        case .m2: 100
        case .m2Pro: 200
        case .m2Max: 400
        case .m2Ultra: 800
        case .m3: 100
        case .m3Pro: 150
        case .m3Max: 300
        case .m3Ultra: 800
        case .m4: 120
        case .m4Pro: 273
        case .m4Max: 410
        case .m4Ultra: 820
        case .m5: 153
        case .m5Pro: 300
        case .m5Max: 500
        case .m5Ultra: 1_000
        case .unknownAppleSilicon: 100
        // Intel Macs read main memory over DDR4 with no unified GPU path worth counting.
        case .intel: 40
        }
    }

    /// The generation number, for the "newer than the table" case.
    var generation: Int? {
        switch self {
        case .m1, .m1Pro, .m1Max, .m1Ultra: 1
        case .m2, .m2Pro, .m2Max, .m2Ultra: 2
        case .m3, .m3Pro, .m3Max, .m3Ultra: 3
        case .m4, .m4Pro, .m4Max, .m4Ultra: 4
        case .m5, .m5Pro, .m5Max, .m5Ultra: 5
        case .unknownAppleSilicon, .intel: nil
        }
    }

    /// Parses "Apple M3 Pro" and friends. Case-insensitive, and tolerant of the extra words
    /// Apple has used over the years ("Apple M1 Max", "Apple M4 Pro").
    static func parse(brandString: String, isAppleSilicon: Bool) -> AppleSiliconFamily {
        guard isAppleSilicon else { return .intel }
        let text = brandString.lowercased()

        let variant: String
        if text.contains("ultra") { variant = "Ultra" }
        else if text.contains("max") { variant = "Max" }
        else if text.contains("pro") { variant = "Pro" }
        else { variant = "" }

        for generation in 1...5 where text.contains("m\(generation)") {
            // "m1" must not match inside "m12"; the brand strings are "Apple M3 Pro", so a
            // digit immediately after is the only ambiguity worth guarding.
            if let range = text.range(of: "m\(generation)") {
                let after = range.upperBound
                if after < text.endIndex, text[after].isNumber { continue }
            }
            let key = "m\(generation)\(variant)"
            if let family = AppleSiliconFamily(rawValue: key) { return family }
        }
        return .unknownAppleSilicon
    }
}
