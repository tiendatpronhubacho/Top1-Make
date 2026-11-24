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

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: SandboxAccess.backend.displayName)
                    log("app: existing \(SandboxAccess.backend.displayName) access is still active")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
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
            let challenge = try await requestChallenge(deviceID: id, action: "register")
            let message = canonical(challenge: challenge, action: "register", deviceID: id, licenseKey: key)
            let signature = try signingKey.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
            let payload: [String: Any] = [
                "deviceId": id,
                "licenseKey": key,
                "publicKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
                "challenge": challenge,
                "signature": signature,
                "appVersion": appVersion
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
            let challenge = try await requestChallenge(deviceID: id, action: "verify")
            let message = canonical(challenge: challenge, action: "verify", deviceID: id, licenseKey: key)
            let signature = try signingKey.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
            let payload: [String: Any] = [
                "deviceId": id,
                "licenseKey": key,
                "challenge": challenge,
                "signature": signature,
                "appVersion": appVersion
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

    private func canonical(challenge: String, action: String, deviceID: String, licenseKey: String) -> String {
        "\(challenge)\n\(action)\n\(deviceID)\n\(licenseKey)"
    }

    private func requestChallenge(deviceID: String, action: String) async throws -> String {
        let response: LicenseChallenge = try await post("/v2/challenge", payload: ["deviceId": deviceID, "action": action])
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
            let access = try makeKeyAccessControl()
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, accessControl: access)
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
                "device_not_registered": "Thiết bị chưa được đăng ký với License này."
            ]
            return messages[code] ?? "Xác thực thất bại: \(code)"
        }
    }
}

struct LicenseActivationView: View {
    @EnvironmentObject private var licenseManager: LicenseManager
    @State private var licenseKey = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("KÍCH HOẠT LICENSE").font(.system(size: 23, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("Nhập License Key để xác thực thiết bị và thời hạn sử dụng.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                TextField("IPA-XXXXXXXXXXXXXXXXXXXX", text: $licenseKey)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(14).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white).focused($keyFocused)
                if let message = licenseManager.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button {
                    keyFocused = false
                    Task { await licenseManager.activate(licenseKey: licenseKey) }
                } label: {
                    HStack {
                        if licenseManager.isBusy { ProgressView().tint(.black) }
                        Text(licenseManager.isBusy ? "ĐANG XÁC THỰC..." : "KÍCH HOẠT")
                    }
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(licenseManager.isBusy || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Device ID: \(licenseManager.deviceID.isEmpty ? "Đang tạo khi kích hoạt" : licenseManager.deviceID)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).textSelection(.enabled)
                Text("Yêu cầu kết nối Internet để xác thực. Không hỗ trợ mở khóa offline.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
            }
            .padding(26)
        }
    }
}