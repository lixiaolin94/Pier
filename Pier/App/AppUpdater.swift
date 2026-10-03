import AppKit
#if canImport(Sparkle) && !DEBUG
import Sparkle
#endif

/// 应用内自动更新（Sparkle 2）。发版流程见 docs/RELEASE.md。
///
/// Debug 构建不含更新器：避免开发时被自动更新替换掉，也让 Debug 构建不依赖签名。
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    #if canImport(Sparkle) && !DEBUG
    private var controller: SPUStandardUpdaterController?
    #endif

    /// 启动更新器。Info.plist 里没有公钥时不启动（避免先合代码、后补密钥的构建报签名错误）。
    func start() {
        #if canImport(Sparkle) && !DEBUG
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    var isAvailable: Bool {
        #if canImport(Sparkle) && !DEBUG
        controller?.updater.canCheckForUpdates ?? false
        #else
        false
        #endif
    }

    @objc func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle) && !DEBUG
        controller?.checkForUpdates(sender)
        #endif
    }
}

extension AppUpdater: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { isAvailable }
}
