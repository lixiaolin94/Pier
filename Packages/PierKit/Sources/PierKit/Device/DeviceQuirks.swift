import Foundation

/// 设备能力 / 怪癖档案。根据 GetDeviceInfo 推断，界面据此启用、禁用功能并提前给出提示。
///
/// DBI（Switch）的怪癖都是实测得到的，见 CONTEXT.md「增删改查稳定性」。
public struct DeviceQuirks: Sendable, Hashable {
    /// Switch 上的 DBI
    public var isDBI: Bool

    public var canDelete: Bool
    public var canRename: Bool
    public var canMove: Bool
    /// 支持 GetPartialObject64（读 4 GB 以后的数据）
    public var canReadBeyond4GB: Bool
    /// 支持 Android 编辑扩展（BeginEdit + SendPartialObject + EndEdit），可以分段上传
    public var canPartialWrite: Bool
    /// 分段上传已在这台设备上验证可靠，小于 4 GB 也优先分段（有真实进度、能取消、能给浏览让路）
    public var prefersChunkedUpload: Bool

    /// 只能改成纯 ASCII 名字（DBI：改成非 ASCII 名字返回 0x2005）
    public var renameRequiresASCII: Bool
    /// 判断重名时忽略非 ASCII 字符（DBI：`游戏.nsp` 与 `存档.nsp` 冲突）
    public var namesCollideIgnoringNonASCII: Bool
    /// 名字里含非 ASCII 字符的文件不能移动（DBI）
    public var moveRequiresASCIIFileName: Bool
    /// 移动之后设备的目录列表不会更新（DBI：已枚举过的目标文件夹里看不到移进来的文件），需要 app 自己记账
    public var listingsGoStaleAfterMove: Bool
    /// 设备列出的名字可能缺字（DBI 扫描目录时会删掉非 ASCII 字符）
    public var namesMayBeIncomplete: Bool
    /// 剩余空间是会话开始时的缓存值，不会实时更新（DBI）
    public var freeSpaceIsCached: Bool
    /// 0 字节文件不要发 SendObject：DBI 会返回 0x2002，之后这个句柄也读不到了（文件本身已由 SendObjectInfo 建好）
    public var zeroByteFilesNeedOnlyObjectInfo: Bool
    /// 删除文件夹会递归删除其中所有内容（MTP 设备普遍如此）
    public var deletesFoldersRecursively: Bool
    /// 分段上传时先用 SendObjectPropList 声明完整的 64 位大小，再从 0 开始 SendPartialObject，不发首块 SendObject。
    /// DBI：只声明首块大小时按小文件建，FAT32 卡上超过 4 GB 的部分被静默丢弃；声明完整大小后会拆分存储，7.7 GB 实测逐段一致。
    public var chunkedUploadDeclaresFullSize: Bool

    public init(deviceInfo info: PTPDeviceInfo) {
        isDBI = info.manufacturer.localizedCaseInsensitiveContains("Nintendo")
        canDelete = info.supports(.deleteObject)
        // DBI 没有在 OperationsSupported 里列出 SetObjectPropValue，但 0xDC07 实测可写
        canRename = info.supports(.setObjectPropValue) || isDBI
        canMove = info.supports(.moveObject)
        canReadBeyond4GB = info.supports(.getPartialObject64)
        canPartialWrite = info.supports(.beginEditObject) && info.supports(.sendPartialObject) && info.supports(.endEditObject)
        prefersChunkedUpload = isDBI && canPartialWrite
        renameRequiresASCII = isDBI
        namesCollideIgnoringNonASCII = isDBI
        moveRequiresASCIIFileName = isDBI
        listingsGoStaleAfterMove = isDBI
        namesMayBeIncomplete = isDBI
        freeSpaceIsCached = isDBI
        zeroByteFilesNeedOnlyObjectInfo = isDBI
        deletesFoldersRecursively = true
        chunkedUploadDeclaresFullSize = isDBI && info.supports(.sendObjectPropList)
    }

    /// DBI 的安装存储（SD Card install / NAND install）：写进去的 NSP 会被安装。
    /// 只能用一条 SendObject 发完整个文件：BeginEdit 返回 0x200E、SendPartialObject 返回 0x2005，
    /// SendObject 带的数据少于声明的大小返回 0x2002。所以超过单条指令上限（约 4 GB）的文件装不进去。
    public func isInstallTarget(_ storage: MTPStorage) -> Bool {
        isDBI && storage.displayName.localizedCaseInsensitiveContains("install")
    }

    /// 这个存储能不能用分段上传
    public func allowsChunkedUpload(to storage: MTPStorage) -> Bool {
        canPartialWrite && !isInstallTarget(storage)
    }

    // MARK: 文件名

    /// 判重用的键：不区分大小写（FAT/exFAT、Android 的 /sdcard 都不区分）；DBI 还要去掉非 ASCII 字符
    public func collisionKey(_ name: String) -> String {
        var s = name
        if namesCollideIgnoringNonASCII { s = String(s.unicodeScalars.filter(\.isASCII).map(Character.init)) }
        return s.lowercased()
    }

    /// 新建文件夹的默认名字。DBI 判重忽略非 ASCII，中文默认名会和任何同扩展名的名字冲突，所以用英文。
    public var untitledFolderName: String { renameRequiresASCII ? "untitled folder" : "未命名文件夹" }

    public enum NamePurpose: Sendable { case create, rename }

    /// 检查一个新名字是否可用。可用返回 nil，否则返回给用户看的原因。
    /// - Parameters:
    ///   - siblings: 同一文件夹里已有的名字
    ///   - original: 改名时的原名（不和自己比较）
    public func problem(with name: String, purpose: NamePurpose, siblings: [String], original: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "名称不能为空。") }
        if trimmed == "." || trimmed == ".." { return String(localized: "不能使用“\(trimmed)”作为名称。") }
        if name.contains("/") || name.contains(":") || name.contains("\\") {
            return String(localized: "名称不能包含“/”“\\”或“:”。")
        }
        if name.utf16.count > 254 { return String(localized: "名称太长。") }
        if purpose == .rename && renameRequiresASCII && !name.unicodeScalars.allSatisfy(\.isASCII) {
            return String(localized: "这台设备只支持把名称改成英文字母、数字和符号（不支持中文、emoji 等字符）。")
        }
        let key = collisionKey(name)
        for sibling in siblings where sibling != original && collisionKey(sibling) == key {
            if sibling.lowercased() == name.lowercased() {
                return String(localized: "已有名为“\(sibling)”的项目。")
            }
            return String(localized: "与“\(sibling)”冲突：这台设备判断重名时会忽略中文等非 ASCII 字符。")
        }
        return nil
    }

    /// 生成不冲突的名字（"名称 2.ext"、"名称 3.ext"…），用于"保留两者"
    public func uniqueName(for name: String, siblings: [String]) -> String {
        let keys = Set(siblings.map(collisionKey))
        if !keys.contains(collisionKey(name)) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for i in 2... {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !keys.contains(collisionKey(candidate)) { return candidate }
        }
        return name
    }
}
