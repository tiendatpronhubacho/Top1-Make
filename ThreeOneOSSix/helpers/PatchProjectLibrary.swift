import Foundation

struct PatchLibraryItem: Identifiable {
    let summary: PatchPackageSummary
    var project: PatchProject?
    var contentKey: Data?
    var packageURL: URL
    let isAuthorCopy: Bool
    let origin: PatchPackageOrigin?

    var id: UUID { summary.packageID }
    var isLocked: Bool { project == nil }
    var canInspectContents: Bool {
        guard let project else { return false }
        return PatchProjectAccessPolicy.canInspectContents(
            project: project,
            isAuthorCopy: isAuthorCopy
        )
    }
    var workspaceURL: URL? {
        guard canInspectContents else { return nil }
        return PatchWorkspaceService.workspaceURL(projectID: id)
    }
}

struct PatchPasswordRequest: Identifiable {
    let summary: PatchPackageSummary
    let origin: PatchPackageOrigin?
    var id: UUID { summary.packageID }

    init(summary: PatchPackageSummary, origin: PatchPackageOrigin? = nil) {
        self.summary = summary
        self.origin = origin
    }
}

enum PatchProjectLibrary {
    private static let authorCopiesDirectoryName = ".AuthorCopies"
    private static let originsDirectoryName = ".Origins"
    private static let bundledManifestFilename = ".BundledPackages.plist"
    private static let userImportsDirectoryName = ".UserImports"

    static func packageRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("PatchProjects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// Chuẩn bị cấu trúc thư mục patch khi app khởi động.
    /// Gọi trước khi UI đọc `load()` để tránh race ở lần chạy đầu.
    static func bootstrap(fileManager: FileManager = .default) {
        _ = try? packageRootURL(fileManager: fileManager)
        _ = try? backupRootURL(fileManager: fileManager)
        _ = try? authorCopiesRootURL(fileManager: fileManager)
        _ = try? originsRootURL(fileManager: fileManager)
        _ = try? userImportsRootURL(fileManager: fileManager)
    }

    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(fileManager: FileManager = .default) -> [PatchLibraryItem] {
        guard let root = try? packageRootURL(fileManager: fileManager) else { return [] }
        seedBundledPackages(into: root, fileManager: fileManager)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var byID: [UUID: PatchLibraryItem] = [:]
        for url in urls where ["3106", "3105"].contains(url.pathExtension.lowercased()) {
            do {
                let data = try readPackage(at: url)
                let summary = try PatchPackageCodec.inspect(data)
                let decoded: DecodedPatchPackage?
                if let contentKey = try PatchKeyStore.load(for: summary) {
                    decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                } else if summary.isPasswordProtected {
                    decoded = nil
                } else {
                    decoded = try PatchPackageCodec.decode(data, password: nil)
                }
                let isAuthorCopy = isAuthorCopy(
                    packageID: summary.packageID,
                    fileManager: fileManager
                )
                let item = PatchLibraryItem(
                    summary: summary,
                    project: decoded?.project,
                    contentKey: decoded?.contentKey,
                    packageURL: url,
                    isAuthorCopy: isAuthorCopy,
                    origin: loadOrigin(
                        packageID: summary.packageID,
                        fileManager: fileManager
                    )
                )
                if summary.schemaVersion >= 2, let project = decoded?.project {
                    if PatchProjectAccessPolicy.shouldMaterializeWorkspace(
                        project: project,
                        isAuthorCopy: isAuthorCopy
                    ) {
                        do {
                            _ = try PatchWorkspaceService.ensureWorkspace(for: project)
                        } catch {
                            log("patch: workspace unavailable for \(project.id.uuidString)")
                        }
                    } else {
                        try? PatchWorkspaceService.deleteWorkspace(
                            projectID: project.id,
                            fileManager: fileManager
                        )
                    }
                }
                byID[summary.packageID] = item
            } catch {
                log("patch: skipped invalid local package \(url.lastPathComponent)")
            }
        }
        return byID.values.sorted {
            ($0.project?.updatedAt ?? .distantPast) > ($1.project?.updatedAt ?? .distantPast)
        }
    }

    /// Synchronizes packages shipped in PatchCatalog.dat into the local library.
    /// Bundled packages are updated by catalog filename, because a replacement
    /// package may intentionally have a new packageID. User imports and active
    /// patches are left untouched.
    private static func seedBundledPackages(
        into root: URL,
        fileManager: FileManager
    ) {
        guard let catalogURL = Bundle.main.url(forResource: "PatchCatalog", withExtension: "dat"),
              let catalogData = try? Data(contentsOf: catalogURL),
              let catalog = (try? PropertyListSerialization.propertyList(
                  from: catalogData,
                  options: [],
                  format: nil
              )) as? [String: Data] else { return }

        var manifest = loadBundledManifest(from: root)
        let localURLs = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        var localByID: [UUID: URL] = [:]
        for url in localURLs where ["3105", "3106"].contains(url.pathExtension.lowercased()) {
            guard let data = try? readPackage(at: url),
                  let summary = try? PatchPackageCodec.inspect(data) else { continue }
            localByID[summary.packageID] = url
        }

        var manifestChanged = false
        for filename in catalog.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let sourceURL = URL(fileURLWithPath: filename)
            let ext = sourceURL.pathExtension.lowercased()
            guard ["3105", "3106"].contains(ext),
                  let bundledData = catalog[filename],
                  let bundledSummary = try? PatchPackageCodec.inspect(bundledData) else { continue }

            let sourceName = sourceURL.deletingPathExtension().lastPathComponent
            let baseName = sanitizedFilename(sourceName)
            let canonicalURL = root.appendingPathComponent(baseName).appendingPathExtension(ext)

            // Prefer the persisted mapping, then the exact package ID. For
            // installations predating the manifest, the canonical filename is
            // the legacy seed location used by the original implementation.
            var existingURL: URL?
            if let localFilename = manifest[filename] {
                let safeLocalFilename = URL(fileURLWithPath: localFilename).lastPathComponent
                let mapped = root.appendingPathComponent(safeLocalFilename)
                if safeLocalFilename == localFilename,
                   fileManager.fileExists(atPath: mapped.path) {
                    existingURL = mapped
                }
            }
            if existingURL == nil, let sameIDURL = localByID[bundledSummary.packageID] {
                existingURL = sameIDURL
            }
            if existingURL == nil, fileManager.fileExists(atPath: canonicalURL.path) {
                existingURL = canonicalURL
            }

            // Older app versions used a "-2", "-3" suffix when a user file
            // already occupied the canonical bundled filename. If that
            // canonical file is marked as user-owned, look for the legacy
            // suffixed bundled copy before creating another duplicate.
            if let selectedURL = existingURL,
               selectedURL.standardizedFileURL == canonicalURL.standardizedFileURL,
               let selectedData = try? readPackage(at: selectedURL),
               let selectedSummary = try? PatchPackageCodec.inspect(selectedData) {
                let selectedIsProtected = isAuthorCopy(
                    packageID: selectedSummary.packageID,
                    fileManager: fileManager
                ) || loadOrigin(
                    packageID: selectedSummary.packageID,
                    fileManager: fileManager
                ) != nil || isUserImport(
                    packageID: selectedSummary.packageID,
                    fileManager: fileManager
                )
                if selectedIsProtected {
                    let suffixedCandidates = localURLs.filter { candidate in
                        guard candidate.pathExtension.lowercased() == ext else { return false }
                        let stem = candidate.deletingPathExtension().lastPathComponent
                        guard stem.hasPrefix(baseName + "-") else { return false }
                        return Int(stem.dropFirst(baseName.count + 1)) != nil
                    }.sorted { lhs, rhs in
                        let left = Int(lhs.deletingPathExtension().lastPathComponent.dropFirst(baseName.count + 1)) ?? Int.max
                        let right = Int(rhs.deletingPathExtension().lastPathComponent.dropFirst(baseName.count + 1)) ?? Int.max
                        return left < right
                    }
                    for candidate in suffixedCandidates {
                        guard let candidateData = try? readPackage(at: candidate),
                              let candidateSummary = try? PatchPackageCodec.inspect(candidateData) else { continue }
                        let candidateIsProtected = isAuthorCopy(
                            packageID: candidateSummary.packageID,
                            fileManager: fileManager
                        ) || loadOrigin(
                            packageID: candidateSummary.packageID,
                            fileManager: fileManager
                        ) != nil || isUserImport(
                            packageID: candidateSummary.packageID,
                            fileManager: fileManager
                        )
                        if !candidateIsProtected {
                            existingURL = candidate
                            break
                        }
                    }
                }
            }

            if let existingURL,
               let existingData = try? readPackage(at: existingURL),
               let existingSummary = try? PatchPackageCodec.inspect(existingData),
               existingSummary.packageID == bundledSummary.packageID {
                // Never replace an author copy or a package imported from a
                // repository. The marker is checked against the old ID because
                // a bundled replacement can carry a different ID.
                let protectedCopy = isAuthorCopy(
                    packageID: existingSummary.packageID,
                    fileManager: fileManager
                ) || loadOrigin(
                    packageID: existingSummary.packageID,
                    fileManager: fileManager
                ) != nil || isUserImport(
                    packageID: existingSummary.packageID,
                    fileManager: fileManager
                )

                if protectedCopy {
                    // A same-ID package may be a user import; do not overwrite it.
                    // Create a separate bundled copy below unless it is already
                    // the exact catalog payload.
                    if existingData == bundledData {
                        manifest[filename] = existingURL.lastPathComponent
                        manifestChanged = true
                        continue
                    }
                } else {
                    let backupRoot = try? backupRootURL(fileManager: fileManager)
                    let isActive = backupRoot.map {
                        PatchTransaction.latestReceipt(
                            projectID: existingSummary.packageID,
                            backupRoot: $0,
                            fileManager: fileManager
                        ) != nil
                    } ?? false

                    if isActive {
                        // Keep the old bytes while the patch is applied. The
                        // next library load retries this catalog update.
                        manifest[filename] = existingURL.lastPathComponent
                        manifestChanged = true
                        continue
                    }

                    if existingData != bundledData {
                        do {
                            try bundledData.write(
                                to: existingURL,
                                options: [.atomic, .completeFileProtection]
                            )
                            if existingSummary.packageID != bundledSummary.packageID {
                                try? PatchKeyStore.delete(for: existingSummary)
                                try? PatchWorkspaceService.deleteWorkspace(
                                    projectID: existingSummary.packageID,
                                    fileManager: fileManager
                                )
                                localByID.removeValue(forKey: existingSummary.packageID)
                            } else {
                                try? PatchKeyStore.delete(for: existingSummary)
                                try? PatchWorkspaceService.deleteWorkspace(
                                    projectID: bundledSummary.packageID,
                                    fileManager: fileManager
                                )
                            }
                            log("patch: updated bundled package \(filename)")
                        } catch {
                            log("patch: bundled package update failed for \(filename)")
                            continue
                        }
                    }
                    localByID[bundledSummary.packageID] = existingURL
                    manifest[filename] = existingURL.lastPathComponent
                    manifestChanged = true
                    continue
                }
            }

            // No safe legacy/bundled destination was found. Add a new bundled
            // copy without overwriting any user-owned file.
            var destination = canonicalURL
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = root.appendingPathComponent("\(baseName)-\(suffix)")
                    .appendingPathExtension(ext)
                suffix += 1
            }
            do {
                try bundledData.write(
                    to: destination,
                    options: [.atomic, .completeFileProtection]
                )
                localByID[bundledSummary.packageID] = destination
                manifest[filename] = destination.lastPathComponent
                manifestChanged = true
            } catch {
                log("patch: bundled package copy failed for \(filename)")
            }
        }

        if manifestChanged {
            saveBundledManifest(manifest, to: root)
        }
    }

    private static func loadBundledManifest(
        from root: URL
    ) -> [String: String] {
        let url = root.appendingPathComponent(bundledManifestFilename)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? PropertyListDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return manifest
    }

    private static func saveBundledManifest(
        _ manifest: [String: String],
        to root: URL
    ) {
        let url = root.appendingPathComponent(bundledManifestFilename)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try encoder.encode(manifest).write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            log("patch: bundled package manifest save failed")
        }
    }

    static func readPackage(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func save(
        data: Data,
        projectName: String,
        existingURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination: URL
        if let existingURL {
            destination = existingURL
        } else {
            let root = try packageRootURL(fileManager: fileManager)
            let baseName = sanitizedFilename(projectName)
            var candidate = root.appendingPathComponent(baseName).appendingPathExtension("3106")
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = root.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("3106")
                suffix += 1
            }
            destination = candidate
        }
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    static func markAsAuthorCopy(
        packageID: UUID,
        fileManager: FileManager = .default
    ) throws {
        let root = try authorCopiesRootURL(fileManager: fileManager)
        try Data().write(
            to: root.appendingPathComponent(packageID.uuidString),
            options: [.atomic, .completeFileProtection]
        )
    }

    static func isAuthorCopy(
        packageID: UUID,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let root = try? authorCopiesRootURL(fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(
            atPath: root.appendingPathComponent(packageID.uuidString).path
        )
    }

    static func overlappingTargetPath(
        in project: PatchProject,
        excludingPackageID: UUID,
        fileManager: FileManager = .default
    ) -> String? {
        var occupied = Set<String>()
        for item in load(fileManager: fileManager) where item.id != excludingPackageID {
            guard let other = item.project else { continue }
            for rule in other.rules {
                occupied.insert(rule.bundleID + "\0" + rule.relativePath)
            }
        }
        for rule in project.rules {
            let key = rule.bundleID + "\0" + rule.relativePath
            if occupied.contains(key) {
                return rule.bundleID + "/" + rule.relativePath
            }
        }
        return nil
    }

    static func installImportedPackage(
        data: Data,
        decoded: DecodedPatchPackage,
        summary: PatchPackageSummary,
        existingURL: URL?,
        origin: PatchPackageOrigin? = nil,
        fileManager: FileManager = .default
    ) throws {
        let authorCopy = isAuthorCopy(
            packageID: summary.packageID,
            fileManager: fileManager
        )
        if let occupiedPath = overlappingTargetPath(
            in: decoded.project,
            excludingPackageID: summary.packageID,
            fileManager: fileManager
        ) {
            if decoded.project.isPrivate, !authorCopy {
                throw PatchPackageError.privateOperationFailed
            }
            throw PatchPackageError.targetOccupied(occupiedPath)
        }
        let previousData = try existingURL.map { try readPackage(at: $0) }
        let originURL = try originFileURL(
            packageID: summary.packageID,
            fileManager: fileManager
        )
        let previousOriginData = try? Data(contentsOf: originURL)
        var savedURL: URL?
        do {
            if let origin {
                try saveOrigin(origin, to: originURL)
            }
            savedURL = try save(
                data: data,
                projectName: decoded.project.name,
                existingURL: existingURL,
                fileManager: fileManager
            )
            if summary.schemaVersion >= 2 {
                if PatchProjectAccessPolicy.shouldMaterializeWorkspace(
                    project: decoded.project,
                    isAuthorCopy: authorCopy
                ) {
                    _ = try PatchWorkspaceService.replaceWorkspace(
                        with: decoded.project,
                        fileManager: fileManager
                    )
                } else {
                    try PatchWorkspaceService.deleteWorkspace(
                        projectID: decoded.project.id,
                        fileManager: fileManager
                    )
                }
            } else {
                try? PatchWorkspaceService.deleteWorkspace(
                    projectID: decoded.project.id,
                    fileManager: fileManager
                )
            }
        } catch {
            if let previousData, let existingURL {
                try? previousData.write(
                    to: existingURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if let savedURL, fileManager.fileExists(atPath: savedURL.path) {
                try? fileManager.removeItem(at: savedURL)
            }
            if let previousOriginData {
                try? previousOriginData.write(
                    to: originURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if origin != nil, fileManager.fileExists(atPath: originURL.path) {
                try? fileManager.removeItem(at: originURL)
            }
            throw error
        }
        try? markAsUserImport(packageID: summary.packageID, fileManager: fileManager)
    }

    static func delete(_ item: PatchLibraryItem, fileManager: FileManager = .default) throws {
        let backupRoot = try backupRootURL(fileManager: fileManager)
        guard PatchTransaction.latestReceipt(
            projectID: item.id,
            backupRoot: backupRoot,
            fileManager: fileManager
        ) == nil else {
            throw PatchPackageError.activePatchCannotBeDeleted
        }
        if fileManager.fileExists(atPath: item.packageURL.path) {
            try fileManager.removeItem(at: item.packageURL)
        }
        try? PatchWorkspaceService.deleteWorkspace(projectID: item.id, fileManager: fileManager)
        try? PatchKeyStore.delete(for: item.summary)
        if let originURL = try? originFileURL(
            packageID: item.id,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: originURL.path) {
            try? fileManager.removeItem(at: originURL)
        }
        if let marker = try? authorCopyMarkerURL(
            packageID: item.id,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: marker.path) {
            try? fileManager.removeItem(at: marker)
        }
        if let marker = try? userImportMarkerURL(
            packageID: item.id,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: marker.path) {
            try? fileManager.removeItem(at: marker)
        }
    }

    static func synchronizeWorkspace(
        item: PatchLibraryItem,
        fileManager: FileManager = .default
    ) throws -> PatchProject {
        guard item.summary.schemaVersion >= 2,
              item.canInspectContents,
              let baseProject = item.project,
              let contentKey = item.contentKey else {
            throw PatchPackageError.invalidProject
        }
        let workspace = try PatchWorkspaceService.ensureWorkspace(
            for: baseProject,
            fileManager: fileManager
        )
        let project = try PatchWorkspaceService.snapshot(
            baseProject: baseProject,
            workspaceURL: workspace,
            fileManager: fileManager
        )
        let original = try readPackage(at: item.packageURL)
        let updated = try PatchPackageCodec.update(
            original,
            project: project,
            contentKey: contentKey,
            schemaVersion: PatchPackageCodec.latestSchemaVersion
        )
        _ = try save(
            data: updated,
            projectName: project.name,
            existingURL: item.packageURL,
            fileManager: fileManager
        )
        return project
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }

    private static func authorCopiesRootURL(
        fileManager: FileManager
    ) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent(authorCopiesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func authorCopyMarkerURL(
        packageID: UUID,
        fileManager: FileManager
    ) throws -> URL {
        try authorCopiesRootURL(fileManager: fileManager)
            .appendingPathComponent(packageID.uuidString)
    }

    private static func userImportsRootURL(fileManager: FileManager) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent(userImportsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func userImportMarkerURL(
        packageID: UUID,
        fileManager: FileManager
    ) throws -> URL {
        try userImportsRootURL(fileManager: fileManager)
            .appendingPathComponent(packageID.uuidString)
    }

    private static func markAsUserImport(
        packageID: UUID,
        fileManager: FileManager
    ) throws {
        let url = try userImportMarkerURL(packageID: packageID, fileManager: fileManager)
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func isUserImport(
        packageID: UUID,
        fileManager: FileManager
    ) -> Bool {
        guard let url = try? userImportMarkerURL(packageID: packageID, fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func originsRootURL(fileManager: FileManager) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent(originsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func originFileURL(
        packageID: UUID,
        fileManager: FileManager
    ) throws -> URL {
        try originsRootURL(fileManager: fileManager)
            .appendingPathComponent(packageID.uuidString)
            .appendingPathExtension("plist")
    }

    private static func loadOrigin(
        packageID: UUID,
        fileManager: FileManager
    ) -> PatchPackageOrigin? {
        guard let url = try? originFileURL(
            packageID: packageID,
            fileManager: fileManager
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PropertyListDecoder().decode(PatchPackageOrigin.self, from: data)
    }

    private static func saveOrigin(
        _ origin: PatchPackageOrigin,
        to url: URL
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(origin).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
    }
}