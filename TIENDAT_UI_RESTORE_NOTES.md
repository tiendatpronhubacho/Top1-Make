# Tiến Đạt 3-tab UI restoration

- Keep exactly the original Tiến Đạt three-tab shell: Trang chủ / Chức năng / Cài đặt.
- Keep the original Tiến Đạt AIM + MOD presentation in the Chức năng tab.
- Do not add a fourth tab, FeatureHubView, a 3106 feature menu to the main interface, or new 3106 settings rows that alter the Tiến Đạt design.
- Keep the 3106 implementation files, services, entitlements, App Groups, Sandbox, Backup/Restore, Plist Editor, SQLite Editor, and file-management code in the project. Do not delete those modules while restoring the presentation.
- The Settings tab retains the Tiến Đạt settings presentation; the added Sandbox Diagnostics row/sheet entry was removed from this screen. The Sandbox diagnostics implementation itself remains in the project.
- The AIM/MOD list remains connected to the 3106 patch library and DevicePatchService apply/restore entry points.

**Build status:** not compiled in this environment. Build with Xcode/Codemagic and test the preserved 3106 core flows on-device before release.
