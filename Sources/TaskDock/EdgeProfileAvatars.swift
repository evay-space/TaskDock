import AppKit
import SwiftUI

struct EdgeProfileAvatar: Equatable {
    let name: String
    let imageData: Data
}

enum EdgeProfileAvatarCatalog {
    static let bundleIdentifier = "com.microsoft.edgemac"

    static func profileKey(in rawTitle: String) -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = " - Microsoft Edge"
        guard let separator = title.range(of: marker, options: [.backwards, .caseInsensitive]),
              !title[..<separator.lowerBound].isEmpty else { return nil }
        let suffix = title[separator.upperBound...]
        guard suffix.hasPrefix(" - ") else { return nil }
        let name = suffix.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return key(for: name)
    }

    static func load(from directory: URL, builtInAvatars: [Int: Data]) -> [String: EdgeProfileAvatar] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Local State")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let entries = profile["info_cache"] as? [String: [String: Any]] else { return [:] }
        let visibleProfiles = entries.filter {
            $0.value["is_omitted"] as? Bool != true && $0.value["is_ephemeral"] as? Bool != true
        }
        guard visibleProfiles.count > 1 else { return [:] }
        var avatars: [String: EdgeProfileAvatar] = [:]
        var seen = Set<String>()
        var ambiguous = Set<String>()
        for (folder, entry) in visibleProfiles {
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            let profileKey = key(for: name)
            guard seen.insert(profileKey).inserted else {
                ambiguous.insert(profileKey)
                continue
            }
            let iconPrefix = "chrome://theme/IDR_PROFILE_AVATAR_"
            let icon = (entry["avatar_icon"] as? String) ?? ""
            let index = icon.hasPrefix(iconPrefix) ? Int(icon.dropFirst(iconPrefix.count)) : nil
            let photo = readPhoto(in: directory, folder: folder, entry: entry)
            guard let image = photo ?? index.flatMap({ builtInAvatars[$0] }) else { continue }
            avatars[profileKey] = EdgeProfileAvatar(name: name, imageData: image)
        }
        for profileKey in ambiguous { avatars.removeValue(forKey: profileKey) }
        return avatars
    }

    private static func key(for name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func readPhoto(in directory: URL, folder: String, entry: [String: Any]) -> Data? {
        guard entry["use_gaia_picture"] as? Bool == true,
              let filename = entry["gaia_picture_file_name"] as? String,
              [folder, filename].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let photo = root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
        guard photo.pathComponents.dropLast(2).elementsEqual(root.pathComponents),
              let metadata = try? photo.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true,
              let size = metadata.fileSize, (1...2_000_000).contains(size) else { return nil }
        return try? Data(contentsOf: photo)
    }
}

@MainActor
final class EdgeProfileAvatarStore: ObservableObject {
    @Published private(set) var avatars: [String: EdgeProfileAvatar] = [:]

    func refreshWhileVisible() async {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true)
        var currentFramework: URL?
        var builtInAvatars: [Int: Data] = [:]
        while !Task.isCancelled {
            let framework = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EdgeProfileAvatarCatalog.bundleIdentifier)
                .map(EdgeBuiltInAvatars.frameworkURL(in:))
            if framework != currentFramework {
                currentFramework = framework
                builtInAvatars = await Task.detached(priority: .utility) {
                    framework.map(EdgeBuiltInAvatars.load(from:)) ?? [:]
                }.value
            }
            let resources = builtInAvatars
            let loaded = await Task.detached(priority: .utility) {
                EdgeProfileAvatarCatalog.load(from: directory, builtInAvatars: resources)
            }.value
            guard !Task.isCancelled else { return }
            if loaded != avatars { avatars = loaded }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    func avatar(for window: WindowModel) -> EdgeProfileAvatar? {
        guard window.bundleIdentifier == EdgeProfileAvatarCatalog.bundleIdentifier,
              let profile = EdgeProfileAvatarCatalog.profileKey(in: window.rawTitle) else { return nil }
        return avatars[profile]
    }
}

struct EdgeProfileAvatarBadge: View, Equatable {
    let avatar: EdgeProfileAvatar
    let size: CGFloat

    var body: some View {
        if let image = NSImage(data: avatar.imageData), image.isValid {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: max(0.75, size * 0.085)))
                .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func edgeProfileAvatar(_ avatar: EdgeProfileAvatar?, iconSize: CGFloat) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let avatar {
                EdgeProfileAvatarBadge(avatar: avatar, size: iconSize * 0.42)
                    .equatable()
            }
        }
    }
}
