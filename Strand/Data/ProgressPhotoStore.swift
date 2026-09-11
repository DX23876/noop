import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ProgressPhotoStore.swift — progress photos, on disk and nowhere else.
//
// The body spec deliberately excluded these ("moderate value, large privacy surface"). They are here
// because they were asked for, and the privacy objection is answerable rather than fatal — but only if
// the answer is built in rather than promised:
//
//   • THEY NEVER LEAVE THE DEVICE. Files live in Application Support, not the photo library, not
//     iCloud Photos, not the `.noopbak` backup. A `.noopbak` is a settings + database export that
//     users mail to themselves and paste into issues; a body photo has no business riding along, and
//     the whitelist is a fixed contract that cannot accidentally acquire one.
//   • THEY ARE EXCLUDED FROM iCLOUD DEVICE BACKUP, explicitly, per file. Application Support is backed
//     up by default, so silence here would mean the opposite of what the file header claims.
//   • THEY ARE NEVER WRITTEN TO THE PHOTO LIBRARY. Nothing here asks for that permission.
//
// The frame that matters more than any of this: a progress photo is only worth anything against
// ANOTHER progress photo, and only if the two were taken the same way. That is why the capture surface
// draws a fixed guide and this store records which pose a shot belongs to.

/// Which view a shot is. Three poses, because the changes people are looking for do not all show from
/// the front — a waist reads best from the side and a back reads not at all from anywhere else.
enum PhotoPose: String, CaseIterable, Codable, Sendable, Identifiable {
    case front, side, back

    var id: String { rawValue }

    var label: String {
        switch self {
        case .front: return String(localized: "Front")
        case .side:  return String(localized: "Side")
        // Its own key: plain "Back" is the navigation button, translated as "Zurück", "Retour", "返回".
        case .back:  return String(localized: "pose.back", defaultValue: "Back")
        }
    }

    /// What to do so this shot is comparable with the last one.
    var guidance: String {
        switch self {
        case .front:
            return String(localized: "Face the camera square on, arms relaxed at your sides, feet at shoulder width.")
        case .side:
            return String(localized: "Turn a quarter turn, arms hanging naturally. Pick one side and always use the same one.")
        case .back:
            return String(localized: "Face away, arms relaxed. Same distance and same stance as the front shot.")
        }
    }
}

/// One stored photo.
struct ProgressPhoto: Identifiable, Codable, Sendable, Equatable {
    /// `yyyy-MM-dd-pose`, so one pose per day replaces rather than accumulates.
    let id: String
    let day: String
    let pose: PhotoPose
    let takenAt: Int
}

/// Progress photos on local disk, indexed in UserDefaults.
enum ProgressPhotoStore {

    private static let indexKey = "body.photos.index"

    /// Where the files live. Under Application Support rather than Documents, so they never appear in
    /// the Files app alongside a user's own documents.
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("BodyPhotos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func url(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id).jpg")
    }

    /// Every stored photo, newest first.
    static var all: [ProgressPhoto] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([ProgressPhoto].self, from: data) else { return [] }
        return list.sorted { $0.takenAt > $1.takenAt }
    }

    /// Photos for one pose, oldest first — the order a comparison reads in.
    static func series(_ pose: PhotoPose) -> [ProgressPhoto] {
        all.filter { $0.pose == pose }.sorted { $0.takenAt < $1.takenAt }
    }

    private static func write(_ list: [ProgressPhoto]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
    }

    #if canImport(UIKit)
    /// Stores one shot, replacing whatever that pose held for that day.
    ///
    /// Re-encoded as JPEG rather than kept as whatever the camera produced: it strips the original's
    /// metadata, including the location an unmodified capture would carry. A body photo tagged with a
    /// home address is a materially worse thing to hold than a body photo.
    @discardableResult
    static func save(_ image: UIImage, pose: PhotoPose, takenAt: Date = Date()) -> ProgressPhoto? {
        let day = Repository.localDayKey(takenAt)
        let id = "\(day)-\(pose.rawValue)"
        guard let url = url(for: id), let data = image.jpegData(compressionQuality: 0.82) else {
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(resource)
        } catch {
            return nil
        }
        let photo = ProgressPhoto(id: id, day: day, pose: pose,
                                  takenAt: Int(takenAt.timeIntervalSince1970))
        write(all.filter { $0.id != id } + [photo])
        return photo
    }

    static func image(for photo: ProgressPhoto) -> UIImage? {
        guard let url = url(for: photo.id), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    #endif

    /// Removes one photo and its file. The caller confirms first — this does not ask.
    static func delete(_ photo: ProgressPhoto) {
        if let url = url(for: photo.id) { try? FileManager.default.removeItem(at: url) }
        write(all.filter { $0.id != photo.id })
    }
}
