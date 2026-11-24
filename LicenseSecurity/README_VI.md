# VipProIPA – License v2 Secure

## Các thay đổi đã chuẩn bị
- App dùng LicenseManager trong `ThreeOneOSSix/App.swift`.
- Bổ sung import `CryptoKit` và `Security` cho ECDSA P-256, Secure Enclave và Keychain.
- Worker dùng challenge một lần, chữ ký ECDSA P-256 và lưu public key theo thiết bị.
- Sửa thao tác thu hồi License: dùng trạng thái `blocked` (không dùng `revoked`) để tương thích CHECK constraint của database hiện tại (`active`, `blocked`).
- Migration chỉ tạo `license_challenges` và index. Cột `devices.public_key` đã được thêm trên D1 theo thao tác đã thực hiện; không chạy ALTER TABLE lần nữa.

## Cấu hình Worker
- D1 binding: tên `DB`, trỏ đúng database `ipa-device-db`.
- Secret: `ADMIN_TOKEN` phải tồn tại.
- Deploy `worker_secure.js` sau khi xác nhận hai cấu hình trên.
- Health: `/health`; Admin: `/admin`.

## Database
Migration hiện tại: `migration_v2.sql`.
Nó có thể chạy lại an toàn vì dùng `IF NOT EXISTS`. Không chạy lại câu `ALTER TABLE ... ADD COLUMN public_key` vì cột đó đã tồn tại.

## Build IPA
Mở `ThreeOneOSSix.xcodeproj` bằng Xcode, kiểm tra Signing Team / Bundle ID / provisioning profile rồi build lại IPA. Gói ZIP này là mã nguồn, không phải IPA đã build và ký.

## Giới hạn đã biết
- Cơ chế ký thiết bị dùng Secure Enclave P-256; thiết bị không hỗ trợ Secure Enclave sẽ báo lỗi Keychain/Secure Enclave.
- Đây không phải App Attest. Provisioning profile cần entitlement App Attest riêng mới có thể triển khai App Attest.
- Ứng dụng xác thực online và fail-closed khi không kết nối được máy chủ.
- Chưa thể xác nhận build Xcode hoặc cài đặt trên thiết bị thực trong môi trường này.
