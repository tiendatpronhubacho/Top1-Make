import Foundation
import CryptoKit

struct PatchStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var messageArgument: String?

    init(titleKey: String, messageKey: String, messageArgument: String? = nil) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.messageArgument = messageArgument
    }

    func message(language: AppLanguage) -> String {
        if let messageArgument {
            return language.text(messageKey, messageArgument)
        }
        return language.text(messageKey)
    }
}

struct AdminPatch: Identifiable, Hashable {
    let id: UUID
    let name: String
    let target: String
}

private struct WorkerPatchList: Decodable {
    let ok: Bool?
    let patches: [WorkerPatch]
    let error: String?
}

private struct WorkerPatch: Decodable {
    let id: String
    let name: String
    let target: String
    let sha256: String
}

@MainActor
final class PatchProjectStore: ObservableObject {
    private let licenseManager: LicenseManager
    @Published private(set) var items: [PatchLibraryItem] = []
    @Published private(set) var adminPatches: [AdminPatch] = []
    @Published private(set) var isBusy = false
    @Published private(set) var loadIssues: [String] = []
    @Published var passwordRequest: PatchPasswordRequest?
    @Published var alert: PatchStoreAlert?
    @Published var unlockErrorKey: String?
    
    // Lưu trạng thái bật/tắt của nút gạt
    @Published var activePatchIDs: Set<UUID> = [] {
        didSet {
            let ids = activePatchIDs.map { $0.uuidString }
            UserDefaults.standard.set(ids, forKey: "com.tiendat.develop.activePatchIDs")
        }
    }

    private struct PendingUnlock {
        let data: Data
        let summary: PatchPackageSummary
        let existingURL: URL?
        let origin: PatchPackageOrigin?
    }

    private var pendingUnlock: PendingUnlock?
    // Names supplied by the Admin API are authoritative for remote packages.
    // A password-protected package has no decoded project name until unlocked.
    private var workerPatchesByID: [UUID: WorkerPatch] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingPatchID: UUID?
    private var prioritizedPrefetchPatchID: UUID?

    init(licenseManager: LicenseManager) {
    self.licenseManager = licenseManager

    if let saved = UserDefaults.standard.array(
        forKey: "com.tiendat.develop.activePatchIDs"
    ) as? [String] {
        self.activePatchIDs = Set(
            saved.compactMap { UUID(uuidString: $0) }
        )
    }

    PatchProjectLibrary.bootstrap()
    self.items = PatchProjectLibrary.load().filter { self.isWorkerManagedPackage($0) }

    // Fetch only lightweight metadata at launch. Patch binaries are downloaded
    // on demand after the user selects a patch.
    Task { @MainActor [weak self] in
        guard let self else { return }
        await self.downloadPatchesFromGithub()
        self.updateLoadIssues()
        self.startBackgroundPatchPrefetch()
    }
}

    private func isWorkerManagedPackage(_ item: PatchLibraryItem) -> Bool {
        item.packageURL.lastPathComponent.hasPrefix("RemoteRelease-")
    }

    private func normalizedRemotePatchName(_ raw: String) -> String {
        let url = URL(fileURLWithPath: raw)
        let stem = url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        return stem.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func remotePatchKey(name: String, target: String) -> String {
        "\(target)|\(normalizedRemotePatchName(name))"
    }

    private func remoteCacheFilename(name: String, target: String) -> String {
        let key = remotePatchKey(name: name, target: target)
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "RemoteRelease-\(digest).\(target)"
    }

    private func cachedItem(for patch: AdminPatch) -> PatchLibraryItem? {
        let filename = remoteCacheFilename(name: patch.name, target: patch.target)
        if let item = items.first(where: { $0.packageURL.lastPathComponent == filename }) {
            return item
        }
        // Backward compatibility with cache files created by older app versions.
        return items.first(where: { $0.id == patch.id })
    }

    private func hasActiveReceipt(_ item: PatchLibraryItem) -> Bool {
        DevicePatchService.latestReceipt(projectID: item.id) != nil
    }

    /// Resolve a remote package by its exact Admin name and target, not by its
    /// changing Worker UUID. This also supports password-protected packages.
    func item(named package: String) -> PatchLibraryItem? {
        let requestedURL = URL(fileURLWithPath: package)
        let target = requestedURL.pathExtension
        guard ["3105", "3106"].contains(target) else { return nil }
        let requestedName = normalizedRemotePatchName(package)
        guard let patch = adminPatches.first(where: {
            $0.target == target && normalizedRemotePatchName($0.name) == requestedName
        }) else { return nil }
        return cachedItem(for: patch)
    }

    private func workerPatchList(target: String) async throws -> [WorkerPatch] {
        guard let baseURL = URL(string: "https://ipa-device-server.dat1888haizz.workers.dev/v2/patches"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "WorkerPatchList", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "URL không hợp lệ"])
        }
        components.queryItems = [
            URLQueryItem(name: "target", value: target),
            URLQueryItem(name: "channel", value: "stable")
        ]
        guard let url = components.url else {
            throw NSError(domain: "WorkerPatchList", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "URL không hợp lệ"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WorkerPatchList", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        return try JSONDecoder().decode(WorkerPatchList.self, from: data).patches
    }

    private func workerPatchListResult(target: String) async -> Result<[WorkerPatch], Error> {
        do {
            return .success(try await workerPatchList(target: target))
        } catch {
            return .failure(error)
        }
    }

    private func downloadPatchesFromGithub() async {
        loadIssues = await downloadPatchesFromWorker()
    }

    /// Fetch the enabled patch metadata. Binary files are warmed in the background after this.
    private func downloadPatchesFromWorker() async -> [String] {
        var failures: [String] = []
        var availablePatches: [AdminPatch] = []
        var latestPatches: [UUID: WorkerPatch] = [:]

        // Fetch both target lists concurrently instead of waiting for 3105 then 3106.
        async let list3105 = workerPatchListResult(target: "3105")
        async let list3106 = workerPatchListResult(target: "3106")
        let results: [(String, Result<[WorkerPatch], Error>)] = await [
            ("3105", list3105),
            ("3106", list3106)
        ]

        for (target, result) in results {
            switch result {
            case .success(let patches):
                for patch in patches {
                    guard patch.target == target,
                          let patchUUID = UUID(uuidString: patch.id),
                          patch.sha256.count == 64 else {
                        failures.append("\(patch.name): metadata Worker không hợp lệ")
                        continue
                    }
                    latestPatches[patchUUID] = patch
                    availablePatches.append(
                        AdminPatch(id: patchUUID, name: patch.name, target: patch.target)
                    )
                }
            case .failure(let error):
                failures.append("Worker Patch \(target): \(error.localizedDescription)")
                log("patch: Worker list failed target=\(target): \(error)")
            }
        }

        workerPatchesByID = latestPatches
        adminPatches = availablePatches.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return failures
    }

    /// Warm the local cache after the lightweight Admin list is loaded.
    /// This runs in the background and never holds the UI's busy state.
    private func startBackgroundPatchPrefetch() {
        guard licenseManager.isLicensed, !adminPatches.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for patch in self.adminPatches {
                if Task.isCancelled { break }
                guard let metadata = self.workerPatchesByID[patch.id] else { continue }

                if let cached = self.cachedItem(for: patch),
                   let data = try? Data(contentsOf: cached.packageURL) {
                    let hash = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }.joined()
                    if hash.caseInsensitiveCompare(metadata.sha256) == .orderedSame,
                       (try? PatchPackageCodec.inspect(data)) != nil {
                        // Migrate an older UUID-named cache to the stable name-based path.
                        let destination = try? PatchProjectLibrary.packageRootURL()
                            .appendingPathComponent(self.remoteCacheFilename(name: patch.name, target: patch.target))
                        if let destination,
                           cached.packageURL.lastPathComponent != destination.lastPathComponent,
                           !self.hasActiveReceipt(cached) {
                            try? FileManager.default.moveItem(at: cached.packageURL, to: destination)
                            self.reload()
                        }
                        continue
                    }
                    // Never replace bytes while their package identity owns an active
                    // restore receipt. Keep the old package intact until it is restored.
                    if self.hasActiveReceipt(cached) {
                        log("patch: defer same-name update until restore: \(patch.name)")
                        continue
                    }
                }

                self.prefetchingPatchID = patch.id
                do {
                    let data = try await self.licenseManager.downloadPatchData(patchID: metadata.id)
                    if Task.isCancelled { break }
                    let hash = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }.joined()
                    guard hash.caseInsensitiveCompare(metadata.sha256) == .orderedSame else {
                        throw NSError(domain: "WorkerPatchPrefetch", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "SHA-256 không khớp"])
                    }
                    _ = try PatchPackageCodec.inspect(data)
                    let root = try PatchProjectLibrary.packageRootURL()
                    let destination = root.appendingPathComponent(
                        self.remoteCacheFilename(name: patch.name, target: patch.target)
                    )
                    try data.write(to: destination, options: [.atomic, .completeFileProtection])
                    log("patch: background prefetch complete \(patch.name), bytes=\(data.count)")
                    self.reload()
                    if self.prioritizedPrefetchPatchID == patch.id {
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        log("patch: background prefetch skipped \(patch.name): \(error)")
                    }
                    if self.prioritizedPrefetchPatchID == patch.id {
                        break
                    }
                }
                self.prefetchingPatchID = nil
            }
            self.prefetchingPatchID = nil
            self.prefetchTask = nil
        }
    }

    /// Download the selected patch only, verify its SHA-256, then apply it.
    func applyAdminPatch(_ patch: AdminPatch) {
        guard !isBusy else { return }

        guard let metadata = workerPatchesByID[patch.id] else {
            alert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.apply_failed"
            )
            return
        }

        if let cachedItem = cachedItem(for: patch),
           let cachedData = try? Data(contentsOf: cachedItem.packageURL) {
            let cachedHash = SHA256.hash(data: cachedData)
                .map { String(format: "%02x", $0) }.joined()
            if cachedHash.caseInsensitiveCompare(metadata.sha256) == .orderedSame,
               (try? PatchPackageCodec.inspect(cachedData)) != nil {
                applyPatch(cachedItem)
                return
            }
            if hasActiveReceipt(cachedItem) {
                alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.apply_failed")
                log("patch: cannot replace same-name package while its old version is active: \(patch.name)")
                return
            }
        }

        // If this exact patch is currently being prefetched, let that download
        // finish instead of starting a second copy of the same transfer.
        if prefetchingPatchID == patch.id, let runningPrefetch = prefetchTask {
            prioritizedPrefetchPatchID = patch.id
            isBusy = true
            Task { @MainActor [weak self] in
                await runningPrefetch.value
                guard let self else { return }
                self.isBusy = false
                self.prioritizedPrefetchPatchID = nil
                self.reload()
                if let ready = self.cachedItem(for: patch) {
                    self.applyPatch(ready)
                } else {
                    self.isBusy = true
                    self.downloadAndApplyAdminPatch(patch, metadata: metadata)
                }
            }
            return
        }

        // Prioritize the tapped patch over the remaining background queue.
        prefetchTask?.cancel()
        prefetchTask = nil
        isBusy = true
        downloadAndApplyAdminPatch(patch, metadata: metadata)
    }

    private func downloadAndApplyAdminPatch(_ patch: AdminPatch, metadata: WorkerPatch) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let rootURL = try PatchProjectLibrary.packageRootURL()
                let destination = rootURL.appendingPathComponent(
                    self.remoteCacheFilename(name: patch.name, target: patch.target)
                )

                let packageData = try await self.licenseManager.downloadPatchData(
                    patchID: metadata.id
                )
                let actualHash = SHA256.hash(data: packageData)
                    .map { String(format: "%02x", $0) }.joined()

                guard actualHash.caseInsensitiveCompare(metadata.sha256) == .orderedSame else {
                    throw NSError(
                        domain: "WorkerPatchDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "SHA-256 không khớp"]
                    )
                }

                _ = try PatchPackageCodec.inspect(packageData)
                try packageData.write(
                    to: destination,
                    options: [.atomic, .completeFileProtection]
                )
                log("patch: downloaded selected Admin patch \(patch.name), sha256=\(actualHash)")

                self.reload()
                guard let downloadedItem = self.cachedItem(for: patch) else {
                    throw NSError(
                        domain: "WorkerPatchDownload",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy Patch sau khi tải"]
                    )
                }

                self.isBusy = false
                self.applyPatch(downloadedItem)
            } catch {
                self.isBusy = false
                log("patch: selected download failed -- \(patch.name): \(error)")
                self.alert = PatchStoreAlert(
                    titleKey: "common.failed",
                    messageKey: "patch.apply_failed"
                )
            }
        }
    }

    /// Re-check the Admin's live enabled list immediately before every apply.
    /// A cached package is never sufficient authorization to activate a patch.
    private func isWorkerPatchEnabled(_ item: PatchLibraryItem) async throws -> Bool {
        let filename = item.packageURL.lastPathComponent
        let target = item.packageURL.pathExtension
        guard ["3105", "3106"].contains(target),
              let metadata = workerPatchesByID.values.first(where: { candidate in
                  candidate.target == target &&
                  item.packageURL.lastPathComponent == remoteCacheFilename(
                      name: candidate.name,
                      target: candidate.target
                  )
              }) ?? workerPatchesByID.values.first(where: { candidate in
                  guard candidate.target == target,
                        let remoteID = UUID(uuidString: candidate.id) else { return false }
                  return item.id == remoteID
              }) else {
            log("patch: activation denied; local package has no matching Admin name: \(filename)")
            return false
        }

        let patches = try await workerPatchList(target: target)
        guard let patch = patches.first(where: {
            $0.target == target &&
            normalizedRemotePatchName($0.name) == normalizedRemotePatchName(metadata.name)
        }) else {
            log("patch: activation denied; Admin has disabled or removed \(metadata.name)")
            return false
        }

        let data = try Data(contentsOf: item.packageURL)
        let actualHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard actualHash.caseInsensitiveCompare(patch.sha256) == .orderedSame else {
            log("patch: activation denied; cached package hash mismatch \(filename)")
            return false
        }
        _ = try PatchPackageCodec.inspect(data)
        return true
    }

    private func updateLoadIssues() {
        loadIssues = Array(Set(loadIssues)).sorted()
    }

    func reload() {
        PatchProjectLibrary.bootstrap()
        items = PatchProjectLibrary.load().filter { isWorkerManagedPackage($0) }
        updateLoadIssues()
    }

    // MARK: - Apply & Restore (Có cập nhật nút gạt)

    
func applyPatch(_ item: PatchLibraryItem) {
    guard !isBusy else { return }

    guard let project = item.project else {
        if item.isLocked {
            requestUnlock(for: item)
        } else {
            present(.invalidProject)
        }
        return
    }

    isBusy = true
    let itemID = item.id

    Task { @MainActor [weak self] in
        guard let self else { return }

        do {
            // Run the live Admin-enabled check and signed License authorization
            // at the same time, rather than waiting for two network round trips in series.
            async let enabledCheck = self.isWorkerPatchEnabled(item)
            async let licenseAuthorization: Void = self.licenseManager.authorizePatch(
                action: "patch_apply"
            )
            let (isEnabled, _) = try await (enabledCheck, licenseAuthorization)

            guard isEnabled else {
                throw NSError(
                    domain: "WorkerPatchAuthorization",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Patch chưa được bật hoặc đã bị tắt trên Admin"]
                )
            }
            _ = try await DevicePatchService.apply(
                project: project,
                licenseManager: self.licenseManager,
                authorizationAlreadyValidated: true
            )

            self.activePatchIDs.insert(itemID)
            self.isBusy = false

            self.alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.applied_message"
            )

        } catch let error as PatchPackageError {
            self.isBusy = false
            self.present(error)

        } catch {
            self.isBusy = false

            log("patch: apply failed: \(error.localizedDescription)")

            self.alert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.apply_failed"
            )
        }
    }
}
    func restorePatch(_ item: PatchLibraryItem) {
        guard !isBusy else { return }
        let itemID = item.id
        
        guard let receipt = DevicePatchService.latestReceipt(projectID: itemID) else {
            activePatchIDs.remove(itemID)
            return
        }
        
        isBusy = true
        
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restore(receipt: receipt)
                }.value
                
                guard let self = self else { return }
                self.activePatchIDs.remove(itemID)
                self.isBusy = false
                self.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.isBusy = false
                self.present(error)
            } catch {
                guard let self = self else { return }
                self.isBusy = false
                self.present(.restoreFailed)
            }
        }
    }

    // MARK: - CRUD
    func create(project: PatchProject, password: String?) {
        runOperation(successMessageKey: "patch.created_message") {
            let encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
            let summary = try PatchPackageCodec.inspect(encoded.data)
            let workspace = try PatchWorkspaceService.createWorkspace(for: project)
            var savedURL: URL?
            do {
                if summary.isPasswordProtected {
                    try PatchKeyStore.store(encoded.contentKey, for: summary)
                }
                savedURL = try PatchProjectLibrary.save(
                    data: encoded.data,
                    projectName: project.name
                )
                try PatchProjectLibrary.markAsAuthorCopy(packageID: project.id)
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                if let savedURL {
                    try? FileManager.default.removeItem(at: savedURL)
                }
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
        }
    }

    func update(project: PatchProject) {
        guard let item = items.first(where: { $0.id == project.id }),
              let contentKey = item.contentKey else {
            present(.invalidProject)
            return
        }
        runOperation(successMessageKey: "patch.updated_message") {
            let original = try PatchProjectLibrary.readPackage(at: item.packageURL)
            let updated = try PatchPackageCodec.update(
                original,
                project: project,
                contentKey: contentKey,
                schemaVersion: PatchPackageCodec.latestSchemaVersion
            )
            _ = try PatchProjectLibrary.save(
                data: updated,
                projectName: project.name,
                existingURL: item.packageURL
            )
        }
    }

    func importPackage(at sourceURL: URL) {
        guard !isBusy else { return }
        isBusy = true
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        
        Task { @MainActor [weak self] in
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try PatchProjectLibrary.readPackage(at: sourceURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = self?.existingPackageURL(for: summary.packageID)
                
                let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                )
                
                guard let self = self else { return }
                if let pending {
                    self.requestPassword(pending: pending)
                } else {
                    self.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failOperation(error)
            } catch {
                guard let self = self else { return }
                self.failOperation(.unsupportedFormat)
            }
        }
    }

    @discardableResult
    func importPackage(
        data: Data,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil
    ) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        
        Task { @MainActor [weak self] in
            do {
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = self?.existingPackageURL(for: summary.packageID)
                
                let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    password: password,
                    origin: origin
                )
                
                guard let self = self else { return }
                if let pending {
                    self.requestPassword(pending: pending)
                } else {
                    self.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failOperation(error)
            } catch {
                guard let self = self else { return }
                self.failOperation(.unsupportedFormat)
            }
        }
        return true
    }

    func presentImportError(_ error: PatchPackageError) {
        present(error)
    }

    func importPackage(from source: PatchImportSource) {
        switch source {
        case .file(let url): importPackage(at: url)
        case .remote(let url): importPackage(fromRemoteURL: url)
        case .invalid: present(.invalidImportLink)
        }
    }

    private func importPackage(fromRemoteURL remoteURL: URL) {
        guard !isBusy, PatchImportRoute.validatedRemoteURL(remoteURL) != nil else {
            if !isBusy { present(.invalidImportLink) }
            return
        }
        isBusy = true
        
        Task { @MainActor [weak self] in
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }

                let (temporaryURL, response) = try await session.download(from: remoteURL)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let finalURL = response.url,
                      PatchImportRoute.validatedRemoteURL(finalURL) != nil else {
                    throw PatchPackageError.remoteImportFailed
                }

                let data = try PatchProjectLibrary.readPackage(at: temporaryURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = self?.existingPackageURL(for: summary.packageID)
                
                let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                )
                
                guard let self = self else { return }
                if let pending {
                    self.requestPassword(pending: pending)
                } else {
                    self.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failOperation(error)
            } catch {
                guard let self = self else { return }
                self.failOperation(.remoteImportFailed)
            }
        }
    }

    // MARK: - Unlock Password

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
            pendingUnlock = PendingUnlock(
                data: data,
                summary: item.summary,
                existingURL: item.packageURL,
                origin: item.origin
            )
            passwordRequest = PatchPasswordRequest(
                summary: item.summary,
                origin: item.origin
            )
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.unsupportedFormat)
        }
    }

    func unlock(password: String) {
        guard let pending = pendingUnlock, !isBusy else { return }
        isBusy = true
        unlockErrorKey = nil
        
        Task { @MainActor [weak self] in
            do {
                let decoded = try PatchPackageCodec.decode(pending.data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: pending.summary)
                do {
                    try PatchProjectLibrary.installImportedPackage(
                        data: pending.data,
                        decoded: decoded,
                        summary: pending.summary,
                        existingURL: pending.existingURL,
                        origin: pending.origin
                    )
                } catch {
                    try? PatchKeyStore.delete(for: pending.summary)
                    throw error
                }
                
                guard let self = self else { return }
                self.clearPendingUnlock()
                self.finishOperation(successMessageKey: "patch.unlocked_message")
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failUnlock(error)
            } catch {
                guard let self = self else { return }
                self.failUnlock(.invalidPasswordOrCorruptedPackage)
            }
        }
    }

    func cancelUnlock() {
        clearPendingUnlock()
        isBusy = false
    }

    func clearUnlockError() {
        unlockErrorKey = nil
    }

    func delete(_ item: PatchLibraryItem) {
        do {
            try PatchProjectLibrary.delete(item)
            reload()
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.invalidProject)
        }
    }

    func synchronizeWorkspace(projectID: UUID, reportsSuccess: Bool = false) {
        guard let item = items.first(where: { $0.id == projectID }),
              item.summary.schemaVersion >= 2,
              !isBusy else { return }
        isBusy = true
        
        Task { @MainActor [weak self] in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try PatchProjectLibrary.synchronizeWorkspace(item: item)
                }.value
                guard let self = self else { return }
                self.finishWorkspaceSynchronization(reportsSuccess: reportsSuccess)
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failOperation(error)
            } catch {
                guard let self = self else { return }
                self.failOperation(.invalidProject)
            }
        }
    }

    private func finishWorkspaceSynchronization(reportsSuccess: Bool) {
        reload()
        isBusy = false
        if reportsSuccess {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.workspace_synced_message"
            )
        }
    }

    private func runOperation(
        successMessageKey: String,
        operation: @escaping () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                guard let self = self else { return }
                self.finishOperation(successMessageKey: successMessageKey)
            } catch let error as PatchPackageError {
                guard let self = self else { return }
                self.failOperation(error)
            } catch {
                guard let self = self else { return }
                self.failOperation(.invalidProject)
            }
        }
    }

    private func requestPassword(pending: PendingUnlock) {
        pendingUnlock = pending
        passwordRequest = PatchPasswordRequest(
            summary: pending.summary,
            origin: pending.origin
        )
        isBusy = false
    }

    private func existingPackageURL(for packageID: UUID) -> URL? {
        items.first(where: { $0.id == packageID })?.packageURL
    }

    private nonisolated static func persistImportedPackage(
        data: Data,
        summary: PatchPackageSummary,
        existingURL: URL?,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil
    ) throws -> PendingUnlock? {
        if let key = try PatchKeyStore.load(for: summary) {
            let decoded = try PatchPackageCodec.decode(data, contentKey: key)
            try PatchProjectLibrary.installImportedPackage(
                data: data,
                decoded: decoded,
                summary: summary,
                existingURL: existingURL,
                origin: origin
            )
            return nil
        }
        if summary.isPasswordProtected {
            guard let password else {
                return PendingUnlock(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin
                )
            }
            let decoded = try PatchPackageCodec.decode(data, password: password)
            try PatchKeyStore.store(decoded.contentKey, for: summary)
            do {
                try PatchProjectLibrary.installImportedPackage(
                    data: data,
                    decoded: decoded,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin
                )
            } catch {
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
            return nil
        }
        let decoded = try PatchPackageCodec.decode(data, password: nil)
        try PatchProjectLibrary.installImportedPackage(
            data: data,
            decoded: decoded,
            summary: summary,
            existingURL: existingURL,
            origin: origin
        )
        return nil
    }

    private func clearPendingUnlock() {
        pendingUnlock = nil
        passwordRequest = nil
        unlockErrorKey = nil
    }

    private func finishOperation(successMessageKey: String) {
        reload()
        isBusy = false
        alert = PatchStoreAlert(titleKey: "common.done", messageKey: successMessageKey)
    }

    private func failOperation(_ error: PatchPackageError) {
        isBusy = false
        present(error)
    }

    private func failUnlock(_ error: PatchPackageError) {
        isBusy = false
        if case .invalidPasswordOrCorruptedPackage = error {
            unlockErrorKey = "patch.error.wrong_password"
        } else {
            unlockErrorKey = error.localizationKey
        }
    }

    private func present(_ error: PatchPackageError) {
        alert = PatchStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey,
            messageArgument: error.localizationArgument
        )
    }
}