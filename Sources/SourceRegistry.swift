import Foundation

// Display names can change; stable IDs, note labels and runtime aliases are compatibility data.
struct SourceDescriptor: Equatable {
    let stableID: String
    let displayName: String
    let icon: String
    let runtimeSlot: String
    let aliases: [String]
    let nativePlatform: NativePlatform?
    let verifiedHost: String?
    let noteLabel: String?

    static let bb = SourceDescriptor(stableID: "bb", displayName: "BB", icon: "calendar", runtimeSlot: "bb", aliases: [], nativePlatform: nil, verifiedHost: nil, noteLabel: nil)
    static let mo = SourceDescriptor(stableID: "mo", displayName: "智海 MO", icon: "book.closed", runtimeSlot: "mo", aliases: [], nativePlatform: .mo, verifiedHost: "mo.zju.edu.cn", noteLabel: "MO")
    static let learningInZJU = SourceDescriptor(stableID: "learningInZJU", displayName: "学在浙大", icon: "graduationcap", runtimeSlot: "xzzd", aliases: ["xzzd"], nativePlatform: .learningInZJU, verifiedHost: "courses.zju.edu.cn", noteLabel: "学在浙大")
}

enum SourceRegistryError: Error { case invalidDescriptor, duplicateIdentity, adapterMismatch }
struct SourceRegistry {
    let descriptors: [SourceDescriptor]
    var nativeDescriptors: [SourceDescriptor] { descriptors.filter { $0.nativePlatform != nil } }
    static let production = try! SourceRegistry(descriptors: [.bb, .mo, .learningInZJU])

    init(descriptors: [SourceDescriptor]) throws {
        var names = Set<String>(), slots = Set<String>()
        for descriptor in descriptors {
            guard NativePlatform(rawValue: descriptor.stableID) != nil,
                  NativePlatform(rawValue: descriptor.runtimeSlot) != nil,
                  !descriptor.displayName.isEmpty, !descriptor.icon.isEmpty,
                  descriptor.aliases.allSatisfy({ NativePlatform(rawValue: $0) != nil }),
                  Set(descriptor.aliases).count == descriptor.aliases.count,
                  !descriptor.aliases.contains(descriptor.stableID) else { throw SourceRegistryError.invalidDescriptor }
            guard slots.insert(descriptor.runtimeSlot).inserted else { throw SourceRegistryError.duplicateIdentity }
            // The slot is also a lookup alias, including legacy xzzd scheduling/claim IDs.
            for name in Set([descriptor.stableID, descriptor.runtimeSlot] + descriptor.aliases) {
                guard names.insert(name).inserted else { throw SourceRegistryError.duplicateIdentity }
            }
            if let platform = descriptor.nativePlatform {
                guard platform.rawValue == descriptor.stableID, let host = descriptor.verifiedHost,
                      let url = URL(string: "https://\(host)/"), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.host == host, parts.percentEncodedHost == host, parts.port == nil,
                      parts.user == nil, parts.password == nil, parts.path == "/", parts.query == nil, parts.fragment == nil,
                      let label = descriptor.noteLabel, !label.isEmpty,
                      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !label.contains("[") else { throw SourceRegistryError.invalidDescriptor }
            } else {
                guard descriptor.verifiedHost == nil, descriptor.noteLabel == nil else { throw SourceRegistryError.invalidDescriptor }
            }
        }
        self.descriptors = descriptors
    }
    func descriptor(for idOrAlias: String) -> SourceDescriptor? {
        descriptors.first { $0.stableID == idOrAlias || $0.runtimeSlot == idOrAlias || $0.aliases.contains(idOrAlias) }
    }
    func descriptor(for platform: NativePlatform) -> SourceDescriptor? {
        nativeDescriptors.first { $0.nativePlatform == platform }
    }
}

extension NativePlatform {
    var displayName: String { SourceRegistry.production.descriptor(for: self)?.displayName ?? rawValue }
}
