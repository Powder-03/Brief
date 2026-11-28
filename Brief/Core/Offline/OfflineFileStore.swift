//
//  OfflineFileStore.swift
//  Brief
//
//  Container-safe relative-path asset storage inside Application Support for offline images.
//

import Foundation

nonisolated struct OfflineFileStore: Sendable {
    let baseDirectoryURL: URL

    init(baseDirectoryURL: URL? = nil) {
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL.temporaryDirectory
            self.baseDirectoryURL = appSupport.appendingPathComponent(
                AppConfig.offlineAssetsFolderName,
                isDirectory: true
            )
        }
    }

    func resolveURL(relativePath: String) -> URL {
        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        return components.reduce(baseDirectoryURL) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: false)
        }
    }

    @concurrent
    func saveImageData(
        _ data: Data,
        storyID: Int,
        assetID: String,
        remoteURLString: String,
        mimeType: String?
    ) async throws -> OfflineAssetRecord {
        try Task.checkCancellation()

        guard !data.isEmpty, data.count <= AppConfig.maxImageBytes else {
            throw APIError.extractionError("Image exceeds maximum allowed size.")
        }

        guard let (fileExtension, resolvedMIME) = Self.detectImageFormat(data: data, reportedMIME: mimeType) else {
            throw APIError.extractionError("Unsupported or non-image asset response.")
        }

        let fileManager = FileManager.default
        try Self.ensureDirectoryExists(baseDirectoryURL, fileManager: fileManager)

        let storyDirectory = baseDirectoryURL.appendingPathComponent(String(storyID), isDirectory: true)
        try Self.ensureDirectoryExists(storyDirectory, fileManager: fileManager)

        let safeAssetID = Self.sanitizeFilenameComponent(assetID)
        let filename = "\(safeAssetID).\(fileExtension)"
        let destinationURL = storyDirectory.appendingPathComponent(filename, isDirectory: false)
        let replacingExisting = fileManager.fileExists(atPath: destinationURL.path)
        let replacedBytes = replacingExisting
            ? Int64((try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            : 0

        let (existingCount, existingBytes) = Self.folderUsage(at: storyDirectory, fileManager: fileManager)
        if !replacingExisting {
            guard existingCount < AppConfig.maxImagesPerArticle else {
                throw APIError.extractionError("Maximum image count reached for article.")
            }
        }
        guard (existingBytes - replacedBytes) + Int64(data.count) <= Int64(AppConfig.maxArticleAssetsBytes) else {
            throw APIError.extractionError("Article offline image quota exceeded.")
        }

        try data.write(to: destinationURL, options: .atomic)

        let relativePath = "\(storyID)/\(filename)"
        return OfflineAssetRecord(
            assetID: "\(storyID)::\(safeAssetID)",
            storyID: storyID,
            remoteURLString: remoteURLString,
            relativeLocalPath: relativePath,
            mimeType: resolvedMIME,
            byteSize: Int64(data.count),
            downloadedAt: .now
        )
    }

    @concurrent
    func deleteFolder(for storyID: Int) async throws {
        let storyDirectory = baseDirectoryURL.appendingPathComponent(String(storyID), isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storyDirectory.path) {
            try fileManager.removeItem(at: storyDirectory)
        }
    }

    @concurrent
    func totalDiskUsageBytes() async -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDirectoryURL.path),
              let enumerator = fileManager.enumerator(
                at: baseDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    @concurrent
    func clearAll() async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.removeItem(at: baseDirectoryURL)
        }
        try Self.ensureDirectoryExists(baseDirectoryURL, fileManager: fileManager)
    }

    // MARK: - Helpers

    private static func ensureDirectoryExists(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    private static func folderUsage(at directory: URL, fileManager: FileManager) -> (count: Int, bytes: Int64) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var count = 0
        var bytes: Int64 = 0
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                count += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (count, bytes)
    }

    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        let allowed = raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return allowed.isEmpty ? UUID().uuidString : allowed
    }

    private static func detectImageFormat(data: Data, reportedMIME: String?) -> (extension: String, mime: String)? {
        let bytes = Array(data.prefix(12))

        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ("jpg", "image/jpeg")
        }
        if bytes.count >= 8,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            return ("png", "image/png")
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return ("gif", "image/gif")
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return ("webp", "image/webp")
        }

        if let normalizedMIME = reportedMIME?
            .lowercased()
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            switch normalizedMIME {
            case "image/jpeg", "image/jpg":
                return ("jpg", "image/jpeg")
            case "image/png":
                return ("png", "image/png")
            case "image/gif":
                return ("gif", "image/gif")
            case "image/webp":
                return ("webp", "image/webp")
            case "image/heic":
                return ("heic", "image/heic")
            case "image/avif":
                return ("avif", "image/avif")
            default:
                break
            }
        }

        return nil
    }
}
