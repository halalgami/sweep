import Foundation

/// Parses `diskutil apfs list -plist`. Keeps the boot container's volumes plus simulator runtime volumes.
public enum APFSParser {
    public static func parse(plistData: Data) -> [APFSVolumeInfo] {
        guard let root = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return [] }
        var result: [APFSVolumeInfo] = []
        for c in containers {
            let ref = c["ContainerReference"] as? String ?? "?"
            let vols = c["Volumes"] as? [[String: Any]] ?? []
            let roles = vols.flatMap { $0["Roles"] as? [String] ?? [] }
            let isBoot = roles.contains("System") || roles.contains("Data")
            for v in vols {
                let name = v["Name"] as? String ?? "?"
                let used = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                let role = (v["Roles"] as? [String])?.first
                if name.hasSuffix(" Simulator") || name.contains("Simulator") && role == nil {
                    result.append(APFSVolumeInfo(name: name, role: "Simulator", usedBytes: used, container: ref, isSimulator: true))
                } else if isBoot {
                    result.append(APFSVolumeInfo(name: name, role: role ?? "Other", usedBytes: used, container: ref, isSimulator: false))
                }
            }
        }
        return result
    }
}
