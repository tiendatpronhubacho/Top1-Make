# Tích hợp Tiến Đạt → 3106

## Nguyên tắc tích hợp

- Giữ project configuration, App.swift, entitlements, Info.plist và toàn bộ source/backend 3106.
- Giao diện chính chỉ có đúng 3 tab gốc Tiến Đạt: Trang chủ / Chức năng / Cài đặt.
- Tab Chức năng giữ giao diện AIM + MOD Tiến Đạt. Không thêm tab thứ tư, không đưa FeatureHubView hoặc menu chức năng 3106 vào giao diện chính.
- Không thêm các mục cài đặt 3106 làm thay đổi thiết kế Tiến Đạt.
- Giữ nguyên các lõi và màn hình/chức năng 3106: Sandbox, App Groups, Backup, Restore, Plist Editor, SQLite Editor và quản lý file. Không xóa service/view/backend tương ứng chỉ vì không đưa chúng thành menu mới ở giao diện chính.
- Giữ các gói patch Tiến Đạt và kết nối AIM/MOD với PatchProjectLibrary / DevicePatchService.

## Kiểm tra

- Cần build bằng Xcode/Codemagic và kiểm thử thực tế các luồng Sandbox, App Groups, Backup/Restore, Plist Editor, SQLite Editor, quản lý file và AIM/MOD.
- Không xác nhận build thành công nếu chưa có log build Xcode/Codemagic PASS.
