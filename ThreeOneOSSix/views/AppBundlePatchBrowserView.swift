import SwiftUI
import UniformTypeIdentifiers
import Foundation

// MARK: - App Bundle patch model and isolated storage

struct AppBundlePatchItem: Codable, Identifiable {
    let id: UUID
    var name: String
    let bundleID: String
    let relativePath: String
    let replacementFilename: String
    let replacementData: Data
    let createdAt: Date

    var project: PatchProject {
        PatchProject(
            id: id,
            name: name,
            bundleIdentifiers: [bundleID],
            rules: [
                PatchRule(
                    bundleID: bundleID,
                    relativePath: relativePath,
                    replacementFilename: replacementFilename,
                    replacementData: replacementData
                )
            ]
        )
    }
}

struct InstalledAppBundle: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let version: String
    let path: String
    var id: String { bundleID }
}

enum AppBundlePatchLibrary {
    private static func rootURL(fileManager: FileManager = .default) throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PatchPackageError.applyFailed
        }
        let root = documents.appendingPathComponent(".BundlePatches", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func libraryURL() throws -> URL {
        let url = try rootURL().appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func backupRootURL() throws -> URL {
        let url = try rootURL().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load(bundleID: String) -> [AppBundlePatchItem] {
        guard let root = try? libraryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [] }
        return urls.filter { $0.pathExtension == "bundlepatch" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let item = try? JSONDecoder().decode(AppBundlePatchItem.self, from: data),
                  item.bundleID == bundleID else { return nil }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ item: AppBundlePatchItem) throws {
        let url = try libraryURL().appendingPathComponent(item.id.uuidString).appendingPathExtension("bundlepatch")
        let data = try JSONEncoder().encode(item)
        try data.write(to: url, options: .atomic)
    }

    static func delete(_ item: AppBundlePatchItem) throws {
        if AppBundlePatchService.isApplied(projectID: item.id) {
            throw PatchPackageError.activePatchCannotBeDeleted
        }
        let url = try libraryURL().appendingPathComponent(item.id.uuidString).appendingPathExtension("bundlepatch")
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - App Bundle resolution and transactional apply / restore

enum AppBundlePatchService {
    static func installedApps(refresh: Bool = false) -> [InstalledAppBundle] {
        guard let snapshot = ContainerStore.launchServicesSnapshot() else { return [] }
        let metadata = ContainerStore.applicationBundleMetadataCatalog()
        return snapshot.bundlePaths.compactMap { bundleID, rawPath in
            guard let path = validatedBundlePath(rawPath, expectedBundleID: bundleID) else { return nil }
            let info = metadata[bundleID]
            let name = snapshot.displayName(forBundleID: bundleID)
                ?? info?.displayName
                ?? bundleID
            return InstalledAppBundle(
                bundleID: bundleID,
                name: name,
                version: info?.version ?? "",
                path: path
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func isApplied(projectID: UUID) -> Bool {
        guard let backupRoot = try? AppBundlePatchLibrary.backupRootURL() else { return false }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot) != nil
    }

    static func apply(_ item: AppBundlePatchItem) throws {
        let root = try resolveBundleRoot(bundleID: item.bundleID)
        try withBundleGrant(root: root, expectedBundleID: item.bundleID) {
            _ = try PatchTransaction.apply(
                project: item.project,
                backupRoot: try AppBundlePatchLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard bundleID == item.bundleID else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
        // The transaction engine verifies replacement bytes before marking the journal applied.
        guard isApplied(projectID: item.id) else { throw PatchPackageError.applyFailed }
    }

    static func restore(_ item: AppBundlePatchItem, allowChangedTargets: Bool = false) throws {
        let backupRoot = try AppBundlePatchLibrary.backupRootURL()
        guard let receipt = PatchTransaction.latestReceipt(projectID: item.id, backupRoot: backupRoot) else {
            throw PatchPackageError.restoreFailed
        }
        let requiredIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        guard requiredIDs == [item.bundleID] else { throw PatchPackageError.restoreFailed }
        let root = try resolveBundleRoot(bundleID: item.bundleID)
        try withBundleGrant(root: root, expectedBundleID: item.bundleID) {
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: { bundleID in
                    guard bundleID == item.bundleID else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    private static func resolveBundleRoot(bundleID: String) throws -> URL {
        guard let rawPath = ContainerStore.launchServicesSnapshot()?.bundlePaths[bundleID],
              let path = validatedBundlePath(rawPath, expectedBundleID: bundleID) else {
            throw PatchPackageError.targetAppUnavailable(bundleID)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func validatedBundlePath(_ rawPath: String, expectedBundleID: String) -> String? {
        let canonical = PatchPathValidator.canonicalFileURL(
            URL(fileURLWithPath: rawPath, isDirectory: true)
        ).path
        let allowedRoots = [
            "/private/var/containers/Bundle/Application/",
            "/Applications/",
            "/System/Applications/"
        ]
        guard allowedRoots.contains(where: { canonical.hasPrefix($0) }),
              canonical.hasSuffix(".app"),
              !canonical.contains("/../"),
              !expectedBundleID.isEmpty else {
            return nil
        }
        // LaunchServices supplies the bundle-ID → .app mapping. Do not read
        // Info.plist before acquiring the OS-specific grant: on newer systems
        // that metadata itself may be outside the process sandbox.
        return canonical
    }

    private static func withBundleGrant<T>(root: URL, expectedBundleID: String, operation: () throws -> T) throws -> T {
        // iOS 17/18 kernel backend already has filesystem access. Newer backends
        // must grant the actual .app root with write intent and retain the token
        // for the entire transaction. A successful grant is not treated as proof
        // of a successful patch; PatchTransaction performs the real write/verify.
        let handle: Int64
        if SandboxAccess.backend == .kernel {
            handle = -1
        } else {
            handle = try SandboxAccess.grantOrThrow(path: root.path, writable: true)
        }
        defer { SandboxAccess.release(handle) }

        let infoURL = root.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              (plist["CFBundleIdentifier"] as? String) == expectedBundleID else {
            throw PatchPackageError.targetAppUnavailable(root.lastPathComponent)
        }
        return try operation()
    }
}

// MARK: - App Bundle UI

struct AppBundlePatchBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledAppBundle] = []
    @State private var selectedApp: InstalledAppBundle?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredApps: [InstalledAppBundle] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("App Bundle là thư mục .app của ứng dụng đã cài.", systemImage: "shippingbox")
                    Text("Thay đổi file trong Bundle có thể làm mất chữ ký ứng dụng và khiến ứng dụng không mở được.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Section("Ứng dụng đã cài") {
                    ForEach(filteredApps) { app in
                        Button {
                            selectedApp = app
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).foregroundStyle(.primary)
                                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(app.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Tìm ứng dụng")
            .navigationTitle("App Bundle Patch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        reload()
                    } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.disabled(isLoading)
                }
            }
            .onAppear { if apps.isEmpty { reload() } }
            .sheet(item: $selectedApp) { app in
                AppBundlePatchDetailView(app: app)
            }
            .alert("App Bundle", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppBundlePatchService.installedApps(refresh: true)
            DispatchQueue.main.async {
                apps = result
                isLoading = false
                if result.isEmpty {
                    errorMessage = "Không đọc được danh sách App Bundle. Hãy kiểm tra trạng thái cấp quyền và thử tải lại."
                }
            }
        }
    }
}

private struct AppBundlePatchDetailView: View {
    let app: InstalledAppBundle
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var licenseManager: LicenseManager
    @State private var patches: [AppBundlePatchItem] = []
    @State private var showingPathPrompt = false
    @State private var showingBundlePicker = false
    @State private var targetPath = ""
    @State private var showingImporter = false
    @State private var pendingPath: String?
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(app.name).font(.headline)
                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(app.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Section("Bundle Patch riêng") {
                    if patches.isEmpty {
                        Text("Chưa có patch cho ứng dụng này.").foregroundStyle(.secondary)
                    }
                    ForEach(patches) { patch in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(patch.name).font(.body.weight(.semibold))
                                    Text(patch.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Bật", isOn: Binding(
                                    get: { AppBundlePatchService.isApplied(projectID: patch.id) },
                                    set: { enabled in toggle(patch, enabled: enabled) }
                                ))
                                .labelsHidden()
                                .disabled(isBusy)
                            }
                        }
                    }
                    .onDelete(perform: deletePatches)
                }
                Section {
                    Button {
                        showingBundlePicker = true
                    } label: {
                        Label("Duyệt .app để chọn vị trí", systemImage: "folder")
                    }.disabled(isBusy)
                    Button {
                        targetPath = ""
                        showingPathPrompt = true
                    } label: {
                        Label("Nhập đường dẫn thủ công", systemImage: "text.cursor")
                    }.disabled(isBusy)
                }
            }
            .navigationTitle("Bundle · \(app.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .sheet(
                isPresented: $showingBundlePicker,
                onDismiss: {
                    if pendingPath != nil { showingImporter = true }
                }
            ) {
                AppBundlePathPickerView(rootPath: app.path) { relativePath in
                    targetPath = relativePath
                    pendingPath = relativePath
                    showingBundlePicker = false
                }
            }
            .alert("Đường dẫn trong .app", isPresented: $showingPathPrompt) {
                TextField("Ví dụ: Frameworks/ABC.framework/Info.plist", text: $targetPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Tiếp tục") {
                    do {
                        pendingPath = try PatchPathValidator.canonicalRelativePath(targetPath)
                        showingImporter = true
                    } catch {
                        errorMessage = "Đường dẫn không hợp lệ. Không được dùng đường dẫn tuyệt đối hoặc .."
                    }
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Nhập đường dẫn tương đối tính từ thư mục .app.")
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first, let path = pendingPath else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let item = AppBundlePatchItem(
                        id: UUID(),
                        name: url.lastPathComponent,
                        bundleID: app.bundleID,
                        relativePath: path,
                        replacementFilename: url.lastPathComponent,
                        replacementData: data,
                        createdAt: Date()
                    )
                    try AppBundlePatchLibrary.save(item)
                    reload()
                } catch {
                    errorMessage = "Không thể nhập file patch: \(error.localizedDescription)"
                }
            }
            .alert("Bundle Patch", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        patches = AppBundlePatchLibrary.load(bundleID: app.bundleID)
    }

    private func toggle(_ patch: AppBundlePatchItem, enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                if enabled {
                    // Bundle patches use the same server-side license gate as
                    // App Data patches; local filesystem access alone is not authorization.
                    try await licenseManager.authorizePatch(
                        action: "patch_apply",
                        patchID: patch.id.uuidString
                    )
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if enabled {
                            try AppBundlePatchService.apply(patch)
                        } else {
                            try AppBundlePatchService.restore(patch)
                        }
                        DispatchQueue.main.async {
                            isBusy = false
                            reload()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            isBusy = false
                            errorMessage = "Không thể \(enabled ? "bật" : "tắt") Bundle Patch. \(error.localizedDescription)"
                            reload()
                        }
                    }
                }
            } catch {
                isBusy = false
                errorMessage = "License không cho phép bật Bundle Patch: \(error.localizedDescription)"
            }
        }
    }

    private func deletePatches(at offsets: IndexSet) {
        for index in offsets {
            let patch = patches[index]
            do {
                try AppBundlePatchLibrary.delete(patch)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reload()
    }
}


// MARK: - Read-only .app path picker

private struct AppBundlePathPickerView: View {
    let rootPath: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FileEntry] = []
    @State private var grantHandle: Int64 = -1
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink(destination: AnyView(AppBundlePathDirectoryView(
                            rootPath: rootPath,
                            currentPath: entry.path,
                            onSelect: onSelect
                        ))) {
                            Label(entry.name, systemImage: "folder")
                        }
                    } else {
                        Button {
                            guard let relative = relativePath(entry.path) else {
                                errorMessage = "Đường dẫn nằm ngoài App Bundle."
                                return
                            }
                            onSelect(relative)
                        } label: {
                            Label(entry.name, systemImage: "doc")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Chọn vị trí trong .app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
            .onAppear(perform: load)
            .onDisappear {
                if grantHandle >= 0 { SandboxAccess.release(grantHandle) }
                grantHandle = -1
            }
            .alert("Không thể duyệt App Bundle", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func load() {
        do {
            if SandboxAccess.backend != .kernel {
                grantHandle = try SandboxAccess.grantOrThrow(path: rootPath)
            }
            entries = try directoryEntries(at: rootPath)
        } catch {
            errorMessage = "Không có quyền đọc thư mục .app: \(error.localizedDescription)"
        }
    }

    private func relativePath(_ path: String) -> String? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count + 1))
    }
}

private struct AppBundlePathDirectoryView: View {
    let rootPath: String
    let currentPath: String
    let onSelect: (String) -> Void
    @State private var entries: [FileEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(destination: AnyView(AppBundlePathDirectoryView(
                        rootPath: rootPath,
                        currentPath: entry.path,
                        onSelect: onSelect
                    ))) {
                        Label(entry.name, systemImage: "folder")
                    }
                } else {
                    Button {
                        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
                        let target = URL(fileURLWithPath: entry.path).standardizedFileURL.path
                        guard target.hasPrefix(root + "/") else {
                            errorMessage = "Đường dẫn nằm ngoài App Bundle."
                            return
                        }
                        onSelect(String(target.dropFirst(root.count + 1)))
                    } label: {
                        Label(entry.name, systemImage: "doc")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .navigationTitle(URL(fileURLWithPath: currentPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do { entries = try directoryEntries(at: currentPath) }
            catch { errorMessage = error.localizedDescription }
        }
        .alert("Lỗi đọc thư mục", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private func directoryEntries(at path: String) throws -> [FileEntry] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: path, isDirectory: true),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
        options: []
    )
    return urls.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true else { return nil }
        return FileEntry(
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: values.isDirectory == true,
            size: Int64(values.fileSize ?? 0)
        )
    }.sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
