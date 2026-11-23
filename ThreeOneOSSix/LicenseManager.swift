import Foundation
import Combine

/// Quản lý trạng thái bản quyền.
/// Stub tối thiểu để build pass; thay logic thật khi cần.
final class LicenseManager: ObservableObject {
    @Published var isLicensed: Bool = true
    @Published var licenseStatus: String = "active"
    @Published var licenseeName: String? = nil
    @Published var expiresAt: Date? = nil

    init() {}

    func refresh() {
        // TODO: gọi backend / đọc keychain
    }

    func validate() -> Bool {
        isLicensed
    }
}