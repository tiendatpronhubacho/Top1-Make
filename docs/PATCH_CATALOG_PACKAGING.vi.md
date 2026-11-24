# Đóng gói patch không để lộ thư mục Patches trong IPA

- Xcode chỉ bundle một tài nguyên nhị phân `PatchCatalog.dat` ở cấp tài nguyên của app.
- `PatchProjectLibrary.seedBundledPackages()` đọc catalog và chép các gói `.3105` / `.3106` vào thư viện riêng của app khi chạy lần đầu.
- Thư mục `Patches/` vẫn được giữ trong source để quản lý các gói gốc; nó không còn được thêm trực tiếp vào Copy Bundle Resources.

Khi thêm hoặc thay đổi patch, chạy từ thư mục `Top1-Make`:

```bash
python3 tools/build_patch_catalog.py
```

Sau đó build IPA lại. Trong ESign, app sẽ có một file tài nguyên `PatchCatalog.dat`, không còn thư mục `Patches` chứa từng patch ở cấp ngoài. Đây là cách đóng gói/giảm hiển thị thư mục, không phải mã hóa chống trích xuất; người có công cụ phân tích app vẫn có thể đọc tài nguyên.
