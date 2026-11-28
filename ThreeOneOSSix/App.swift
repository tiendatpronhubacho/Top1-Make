import SwiftUI
import UIKit
import CryptoKit
import Security

@main
struct ThreeOneOSSixApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var licenseManager = LicenseManager()
    
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showAttribution = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("app: TienDat \(appVersion) (\(appBuild)) launching -- iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        SandboxAccess.prepare()
        PatchProjectLibrary.bootstrap()
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if licenseManager.isLicensed {
                    ContentView()
                        .environmentObject(appState)
                        .environmentObject(patchDraftCoordinator)
                        .environmentObject(fileOperationCoordinator)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                } else {
                    LicenseActivationView()
                        .environmentObject(licenseManager)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                }
            }
            .environmentObject(licenseManager)
            .preferredColorScheme(.dark)
            .onAppear {
                Task { await licenseManager.refresh() }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await licenseManager.refresh() }
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?

    /// Same storage key as the `@AppStorage` in `ThreeOneOSSixApp`. AppState
    /// is a plain class, so it cannot read the struct's property directly --
    /// it resolves the language from the shared defaults instead.
    private var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "")
            ?? .english
    }
    @Published var kernelExploitRunning = false

    // Do not repeat support detection when the app returns from background.
    // The successful unlock state remains in this AppState for this process.
    private var didDetectSupport = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        guard !didDetectSupport else { return }
        didDetectSupport = true

        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        if !supported {
            // The explanation lives in RejectionReason so onboarding can show
            // the identical copy without a second hand-maintained copy drifting
            // the moment a version boundary moves.
            if let reason = RejectionReason.make(
                major: v.major,
                minor: v.minor,
                patch: v.patch,
                build: AppInfo.osBuild,
                osVersion: "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))",
                isA10: DeviceCPU.isA10
            ) {
                unsupportedMessage = language.text(reason.key, reason.arguments)
            }
        }
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        // Deliberately no auto-run. The kernel chain reboots the device when it
        // goes wrong, and a process that quietly executes an exploit at launch
        // gives the user no chance to consent or to read what happened. The
        // Unlock screen is the only entry point now; `kernelExploitRunning`,
        // `exploitStatus` and the banner state drive it.
    }

    /// True when the app should offer the Unlock screen: a kernel backend that
    /// has not succeeded yet. Deliberately excludes a settled failure -- retrying
    /// automatically after a failure would recreate the silent loop this change
    /// removed. The user re-opens Unlock explicitly to try again.
    var needsUnlock: Bool {
        ExploitSupportPolicy.requiresExplicitUnlock(
            isKernelBackend: SandboxAccess.backend == .kernel,
            hasAccess: exploitStatus.isSuccess
        )
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // Always verify the real filesystem capability on launch. The old
        // kernel path skipped this probe entirely, so a new process always
        // started with `.notStarted` even when the sandbox grant was still
        // usable. Never restore success from a persisted Boolean: the probe
        // must succeed in this process before privileged UI is enabled.
        let hasAccess: Bool
        switch SandboxAccess.backend {
        case .kernel:
            hasAccess = KernelExploit.hasKernelSandboxAccess()
        case .badQuery, .worseQuery:
            hasAccess = KernelExploit.hasSandboxAccess()
        case .unsupported:
            hasAccess = false
        }

        if hasAccess {
            if !exploitStatus.isSuccess {
                exploitStatus = .success(method: SandboxAccess.backend.displayName)
                log("app: verified existing \(SandboxAccess.backend.displayName) access is active")
            }
        } else if exploitStatus.isSuccess {
            exploitStatus = .notStarted
            log("app: access probe failed; unlock is required again")
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        let backend = SandboxAccess.backend
        log("app: running \(backend.displayName) access setup on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: backend.displayName)
                    if backend == .kernel {
                        log("app: kernel access active")
                    } else {
                        log("app: \(backend.displayName) access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: backend.displayName, code: -1)
                    if backend == .worseQuery && !SandboxAccess.hasAppGroup {
                        log("app: worse_query needs an App Group; re-sign with a tool that provides one")
                    } else {
                        log("app: \(backend.displayName) setup failed -- relaunch the app before retrying")
                    }
                }
            }
        }
    }
}

// MARK: - License security

private enum LicenseConfig {
    static let baseURL = URL(string: "https://ipa-device-server.dat1888haizz.workers.dev")!
    static let keychainService = "com.tiendat.license.secure"
    static let deviceAccount = "device-id"
    static let licenseAccount = "license-key"
    static let signingKeyAccount = "device-signing-key"
}

private struct LicenseChallenge: Decodable {
    let ok: Bool
    let challenge: String
    let expiresAt: Int
}

private struct LicenseResult: Decodable {
    let ok: Bool
    let status: String?
    let expiresAt: Int?
    let label: String?
    let error: String?
}

private struct PatchDownloadAuthorization: Decodable {
    let ok: Bool
    let ticket: String?
    let error: String?
}

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var isLicensed = false
    @Published private(set) var licenseStatus = "Chưa kích hoạt"
    @Published private(set) var licenseeName: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var deviceID = ""
    @Published var isBusy = false
    @Published var errorMessage: String?

    private var refreshInProgress = false

    func activate(licenseKey input: String) async {
        guard !isBusy else { return }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 12 && key.count <= 160 else {
            errorMessage = "License Key không hợp lệ."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let id = try getOrCreateDeviceID()
            deviceID = id
            let signingKey = try getOrCreateSigningKey()
            let buildHash = try currentBuildHash()
            let challenge = try await requestChallenge(deviceID: id, action: "register", buildHash: buildHash)
            let message = canonical(challenge: challenge, action: "register", deviceID: id, licenseKey: key, buildHash: buildHash)
            let signature = try signingKey.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
            let payload: [String: Any] = [
    "deviceId": id,
    "licenseKey": key,
    "challenge": challenge,
    "signature": signature,
    "publicKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
    "appVersion": appVersion,
    "buildHash": buildHash
]
            let result: LicenseResult = try await post("/v2/device/register", payload: payload)
            guard result.ok else { throw LicenseFailure.server(result.error ?? "license_denied") }
            try keychainSave(key, account: LicenseConfig.licenseAccount)
            apply(result)
            isLicensed = true
            errorMessage = nil
        } catch {
            isLicensed = false
            errorMessage = error.localizedDescription
            licenseStatus = "Chưa xác thực"
        }
    }

    func refresh() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        do {
            guard let key = try keychainRead(account: LicenseConfig.licenseAccount), !key.isEmpty else {
                isLicensed = false
                licenseStatus = "Chưa kích hoạt"
                return
            }
            let id = try getOrCreateDeviceID()
            deviceID = id
            let signingKey = try getOrCreateSigningKey()
            let buildHash = try currentBuildHash()
            let challenge = try await requestChallenge(deviceID: id, action: "verify", buildHash: buildHash)
            let message = canonical(challenge: challenge, action: "verify", deviceID: id, licenseKey: key, buildHash: buildHash)
            let signature = try signingKey.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
            let payload: [String: Any] = [
                "deviceId": id,
                "licenseKey": key,
                "challenge": challenge,
                "signature": signature,
                "appVersion": appVersion,
                "buildHash": buildHash
            ]
            let result: LicenseResult = try await post("/v2/device/verify", payload: payload)
            guard result.ok else { throw LicenseFailure.server(result.error ?? "license_denied") }
            apply(result)
            isLicensed = true
            errorMessage = nil
        } catch {
            // Fail closed: no cached "active" flag is trusted while offline.
            isLicensed = false
            licenseStatus = "Không thể xác thực"
            errorMessage = error.localizedDescription
        }
    }
    // MARK: - Patch Authorization

func authorizePatch(action: String, patchID: String? = nil) async throws {
    guard action == "patch_download" ||
          action == "patch_apply" else {
        throw LicenseFailure.server("invalid_patch_action")
    }
    guard let patchID, !patchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LicenseFailure.server("patch_id_required")
    }

    guard isLicensed else {
        throw LicenseFailure.server("license_invalid")
    }

    guard let key = try keychainRead(
        account: LicenseConfig.licenseAccount
    ), !key.isEmpty else {
        isLicensed = false
        throw LicenseFailure.server("license_invalid")
    }

    let id = try getOrCreateDeviceID()
    deviceID = id

    let signingKey = try getOrCreateSigningKey()
    let buildHash = try currentBuildHash()

    let challenge = try await requestChallenge(
        deviceID: id,
        action: action,
        buildHash: buildHash
    )

    let message = canonical(
        challenge: challenge,
        action: action,
        deviceID: id,
        licenseKey: key,
        buildHash: buildHash,
        patchID: patchID
    )

    let signature = try signingKey
        .signature(for: Data(message.utf8))
        .rawRepresentation
        .base64EncodedString()

    var payload: [String: Any] = [
        "deviceId": id,
        "licenseKey": key,
        "challenge": challenge,
        "signature": signature,
        "buildHash": buildHash
    ]
    payload["patchId"] = patchID

    let endpoint = action == "patch_download"
        ? "/v2/patch/authorize-download"
        : "/v2/patch/authorize-apply"

    let result: LicenseResult = try await post(
        endpoint,
        payload: payload
    )

    guard result.ok else {
        throw LicenseFailure.server(
            result.error ?? "patch_authorization_denied"
        )
    }
}

    /// Downloads a Release asset using a device-bound, one-use Worker ticket.
    func downloadPatchData(patchID: String) async throws -> Data {
        guard isLicensed else { throw LicenseFailure.server("license_invalid") }
        guard let key = try keychainRead(account: LicenseConfig.licenseAccount), !key.isEmpty else {
            isLicensed = false
            throw LicenseFailure.server("license_invalid")
        }

        let id = try getOrCreateDeviceID()
        deviceID = id
        let signingKey = try getOrCreateSigningKey()
        let buildHash = try currentBuildHash()
        let challenge = try await requestChallenge(deviceID: id, action: "patch_download", buildHash: buildHash)
        let message = canonical(challenge: challenge, action: "patch_download", deviceID: id, licenseKey: key, buildHash: buildHash, patchID: patchID)
        let signature = try signingKey.signature(for: Data(message.utf8))
            .rawRepresentation.base64EncodedString()

        let authorization: PatchDownloadAuthorization = try await post(
            "/v2/patch/authorize-download",
            payload: [
                "deviceId": id,
                "licenseKey": key,
                "patchId": patchID,
                "challenge": challenge,
                "signature": signature,
                "buildHash": buildHash
            ]
        )
        guard authorization.ok, let ticket = authorization.ticket, !ticket.isEmpty else {
            throw LicenseFailure.server(authorization.error ?? "patch_authorization_denied")
        }

        guard let url = URL(string: "/v2/patch/download", relativeTo: LicenseConfig.baseURL) else {
            throw LicenseFailure.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 90
        request.setValue(ticket, forHTTPHeaderField: "X-Download-Ticket")
        request.setValue(id, forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseFailure.network }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = (try? JSONDecoder().decode(LicenseResult.self, from: data))?.error
                ?? "patch_download_http_\(http.statusCode)"
            throw LicenseFailure.server(apiError)
        }
        guard !data.isEmpty else { throw LicenseFailure.server("patch_download_empty") }
        return data
    }

    func deactivateLocalKey() {
        try? keychainDelete(account: LicenseConfig.licenseAccount)
        isLicensed = false
        licenseStatus = "Chưa kích hoạt"
        licenseeName = nil
        expiresAt = nil
    }

    func validate() -> Bool { isLicensed }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v)(\(b))"
    }

    private func apply(_ result: LicenseResult) {
        licenseStatus = result.status ?? "active"
        licenseeName = result.label
        if let timestamp = result.expiresAt { expiresAt = Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    }

    private func currentBuildHash() throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "IPAOfficialBuildMarker") as? String == "TIENDAT-OFFICIAL-IPA-V1",
              let storedID = Bundle.main.object(forInfoDictionaryKey: "IPAOfficialBuildID") as? String,
              storedID.hasPrefix("TIENDAT-OFFICIAL-BUILD-ID:") else {
            throw LicenseFailure.server("official_ipa_required")
        }

        // Verify the executable's immutable __TEXT segment before trusting the
        // build identity. The code-signature blob is outside __TEXT, so normal
        // re-signing does not invalidate this digest.
        guard let expectedTextHash = Bundle.main.object(forInfoDictionaryKey: "IPAExecutableTextSHA256") as? String,
              expectedTextHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw LicenseFailure.server("binary_integrity_manifest_missing")
        }
        let actualTextHash = try executableTextSegmentSHA256()
        guard actualTextHash == expectedTextHash else {
            log("security: executable __TEXT hash mismatch; refusing license authorization")
            throw LicenseFailure.server("binary_integrity_failed")
        }

        let rawID = String(storedID.dropFirst("TIENDAT-OFFICIAL-BUILD-ID:".count)).lowercased()
        guard let buildID = UUID(uuidString: rawID) else {
            throw LicenseFailure.server("official_ipa_required")
        }
        let canonicalID = buildID.uuidString.lowercased()
        return SHA256.hash(data: Data(canonicalID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the Mach-O __TEXT segment, not the entire executable. iOS
    /// re-signing changes the code-signature area but leaves __TEXT unchanged.
    private func executableTextSegmentSHA256() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw LicenseFailure.server("binary_integrity_unavailable")
        }
        let executable = try Data(contentsOf: executableURL, options: .mappedIfSafe)

        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= executable.count - 4 else {
                throw LicenseFailure.server("binary_integrity_invalid_macho")
            }
            return UInt32(executable[offset])
                | (UInt32(executable[offset + 1]) << 8)
                | (UInt32(executable[offset + 2]) << 16)
                | (UInt32(executable[offset + 3]) << 24)
        }

        func u64(_ offset: Int) throws -> UInt64 {
            guard offset >= 0, offset <= executable.count - 8 else {
                throw LicenseFailure.server("binary_integrity_invalid_macho")
            }
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(executable[offset + index]) << (index * 8)
            }
            return value
        }

        // Current release workflow produces a thin arm64 iOS executable.
        guard executable.count >= 32, try u32(0) == 0xfeedfacf else {
            throw LicenseFailure.server("binary_integrity_unsupported_macho")
        }

        let commandCount = Int(try u32(16))
        let commandBytes = Int(try u32(20))
        guard commandCount > 0, commandCount <= 10000,
              commandBytes <= executable.count - 32 else {
            throw LicenseFailure.server("binary_integrity_invalid_macho")
        }

        var cursor = 32
        let commandEnd = 32 + commandBytes
        for _ in 0..<commandCount {
            let command = try u32(cursor)
            let commandSize = Int(try u32(cursor + 4))
            guard commandSize >= 8, cursor <= commandEnd - commandSize else {
                throw LicenseFailure.server("binary_integrity_invalid_macho")
            }

            if command == 0x19, commandSize >= 72 { // LC_SEGMENT_64
                let nameData = executable.subdata(in: (cursor + 8)..<(cursor + 24))
                let segmentName = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
                if segmentName == "__TEXT" {
                    let fileOffset = try u64(cursor + 40)
                    let fileSize = try u64(cursor + 48)
                    guard fileSize > 0, fileOffset <= UInt64(executable.count),
                          fileSize <= UInt64(executable.count) - fileOffset,
                          fileOffset <= UInt64(Int.max), fileSize <= UInt64(Int.max) else {
                        throw LicenseFailure.server("binary_integrity_invalid_text_segment")
                    }
                    let start = Int(fileOffset)
                    let end = start + Int(fileSize)
                    let textBytes = executable.subdata(in: start..<end)
                    return SHA256.hash(data: textBytes)
                        .map { String(format: "%02x", $0) }.joined()
                }
            }
            cursor += commandSize
        }
        throw LicenseFailure.server("binary_integrity_text_segment_missing")
    }

    private func canonical(challenge: String, action: String, deviceID: String, licenseKey: String, buildHash: String, patchID: String? = nil) -> String {
        let base = "\(challenge)\n\(action)\n\(deviceID)\n\(licenseKey)\n\(buildHash)"
        guard (action == "patch_apply" || action == "patch_download"),
              let patchID, !patchID.isEmpty else { return base }
        return base + "\n" + patchID
    }

    private func requestChallenge(deviceID: String, action: String, buildHash: String) async throws -> String {
        let response: LicenseChallenge = try await post("/v2/challenge", payload: ["deviceId": deviceID, "action": action, "buildHash": buildHash])
        guard response.ok else { throw LicenseFailure.server("challenge_failed") }
        return response.challenge
    }

    private func post<T: Decodable>(_ path: String, payload: [String: Any]) async throws -> T {
        var request = URLRequest(url: URL(string: LicenseConfig.baseURL.absoluteString + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseFailure.network }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = (try? JSONDecoder().decode(LicenseResult.self, from: data))?.error ?? "http_\(http.statusCode)"
            throw LicenseFailure.server(apiError)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getOrCreateDeviceID() throws -> String {
        if let existing = try keychainRead(account: LicenseConfig.deviceAccount), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        try keychainSave(value, account: LicenseConfig.deviceAccount)
        return value
    }

    private func getOrCreateSigningKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = try keychainReadData(account: LicenseConfig.signingKeyAccount) {
            // Restore the previously generated Secure Enclave key from its representation.
            // accessControl is only supplied when creating a new key, not when restoring it.
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        let access = try makeKeyAccessControl()
        let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        try keychainSaveData(key.dataRepresentation, account: LicenseConfig.signingKeyAccount)
        return key
    }

    private func makeKeyAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else {
            if let underlying = error?.takeRetainedValue() { throw underlying as Error }
            throw LicenseFailure.keyStorage
        }
        return access
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: LicenseConfig.keychainService,
         kSecAttrAccount as String: account,
         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    private func keychainRead(account: String) throws -> String? {
        guard let data = try keychainReadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainReadData(account: String) throws -> Data? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LicenseFailure.keyStorage }
        return data
    }

    private func keychainSave(_ value: String, account: String) throws {
        try keychainSaveData(Data(value.utf8), account: account)
    }

    private func keychainSaveData(_ data: Data, account: String) throws {
        let query = keychainQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw LicenseFailure.keyStorage }
    }

    private func keychainDelete(account: String) throws {
        let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LicenseFailure.keyStorage }
    }
}

private enum LicenseFailure: LocalizedError {
    case network, keyStorage
    case server(String)
    var errorDescription: String? {
        switch self {
        case .network: return "Không kết nối được máy chủ License. Hãy kiểm tra Internet."
        case .keyStorage: return "Không thể truy cập Keychain hoặc Secure Enclave trên thiết bị này."
        case .server(let code):
            let messages: [String: String] = [
    "license_invalid": "License Key không tồn tại hoặc đã bị vô hiệu hóa.",
    "license_expired": "License Key đã hết hạn.",
    "device_blocked": "Thiết bị này đã bị quản trị viên khóa.",
    "device_limit_reached": "License đã đạt giới hạn thiết bị.",
    "device_already_bound": "Device ID này đã liên kết với License khác.",
    "device_key_mismatch": "Khóa bảo mật thiết bị không khớp. Hãy liên hệ quản trị viên để gỡ liên kết.",
    "device_not_registered": "Thiết bị chưa được đăng ký với License này.",
    "maintenance": "Máy chủ đang bảo trì. Không thể thực hiện Patch.",
    "server_locked": "Máy chủ đã bị khóa khẩn cấp. Không thể thực hiện Patch.",
    "patch_authorization_denied": "Máy chủ từ chối quyền thực hiện Patch.",
    "invalid_patch_action": "Hành động Patch không hợp lệ.",
    "official_ipa_required": "Bản IPA này chưa được quản trị viên duyệt. Vui lòng cài đặt IPA chính thức mới nhất."
]
            return messages[code] ?? "Xác thực thất bại: \(code)"
        }
    }
}


struct LicenseActivationView: View {
    @EnvironmentObject private var licenseManager: LicenseManager
    @State private var licenseKey = ""
    @FocusState private var keyFocused: Bool

    private let zaloAdminURL = URL(string: "https://zalo.me/0986321175")!

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.green)

                Text("KÍCH HOẠT LICENSE")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Nhập TienDatKey để xác thực thiết bị và thời hạn sử dụng.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                TextField("TIENDATKEY-XXXXXXXXXXXXXXXX", text: $licenseKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(
                        Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(.white)
                    .focused($keyFocused)

                // Zalo Admin ngay bên dưới ô nhập key
                Button {
                    keyFocused = false
                    UIApplication.shared.open(zaloAdminURL)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "message.fill")
                        Text("LIÊN HỆ ZALO ADMIN")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        Color.blue,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }

                if let message = licenseManager.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    keyFocused = false
                    Task {
                        await licenseManager.activate(licenseKey: licenseKey)
                    }
                } label: {
                    HStack {
                        if licenseManager.isBusy {
                            ProgressView().tint(.black)
                        }

                        Text(
                            licenseManager.isBusy
                                ? "ĐANG XÁC THỰC..."
                                : "KÍCH HOẠT"
                        )
                    }
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        Color.green,
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                }
                .disabled(
                    licenseManager.isBusy ||
                    licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Text("Device ID: \(licenseManager.deviceID.isEmpty ? "Đang tạo khi kích hoạt" : licenseManager.deviceID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .textSelection(.enabled)

                Text("Yêu cầu kết nối Internet để xác thực. Không hỗ trợ mở khóa offline.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(26)
        }
    }
}
