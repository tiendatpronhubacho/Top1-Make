import SwiftUI
import UIKit
import AVFoundation

// MARK: - QUẢN LÝ NHẠC NỀN
class AudioManager: ObservableObject {
    static let shared = AudioManager()
    private var player: AVAudioPlayer?
    
    @Published var isPlaying: Bool = UserDefaults.standard.bool(forKey: "background_music_enabled") {
        didSet {
            UserDefaults.standard.set(isPlaying, forKey: "background_music_enabled")
            if isPlaying { play() } else { stop() }
        }
    }
    
    init() { if isPlaying { play() } }
    
    func play() {
        guard let url = Bundle.main.url(forResource: "background_music", withExtension: "mp3") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.play()
        } catch { print("Lỗi phát nhạc: \(error)") }
    }
    func stop() { player?.stop() }
}

// MARK: - CẤU HÌNH TABBAR
func configureTabBarAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = UIColor.black
    let itemAppearance = UITabBarItemAppearance()
    itemAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.5)
    itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.5)]
    itemAppearance.selected.iconColor = UIColor.white
    itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
    appearance.stackedLayoutAppearance = itemAppearance
    appearance.inlineLayoutAppearance = itemAppearance
    appearance.compactInlineLayoutAppearance = itemAppearance
    UITabBar.appearance().standardAppearance = appearance
    if #available(iOS 15.0, *) { UITabBar.appearance().scrollEdgeAppearance = appearance }
}

func loadImageFromBundle(named name: String) -> Image {
    if let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let uiImage = UIImage(contentsOfFile: url.path) { return Image(uiImage: uiImage) }
    if let url = Bundle.main.url(forResource: name, withExtension: "JPG"), let uiImage = UIImage(contentsOfFile: url.path) { return Image(uiImage: uiImage) }
    if let uiImage = UIImage(named: name) { return Image(uiImage: uiImage) }
    return Image(systemName: "photo")
}

// MARK: - CONTENT VIEW
struct ContentView: View {
    @EnvironmentObject private var licenseManager: LicenseManager

    var body: some View {
        LicensedContentView(licenseManager: licenseManager)
    }
}

// MARK: - MAIN CONTENT VIEW (3 TAB TIẾN ĐẠT)
private struct LicensedContentView: View {
    @EnvironmentObject private var appState: AppState

    @StateObject private var patchStore: PatchProjectStore
    @State private var selectedTab = 0

    init(licenseManager: LicenseManager) {
        _patchStore = StateObject(
            wrappedValue: PatchProjectStore(
                licenseManager: licenseManager
            )
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(patchStore: patchStore)
                .tabItem {
                    Label("Trang chủ", systemImage: "house")
                }
                .tag(0)

            FeaturesView(patchStore: patchStore)
                .tabItem {
                    Label("Tính năng", systemImage: "square.grid.2x2")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Cài đặt", systemImage: "gearshape")
                }
                .tag(2)
        }
        .accentColor(.white)
        .preferredColorScheme(.dark)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.black, for: .tabBar)
        .onAppear {
            configureTabBarAppearance()
            appState.detectSupport()
        }
        .sheet(
            item: $patchStore.passwordRequest,
            onDismiss: patchStore.cancelUnlock
        ) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
    }
}

// MARK: - TRANG CHỦ
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var patchStore: PatchProjectStore
    @State private var showCleaner = false
    @State private var showUnlock = false // Đã thêm biến này

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                loadImageFromBundle(named: "background_home")
                    .resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }.ignoresSafeArea()
            Color.black.opacity(0.2).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TIENDAT").font(.system(size: 25, weight: .black, design: .rounded)).tracking(3).foregroundStyle(.white)
                            Text("PATCH CONTROL CENTER").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.7).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                    }
                    
                    VStack(spacing: 0) {
                        Label("DEVICE STATUS", systemImage: "shield.lefthalf.filled").font(.system(size: 12, weight: .black, design: .rounded)).tracking(1.4).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                        statusRow(icon: "apple.logo", title: "iOS", value: AppInfo.osVersion)
                        statusRow(icon: "iphone", title: "Device", value: AppInfo.displayMachineName)
                        statusRow(icon: "checkmark.seal.fill", title: "Support", value: appState.isSupported ? "SUPPORTED" : "UNSUPPORTED", color: appState.isSupported ? .green : .red)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 0.5))

                    // NÚT UNLOCK KERNEL
                    if appState.needsUnlock {
                        Button {
                            showUnlock = true
                        } label: {
                            HStack {
                                Image(systemName: "lock.open.fill").font(.title3)
                                Text("MỞ KHÓA SANDBOX (KERNEL)").font(.system(size: 13, weight: .black, design: .rounded)).tracking(1)
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .green.opacity(0.5), radius: 10, x: 0, y: 5)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("LAUNCH GAME", systemImage: "arrow.up.forward.app.fill").font(.system(size: 12, weight: .black, design: .rounded)).tracking(1.4).foregroundStyle(.white)
                        Button { openGame(scheme: "freefirevn") } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Image(systemName: "arrow.up.right.square.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                Text("Free Fire VN").font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(.white)
                                Text("com.garena.ffvn").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                            }
                            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading).padding(.horizontal, 14)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                        
                        Button { showCleaner = true } label: {
                            Label("Clean Cache & Temp", systemImage: "trash.slash.fill")
                                .font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                    
                    HStack(spacing: 10) {
                        Circle().fill(.green).frame(width: 9, height: 9).shadow(color: .green, radius: 6)
                        Text("SISTEMA PRONTO").font(.system(size: 10, weight: .black, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.72))
                        Spacer()
                        Text("TIENDAT • PRONTO").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 13)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                    
                    VStack(spacing: 10) {
                        Text("Developed by TienDat").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.72))
                        Text("Zalo TienDat").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                        Button { UIApplication.shared.open(URL(string: "https://zalo.me/0986321175")!) } label: {
                            Label("Zalo", systemImage: "paperplane.fill").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 9).background(Color.white.opacity(0.1), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                    .padding(.top, 4).padding(.bottom, 8)
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showCleaner) { CleanerView() }
        .sheet(isPresented: $showUnlock) {
            NavigationStack {
                UnlockView()
            }
        }
    }

    private func statusRow(icon: String, title: String, value: String, color: Color = .white) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold)).foregroundStyle(color).frame(width: 24)
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value).font(.system(size: 14, weight: .black, design: .rounded)).foregroundStyle(.white)
        }.padding(.top, 14)
    }

    private func openGame(scheme: String) {
        guard let url = URL(string: "\(scheme)://") else { return }
        UIApplication.shared.open(url, options: [:])
    }
}

// MARK: - TRANG CHỨC NĂNG
struct FeaturesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var patchStore: PatchProjectStore
    @State private var currentScreen = 0
    @State private var selectedCategory: PatchCategory = .aim

    private enum PatchCategory: String, CaseIterable {
        case aim = "AIM"
        case mod = "MOD"
        case location = "ĐỊNH VỊ"

        var title: String { rawValue }
        var icon: String {
            switch self {
            case .aim: return "scope"
            case .mod: return "slider.horizontal.3"
            case .location: return "location.fill"
            }
        }
    }

    private func category(for patch: AdminPatch) -> PatchCategory {
        let name = patch.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "vi_VN")
        ).lowercased().replacingOccurrences(of: "đ", with: "d")

        // Chỉ hai patch ĐV Nhân Vật và ĐV Súng thuộc mục ĐỊNH VỊ.
        if name.contains("dv nhan vat") || name.contains("dv sung") {
            return .location
        }

        // Nhe Anten và Neck Anten là patch AIM, không phải MOD.
        if ["aim", "aimbot", "headshot", "aimlock", "tam", "body", "anten", "neck"].contains(where: { name.contains($0) }) {
            return .aim
        }

        return .mod
    }

    private func displayPatchName(_ name: String) -> String {
        let suffix = ".3105"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(suffix)
            ? String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                loadImageFromBundle(named: "background_features")
                    .resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }.ignoresSafeArea().overlay(Color.black.opacity(0.4))

            VStack(spacing: 0) {
                if currentScreen > 0 {
                    HStack {
                        Button { withAnimation { currentScreen -= 1 } } label: {
                            HStack(spacing: 6) { Image(systemName: "chevron.left"); Text(currentScreen == 1 ? "Chức năng" : "Danh mục") }
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        }
                        Spacer()
                        Text(currentScreen == 1 ? "Free Fire VN" : selectedCategory.title)
                            .font(.headline).foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.left").opacity(0)
                    }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 20)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if currentScreen == 0 {
                            Button { withAnimation { currentScreen = 1 } } label: {
                                HStack {
                                    Image(systemName: "flame.fill").font(.title2).foregroundStyle(.white)
                                    VStack(alignment: .leading) { Text("Free Fire VN").font(.headline).foregroundStyle(.white); Text("com.garena.ffvn").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                                }
                                .padding().background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                            }.buttonStyle(.plain)
                        } else if currentScreen == 1 {
                            HStack(spacing: 10) {
                                menuButton(title: "AIM", icon: "scope") {
                                    selectedCategory = .aim
                                    withAnimation { currentScreen = 2 }
                                }
                                menuButton(title: "MOD", icon: "puzzlepiece.extension") {
                                    selectedCategory = .mod
                                    withAnimation { currentScreen = 2 }
                                }
                                menuButton(title: "ĐỊNH VỊ", icon: "mappin.and.ellipse") {
                                    selectedCategory = .location
                                    withAnimation { currentScreen = 2 }
                                }
                            }
                        } else if currentScreen == 2 {
                            patchList()
                        }
                    }.padding(.horizontal, 18).padding(.bottom, 20)
                }
            }
        }
        // Custom Binding đánh chặn thông báo thành công
        .alert(item: Binding(
            get: {
                if patchStore.alert?.titleKey == "common.done" {
                    return nil // Trả về nil để SwiftUI không hiển thị popup
                }
                return patchStore.alert
            },
            set: { patchStore.alert = $0 }
        )) { alert in
            Alert(
                title: Text("Lỗi"),
                message: Text(alert.message(language: .vietnamese)),
                dismissButton: .default(Text("OK")) { patchStore.alert = nil }
            )
        }
    }

    private func categoryButton(_ category: PatchCategory) -> some View {
        let count = patchStore.adminPatches.filter { self.category(for: $0) == category }.count
        return Button {
            selectedCategory = category
            withAnimation { currentScreen = 2 }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: category.icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(count) PATCH")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func menuButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.white); Text(title).font(.headline).foregroundStyle(.white) }
                .frame(maxWidth: .infinity).frame(height: 120).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    private func patchList() -> some View {
        VStack(spacing: 10) {
            if patchStore.isBusy && patchStore.adminPatches.isEmpty {
                ProgressView("Đang tải danh sách Patch…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.vertical, 24)
            } else if patchStore.adminPatches.isEmpty {
                Text("Chưa có Patch đang bật trên Admin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.vertical, 24)
            } else {
                let filteredPatches = patchStore.adminPatches.filter {
                    category(for: $0) == selectedCategory
                }
                if filteredPatches.isEmpty {
                    Text("Chưa có Patch thuộc mục này")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.vertical, 24)
                } else {
                    ForEach(Array(filteredPatches.enumerated()), id: \.element.id) { index, patch in
                        let displayName = selectedCategory == .mod ? "Mod v\(index + 1)" : displayPatchName(patch.name)
                        patchRow(patch: patch, displayName: displayName)
                    }
                }
            }

            HStack(spacing: 8) {
                Circle().fill(patchStore.isBusy ? .orange : (patchStore.activePatchIDs.isEmpty ? .white.opacity(0.5) : .green)).frame(width: 7, height: 7)
                Text(patchStore.isBusy ? "PROCESSING PATCH…" : (patchStore.activePatchIDs.isEmpty ? "READY -- SELECT A PATCH" : "PATCH APPLIED")).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            }.padding(.horizontal, 14).padding(.vertical, 12).background(Color.white.opacity(0.1), in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5)).padding(.top, 10)
        }
    }

    private func patchRow(patch: AdminPatch, displayName: String) -> some View {
        let item = patchStore.localItem(for: patch)
        let isEnabled = patchStore.isPatchActive(patch)

        return HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                if item == nil {
                    Text("Chưa tải được gói Patch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.9))
                }
            }

            Spacer()

            Button {
                guard !patchStore.isBusy else { return }
                if isEnabled, let item {
                    patchStore.restorePatch(item)
                } else {
                    patchStore.applyAdminPatch(patch)
                }
            } label: {
                ZStack {
                    Capsule().fill(isEnabled ? Color.white : Color.white.opacity(0.2)).frame(width: 50, height: 30)
                    Circle().fill(isEnabled ? Color.black : Color.white).frame(width: 24, height: 24).offset(x: isEnabled ? 10 : -10).shadow(radius: 2)
                }
            }
            .buttonStyle(.plain)
            .disabled(patchStore.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        .opacity(patchStore.isBusy ? 0.5 : 1)
    }


}

// MARK: - CÀI ĐẶT
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var audioManager = AudioManager.shared
    @State private var showDiag = false
    @State private var showUnlock = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                loadImageFromBundle(named: "background_settings").resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }.ignoresSafeArea().overlay(Color.black.opacity(0.5))
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    HStack(spacing: 16) {
                        Image(systemName: "app.fill").font(.system(size: 30)).foregroundStyle(.white).frame(width: 60, height: 60).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                        VStack(alignment: .leading) { Text("TienDat IPA").font(.title3.bold()).foregroundStyle(.white); Text("Phiên bản 2.0").font(.subheadline).foregroundStyle(.white.opacity(0.7)) }
                        Spacer()
                    }.padding(.top, 20)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ÂM THANH").font(.caption).foregroundStyle(.white.opacity(0.5))
                        HStack { Text("Nhạc Nền").foregroundStyle(.white); Spacer(); Toggle("", isOn: $audioManager.isPlaying).tint(.white) }
                            .padding().background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("GIAO DIỆN").font(.caption).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 0) {
                            Text("Sáng").frame(maxWidth: .infinity).padding(.vertical, 10)
                            Text("Tối").frame(maxWidth: .infinity).padding(.vertical, 10).background(Color.white.opacity(0.2)).cornerRadius(8)
                            Text("Theo hệ thống").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.font(.subheadline.bold()).foregroundStyle(.white).padding(4).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("HỆ THỐNG & BẢO MẬT").font(.caption).foregroundStyle(.white.opacity(0.5))
                        
                        if appState.needsUnlock {
                            Button {
                                showUnlock = true
                            } label: {
                                HStack {
                                    Image(systemName: "lock.open.fill")
                                    Text("Mở khoá Sandbox (Kernel)")
                                    Spacer()
                                    Image(systemName: "chevron.right").opacity(0.5)
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding()
                                .background(Color.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            showDiag = true
                        } label: {
                            HStack {
                                Image(systemName: "stethoscope")
                                Text("Sandbox Diagnostics")
                                Spacer()
                                Image(systemName: "chevron.right").opacity(0.5)
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding()
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("THIẾT BỊ").font(.caption).foregroundStyle(.white.opacity(0.5))
                        VStack(spacing: 0) {
                            HStack { Text("Model phần cứng").foregroundStyle(.white); Spacer(); Text(AppInfo.displayMachineName).foregroundStyle(.white.opacity(0.7)) }.padding()
                            Divider().background(Color.white.opacity(0.2))
                            HStack { Text("Phiên bản iOS").foregroundStyle(.white); Spacer(); Text(AppInfo.osVersion).foregroundStyle(.white.opacity(0.7)) }.padding()
                        }.background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                    }
                    Spacer()
                }.padding(.horizontal, 20)
            }
        }
        .sheet(isPresented: $showDiag) { SandboxDiagnosticsView() }
        .sheet(isPresented: $showUnlock) { NavigationStack { UnlockView() } }
    }
}

// MARK: - PATCH UNLOCK PROMPT

struct PatchUnlockPrompt: View {
    @ObservedObject var store: PatchProjectStore
    @Environment(\.appLanguage) private var language
    @State private var input: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)

                Text("PATCH ĐƯỢC KHOÁ")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white)

                Text("Nhập mật khẩu để mở khoá patch này")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)

                SecureField("Mật khẩu", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
                    .foregroundStyle(.white)
                    .disabled(store.isBusy)

                if let errorKey = store.unlockErrorKey {
                    Text(language.text(errorKey))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                HStack(spacing: 12) {
                    Button {
                        store.cancelUnlock()
                    } label: {
                        Text("Huỷ")
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .disabled(store.isBusy)

                    Button {
                        store.unlock(password: input)
                    } label: {
                        Group {
                            if store.isBusy {
                                ProgressView().tint(.black)
                            } else {
                                Text("Mở khoá")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                    }
                    .disabled(input.isEmpty || store.isBusy)
                    .opacity(input.isEmpty ? 0.4 : 1)
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .padding(28)
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .onAppear { store.clearUnlockError() }
    }
}