// ptpspike — 方案 A 可行性验证：ImageCaptureCore + requestSendPTPCommand 操作 DBI（MTP）
//
// 用法（swift run ptpspike <cmd> ...，数字参数支持 0x 前缀）：
//   info                               设备、capabilities、DeviceInfo、存储列表
//   ls <storage> [parent] [depth]      列目录（parent 默认根目录 0xFFFFFFFF）
//   props <handle>                     读 MTP 对象属性（含 64 位 ObjectSize）
//   media                              对照：ICCameraDevice 自带的 contents / mediaFiles
//   read <handle> <chunkMB> [maxMB]    GetPartialObject(64) 分块读取测速（不落盘）；START_MB 指定起始偏移
//   write <storage> <parent> [sizeKB]  在 parent 下建 SwitchMTP-spike 目录并单次 SendObject 写入测试文件
//                                      （SRC_FILE 指定时 mmap 该文件作为数据）
//   pwrite <storage> <dir> <chunkMB>   分段写：SendObject 首块 + SendPartialObject(0x95C2)，dir 必须是测试目录
//   cmp <handle> <offsetMB...>         比对设备端与 SRC_FILE 在各偏移处的 1 MB
//   crud <storage> <testDir> <n>       增删改查稳定性测试（只在 testDir 下的 crud-* 子目录里操作）
//   install <storage> <A|B|C> <chunkMB>  往安装存储写 >4 GB 文件（SRC_FILE）。A：SendObjectPropList 声明 64 位大小 +
//                                      SendPartialObject 从 0 写；B：SendObjectInfo 大小填 0xFFFFFFFF + 分段；
//                                      C：SendObjectPropList + 首块 SendObject + 分段。NAME_PROP=0xDC44 换文件名属性
//   rmtest <storage> <testDir>         递归删除 SwitchMTP-spike 测试目录（有名字/位置保护）
//
// 环境变量：PTP_VERBOSE=1 打印每条指令的原始收发；LS_MAX 限制 ls 输出条数。
// 运行前先退出 Android File Transfer，让 ptpcamerad 持有设备。

import Foundation
import ImageCaptureCore

// MARK: - PTP 编解码

enum Op {
    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let getStorageIDs: UInt16 = 0x1004
    static let getStorageInfo: UInt16 = 0x1005
    static let getObjectHandles: UInt16 = 0x1007
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let sendObjectInfo: UInt16 = 0x100C
    static let sendObject: UInt16 = 0x100D
    static let getPartialObject: UInt16 = 0x101B
    static let getPartialObject64: UInt16 = 0x95C1
    static let sendPartialObject: UInt16 = 0x95C2
    static let beginEditObject: UInt16 = 0x95C4
    static let endEditObject: UInt16 = 0x95C5
    static let getObjectPropsSupported: UInt16 = 0x9801
    static let getObjectPropDesc: UInt16 = 0x9802
    static let getObjectPropValue: UInt16 = 0x9803
    static let getObjectPropList: UInt16 = 0x9805
    static let sendObjectPropList: UInt16 = 0x9808
}

struct Reader {
    let d: [UInt8]
    var i = 0
    init(_ data: Data) { d = [UInt8](data) }
    var remaining: Int { d.count - i }
    mutating func u8() -> UInt8 { defer { i += 1 }; return i < d.count ? d[i] : 0 }
    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
    mutating func str() -> String {
        let n = Int(u8())
        guard n > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0..<n { units.append(u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    mutating func arr16() -> [UInt16] { (0..<Int(u32())).map { _ in u16() } }
    mutating func arr32() -> [UInt32] { (0..<Int(u32())).map { _ in u32() } }
}

struct Writer {
    var d = Data()
    mutating func u8(_ v: UInt8) { d.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func str(_ s: String) {
        guard !s.isEmpty else { u8(0); return }
        let units = Array(s.utf16) + [0]
        u8(UInt8(units.count))
        units.forEach { u16($0) }
    }
}

func hex(_ v: some BinaryInteger, _ w: Int = 4) -> String {
    "0x" + String(v, radix: 16, uppercase: true).leftPad(w)
}
extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
func parseNum(_ s: String) -> UInt64 {
    s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16)! : UInt64(s)!
}
func mb(_ bytes: Int, _ secs: Double) -> String { String(format: "%.2f MB/s", Double(bytes) / 1_048_576 / secs) }

final class Box: @unchecked Sendable { var value = false }

struct PTPResponse {
    let code: UInt16
    let params: [UInt32]
    let data: Data
}

struct PTPError: Error, CustomStringConvertible {
    let description: String
    var code: UInt16 = 0   // 设备返回的 response code；0 表示非设备错误
}

// MARK: - 设备会话

@MainActor
final class Spike: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var txid: UInt32 = 1
    var foundCont: CheckedContinuation<ICCameraDevice, Error>?
    var sessionCont: CheckedContinuation<Void, Error>?
    var readyCont: CheckedContinuation<Void, Never>?
    var isReady = false
    var verbose = ProcessInfo.processInfo.environment["PTP_VERBOSE"] != nil

    func findDBI(timeout: Double = 15) async throws -> ICCameraDevice {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
        print("ICDeviceBrowser 已启动，mask=\(hex(mask, 8))，等待设备…")
        return try await withCheckedThrowingContinuation { c in
            foundCont = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.foundCont else { return }
                self.foundCont = nil
                c.resume(throwing: PTPError(description: "\(Int(timeout)) 秒内没发现 DBI。请在 Switch 上打开 DBI → MTP responder 并插好数据线。"))
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            print("发现设备：name=\(device.name ?? "?") type=\(hex(device.type.rawValue, 8)) class=\(Swift.type(of: device)) transport=\(device.transportType ?? "?") usbVID=\(hex(device.usbVendorID)) usbPID=\(hex(device.usbProductID))")
            guard device.usbVendorID == 0x057E, device.usbProductID == 0x201D else { return }
            guard let cam = device as? ICCameraDevice else {
                print("⚠️ DBI 不是 ICCameraDevice"); return
            }
            if let c = foundCont { foundCont = nil; c.resume(returning: cam) }
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated { print("设备移除：\(device.name ?? "?")") }
    }

    func open(_ cam: ICCameraDevice, waitReady: Double) async throws {
        camera = cam
        cam.delegate = self
        print("capabilities: \(cam.capabilities)")
        print("serial: \(cam.serialNumberString ?? "?")  productKind: \(cam.productKind ?? "?")  locationDescription: \(cam.locationDescription ?? "?")")
        let t0 = Date()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sessionCont = c
            cam.requestOpenSession()
        }
        print(String(format: "会话已打开（%.2fs）", Date().timeIntervalSince(t0)))
        if waitReady > 0 && !isReady {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                readyCont = c
                DispatchQueue.main.asyncAfter(deadline: .now() + waitReady) { [weak self] in
                    guard let self, let c = self.readyCont else { return }
                    self.readyCont = nil
                    print("⏱ \(Int(waitReady))s 内未收到 deviceDidBecomeReady（catalog \(cam.contentCatalogPercentCompleted)%），继续")
                    c.resume()
                }
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let c = sessionCont else { return }
            sessionCont = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated {
            print("deviceDidBecomeReady（完整 content catalog）")
            isReady = true
            if let c = readyCont { readyCont = nil; c.resume() }
        }
    }
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated { print("会话关闭 error=\(String(describing: error))") }
    }
    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated { print("didRemove device") }
    }
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        MainActor.assumeIsolated { print("device error: \(String(describing: error))") }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        MainActor.assumeIsolated { print("PTP event: \(eventData as NSData)") }
    }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    // MARK: PTP 指令

    /// 发送一条 PTP 指令。command 按 PTP USB container（type=1）组包；返回解析后的 response。
    func send(_ code: UInt16, _ params: [UInt32] = [], out: Data? = nil) async throws -> PTPResponse {
        guard let cam = camera else { throw PTPError(description: "no camera") }
        var w = Writer()
        w.u32(UInt32(12 + 4 * params.count))
        w.u16(1)
        w.u16(code)
        w.u32(txid)
        txid += 1
        params.forEach { w.u32($0) }
        let cmd = w.d
        // 看门狗：单条指令超过 CMD_TIMEOUT 秒（默认 60）没回应就判定设备挂起，直接退出
        let done = Box()
        let limit = Double(ProcessInfo.processInfo.environment["CMD_TIMEOUT"] ?? "60")!
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            if !done.value { print("❌ 指令 \(hex(code)) \(params.map { hex($0, 8) }) 超过 \(Int(limit))s 无响应，设备疑似挂起"); exit(3) }
        }
        defer { done.value = true }
        let (resp, data): (Data, Data) = try await withCheckedThrowingContinuation { c in
            cam.requestSendPTPCommand(cmd, outData: out) { respData, ptpRespData, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: (ptpRespData, respData)) }
            }
        }
        // 注：completion 的第一个参数是数据阶段（inData），第二个是 response container
        var r = Reader(resp)
        let len = r.u32(), type = r.u16(), rc = r.u16(), _ = r.u32()
        var ps: [UInt32] = []
        while r.i + 4 <= min(Int(len), resp.count) { ps.append(r.u32()) }
        if verbose {
            print("  → \(hex(code)) \(params.map { hex($0, 8) }) out=\(out?.count ?? 0)B | resp len=\(len) type=\(type) code=\(hex(rc)) params=\(ps.map { hex($0, 8) }) data=\(data.count)B head=\((data.prefix(16) as NSData))")
        }
        guard rc == 0x2001 else {
            throw PTPError(description: "指令 \(hex(code)) 失败，response=\(hex(rc))", code: rc)
        }
        return PTPResponse(code: rc, params: ps, data: data)
    }

    /// 数据阶段如果带了 12 字节 container 头（type=2），去掉它
    func payload(_ d: Data, expectCode code: UInt16) -> Data {
        guard d.count >= 12 else { return d }
        var r = Reader(d)
        let len = r.u32(), type = r.u16(), c = r.u16()
        if type == 2 && c == code && Int(len) == d.count { return d.dropFirst(12) }
        return d
    }

    func cmd(_ code: UInt16, _ params: [UInt32] = [], out: Data? = nil) async throws -> (PTPResponse, Data) {
        let r = try await send(code, params, out: out)
        return (r, payload(r.data, expectCode: code))
    }
}

// MARK: - 数据集

struct DeviceInfo {
    var std: UInt16 = 0, vendorExt: UInt32 = 0, vendorExtVer: UInt16 = 0, vendorExtDesc = ""
    var ops: [UInt16] = [], events: [UInt16] = [], props: [UInt16] = []
    var captureFormats: [UInt16] = [], imageFormats: [UInt16] = []
    var manufacturer = "", model = "", version = "", serial = ""
    init(_ d: Data) {
        var r = Reader(d)
        std = r.u16(); vendorExt = r.u32(); vendorExtVer = r.u16(); vendorExtDesc = r.str()
        _ = r.u16()
        ops = r.arr16(); events = r.arr16(); props = r.arr16()
        captureFormats = r.arr16(); imageFormats = r.arr16()
        manufacturer = r.str(); model = r.str(); version = r.str(); serial = r.str()
    }
}

struct StorageInfo {
    var type: UInt16, fs: UInt16, access: UInt16, max: UInt64, free: UInt64, desc: String, label: String
    init(_ d: Data) {
        var r = Reader(d)
        type = r.u16(); fs = r.u16(); access = r.u16(); max = r.u64(); free = r.u64(); _ = r.u32()
        desc = r.str(); label = r.str()
    }
}

struct ObjectInfo {
    var storage: UInt32, format: UInt16, size32: UInt32, parent: UInt32, assocType: UInt16
    var name: String, modified: String
    var isDir: Bool { format == 0x3001 }
    init(_ d: Data) {
        var r = Reader(d)
        storage = r.u32(); format = r.u16(); _ = r.u16(); size32 = r.u32()
        _ = r.u16(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32()
        parent = r.u32(); assocType = r.u16(); _ = r.u32(); _ = r.u32()
        name = r.str(); _ = r.str(); modified = r.str()
    }
}

let propNames: [UInt16: String] = [
    0xDC01: "StorageID", 0xDC02: "ObjectFormat", 0xDC03: "ProtectionStatus", 0xDC04: "ObjectSize",
    0xDC07: "ObjectFileName", 0xDC08: "DateCreated", 0xDC09: "DateModified", 0xDC0B: "ParentObject",
    0xDC41: "PersistentUID", 0xDC44: "Name", 0xDC4E: "DateAdded",
]

// MARK: - 子命令

extension Spike {
    func info() async throws {
        let (_, d) = try await cmd(Op.getDeviceInfo)
        let di = DeviceInfo(d)
        print("== GetDeviceInfo (\(d.count)B) ==")
        print("StandardVersion=\(di.std) VendorExt=\(hex(di.vendorExt, 8)) v\(di.vendorExtVer) desc=\"\(di.vendorExtDesc)\"")
        print("Manufacturer=\(di.manufacturer) Model=\(di.model) Version=\(di.version) Serial=\(di.serial)")
        print("OperationsSupported(\(di.ops.count)): \(di.ops.map { hex($0) }.joined(separator: " "))")
        print("EventsSupported: \(di.events.map { hex($0) }.joined(separator: " "))")
        print("DevicePropsSupported: \(di.props.map { hex($0) }.joined(separator: " "))")
        print("ImageFormats(\(di.imageFormats.count)): \(di.imageFormats.map { hex($0) }.joined(separator: " "))")
        for (op, n) in [(Op.getPartialObject, "GetPartialObject"), (Op.getPartialObject64, "GetPartialObject64"),
                        (Op.sendObjectInfo, "SendObjectInfo"), (Op.sendObject, "SendObject"),
                        (Op.getObjectPropValue, "GetObjectPropValue"), (Op.getObjectPropList, "GetObjectPropList")] {
            print("  支持 \(n)(\(hex(op)))? \(di.ops.contains(op) ? "是" : "否")")
        }

        let (_, sd) = try await cmd(Op.getStorageIDs)
        var r = Reader(sd)
        let ids = r.arr32()
        print("== GetStorageIDs: \(ids.map { hex($0, 8) }) ==")
        for id in ids {
            do {
                let (_, s) = try await cmd(Op.getStorageInfo, [id])
                let si = StorageInfo(s)
                print("  \(hex(id, 8)) desc=\"\(si.desc)\" label=\"\(si.label)\" type=\(si.type) fs=\(si.fs) access=\(si.access) max=\(si.max / 1_048_576)MB free=\(si.free / 1_048_576)MB")
            } catch { print("  \(hex(id, 8)) GetStorageInfo 失败: \(error)") }
        }
    }

    func objectSize(_ h: UInt32) async throws -> UInt64 {
        let (_, d) = try await cmd(Op.getObjectPropValue, [h, 0xDC04])
        var r = Reader(d)
        return r.u64()
    }

    func ls(storage: UInt32, parent: UInt32, depth: Int, indent: String = "", budget: inout Int) async throws {
        let (_, d) = try await cmd(Op.getObjectHandles, [storage, 0, parent])
        var r = Reader(d)
        let hs = r.arr32()
        for h in hs {
            guard budget > 0 else { print("\(indent)…（达到输出上限）"); return }
            budget -= 1
            let (_, od) = try await cmd(Op.getObjectInfo, [h])
            let oi = ObjectInfo(od)
            var sizeDesc = "\(oi.size32)"
            if !oi.isDir {
                if let s = try? await objectSize(h) { sizeDesc = "\(s)\(oi.size32 == 0xFFFF_FFFF ? " (ObjectInfo=0xFFFFFFFF)" : "")" }
            }
            print("\(indent)\(oi.isDir ? "📁" : "📄") \(oi.name)  h=\(hex(h, 8)) fmt=\(hex(oi.format)) size=\(oi.isDir ? "-" : sizeDesc) mod=\(oi.modified)")
            if oi.isDir && depth > 1 {
                try await ls(storage: storage, parent: h, depth: depth - 1, indent: indent + "    ", budget: &budget)
            }
        }
    }

    func props(_ h: UInt32) async throws {
        let (_, od) = try await cmd(Op.getObjectInfo, [h])
        let oi = ObjectInfo(od)
        print("ObjectInfo: name=\(oi.name) fmt=\(hex(oi.format)) size32=\(oi.size32) parent=\(hex(oi.parent, 8)) storage=\(hex(oi.storage, 8))")
        let (_, sd) = try await cmd(Op.getObjectPropsSupported, [UInt32(oi.format)])
        var r = Reader(sd)
        let ps = r.arr16()
        print("GetObjectPropsSupported(fmt \(hex(oi.format))): \(ps.map { "\(hex($0))\(propNames[$0].map { "(\($0))" } ?? "")" }.joined(separator: " "))")
        for p in ps {
            do {
                let (_, vd) = try await cmd(Op.getObjectPropValue, [h, UInt32(p)])
                var vr = Reader(vd)
                let v: String
                switch p {
                case 0xDC04: v = "\(vr.u64()) (u64)"
                case 0xDC01, 0xDC0B: v = hex(vr.u32(), 8)
                case 0xDC02, 0xDC03: v = hex(vr.u16())
                case 0xDC07, 0xDC08, 0xDC09, 0xDC44, 0xDC4E: v = "\"\(vr.str())\""
                default: v = "\(vd as NSData)"
                }
                print("  \(hex(p)) \(propNames[p] ?? "?") = \(v)")
            } catch { print("  \(hex(p)) 读取失败: \(error)") }
        }
        do {
            // GetObjectPropList(handle, format=0, prop=0xFFFFFFFF 全部, group=0, depth=0)
            let (_, ld) = try await cmd(Op.getObjectPropList, [h, 0, 0xFFFF_FFFF, 0, 0])
            var lr = Reader(ld)
            print("GetObjectPropList: \(lr.u32()) 个元素，\(ld.count)B")
        } catch { print("GetObjectPropList 失败: \(error)") }
    }

    func media() {
        guard let cam = camera else { return }
        print("contents（顶层 \(cam.contents?.count ?? 0) 项）:")
        func walk(_ items: [ICCameraItem], _ ind: String, _ depth: Int) {
            for it in items.prefix(30) {
                let f = it as? ICCameraFile
                print("\(ind)\(it is ICCameraFolder ? "📁" : "📄") \(it.name ?? "?") \(f.map { "size=\($0.fileSize)" } ?? "") UTI=\(it.uti ?? "?")")
                if let folder = it as? ICCameraFolder, depth > 1, let c = folder.contents { walk(c, ind + "    ", depth - 1) }
            }
            if items.count > 30 { print("\(ind)…共 \(items.count) 项") }
        }
        walk(cam.contents ?? [], "  ", 3)
        print("mediaFiles: \(cam.mediaFiles?.count ?? 0) 项")
        for f in (cam.mediaFiles ?? []).prefix(10) { print("  \(f.name ?? "?")") }
    }

    func read(_ h: UInt32, chunk: Int, maxBytes: UInt64) async throws {
        // START_MB：从指定偏移开始读，用来验证 >4 GB 偏移的 GetPartialObject64
        let start = UInt64(ProcessInfo.processInfo.environment["START_MB"] ?? "0")! * 1_048_576
        let size = try await objectSize(h)
        let total = min(size, start &+ maxBytes)
        let (_, od) = try await cmd(Op.getObjectInfo, [h])
        print("读取 \(ObjectInfo(od).name)（共 \(size) 字节）：偏移 \(start) → \(total)，chunk=\(chunk / 1_048_576)MB")
        var off: UInt64 = start
        let t0 = Date()
        var lastPrint = t0
        var lastOff: UInt64 = start
        var lat: [Double] = []
        while off < total {
            let n = UInt32(min(UInt64(chunk), total - off))
            let ts = Date()
            let d: Data
            if off + UInt64(n) <= 0xFFFF_FFFF && ProcessInfo.processInfo.environment["FORCE64"] == nil {
                d = try await cmd(Op.getPartialObject, [h, UInt32(off), n]).1
            } else {
                // 超过 4 GB 只能用 Android 扩展 GetPartialObject64(handle, offLo, offHi, len)
                d = try await cmd(Op.getPartialObject64, [h, UInt32(off & 0xFFFF_FFFF), UInt32(off >> 32), n]).1
            }
            lat.append(Date().timeIntervalSince(ts))
            guard d.count == Int(n) else { throw PTPError(description: "期望 \(n)B，收到 \(d.count)B @ \(off)") }
            off += UInt64(d.count)
            if Date().timeIntervalSince(lastPrint) > 2 {
                print("  \(off / 1_048_576)MB  瞬时 \(mb(Int(off - lastOff), Date().timeIntervalSince(lastPrint)))")
                lastPrint = Date(); lastOff = off
            }
        }
        let dt = Date().timeIntervalSince(t0)
        lat.sort()
        off -= start
        print(String(format: "完成：%llu 字节 / %.2fs = %@，单块延迟 中位 %.1fms，最大 %.1fms", off, dt, mb(Int(off), dt), lat[lat.count / 2] * 1000, lat.last! * 1000))
    }

    func write(storage: UInt32, parent: UInt32, sizeKB: Int) async throws {
        // 1) 建目录 SwitchMTP-spike（Association）
        func objectInfo(name: String, format: UInt16, size: UInt32, assoc: UInt16) -> Data {
            var w = Writer()
            w.u32(storage); w.u16(format); w.u16(0); w.u32(size)
            w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
            w.u32(parent); w.u16(assoc); w.u32(0); w.u32(0)
            w.str(name); w.str(""); w.str(""); w.str("")
            return w.d
        }
        var dirParent = parent
        let (_, hd) = try await cmd(Op.getObjectHandles, [storage, 0, parent])
        var hr = Reader(hd)
        for h in hr.arr32() {
            let oi = ObjectInfo(try await cmd(Op.getObjectInfo, [h]).1)
            if oi.isDir && oi.name == "SwitchMTP-spike" { dirParent = h; print("测试目录已存在 h=\(hex(h, 8))") }
        }
        if dirParent == parent {
            let r = try await cmd(Op.sendObjectInfo, [storage, parent], out: objectInfo(name: "SwitchMTP-spike", format: 0x3001, size: 0, assoc: 1)).0
            print("SendObjectInfo(目录) 成功，response params=\(r.params.map { hex($0, 8) })")
            dirParent = r.params.count >= 3 ? r.params[2] : 0
        }
        // 2) 写测试文件：小文件用内存数据；SRC_FILE 指定时用 mmap 映射的本地文件（测大文件 / >4 GB）
        let payload: Data
        if let src = ProcessInfo.processInfo.environment["SRC_FILE"] {
            payload = try Data(contentsOf: URL(fileURLWithPath: src), options: .alwaysMapped)
        } else {
            let n = sizeKB * 1024
            var d = Data(count: n)
            d.withUnsafeMutableBytes { p in for i in 0..<n { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) } }
            payload = d
        }
        let size = payload.count
        let fname = "spike-\(Int(Date().timeIntervalSince1970)).bin"
        var w = Writer()
        w.u32(storage); w.u16(0x3000); w.u16(0); w.u32(UInt32(min(size, 0xFFFF_FFFF)))
        w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.u32(dirParent); w.u16(0); w.u32(0); w.u32(0)
        w.str(fname); w.str(""); w.str(""); w.str("")
        let r = try await cmd(Op.sendObjectInfo, [storage, dirParent], out: w.d).0
        print("SendObjectInfo(文件 \(fname), \(size)B) 成功，response params=\(r.params.map { hex($0, 8) })")
        let newHandle = r.params.count >= 3 ? r.params[2] : 0
        let t0 = Date()
        _ = try await cmd(Op.sendObject, [], out: payload)
        let dt = Date().timeIntervalSince(t0)
        print("SendObject \(size)B 成功：\(String(format: "%.3fs", dt)) = \(mb(size, dt))")
        // 3) 回读校验：小文件整体比对；大文件比对 64 位大小 + 末尾 1 MB
        guard newHandle != 0 else { return }
        if size <= 64 * 1_048_576 {
            let back = try await cmd(Op.getObject, [newHandle]).1
            print("回读 GetObject: \(back.count)B，内容\(back == payload ? "一致 ✅" : "不一致 ❌")")
        } else {
            let devSize = try await objectSize(newHandle)
            let tail = UInt64(min(size, 1_048_576)), off = UInt64(size) - tail
            let back = try await cmd(Op.getPartialObject64, [newHandle, UInt32(off & 0xFFFF_FFFF), UInt32(off >> 32), UInt32(tail)]).1
            let expect = payload.subdata(in: Int(off)..<size)
            print("回读：设备端 ObjectSize=\(devSize)（\(devSize == UInt64(size) ? "一致 ✅" : "不一致 ❌")），末尾 1MB \(back == expect ? "一致 ✅" : "不一致 ❌")")
        }
    }
}

extension Spike {
    /// 分段写：SendObject 写首块建对象，之后 BeginEditObject + SendPartialObject(64 位偏移) + EndEditObject。
    /// 用来绕过 ImageCaptureCore 单条 XPC 消息 ≤ 4 GB−1 的限制。只往 SwitchMTP-spike 测试目录写。
    func pwrite(storage: UInt32, dir: UInt32, chunk: Int) async throws {
        guard let src = ProcessInfo.processInfo.environment["SRC_FILE"] else { throw PTPError(description: "需要 SRC_FILE") }
        let file = try Data(contentsOf: URL(fileURLWithPath: src), options: .alwaysMapped)
        let size = ProcessInfo.processInfo.environment["LIMIT_MB"].map { min(file.count, Int($0)! * 1_048_576) } ?? file.count
        let (_, nd) = try await cmd(Op.getObjectInfo, [dir])
        let dirInfo = ObjectInfo(nd)
        guard dirInfo.isDir, dirInfo.name == "SwitchMTP-spike" else { throw PTPError(description: "目标必须是 SwitchMTP-spike 测试目录，实际是 \(dirInfo.name)") }
        let first = min(chunk, size)
        let fname = "spike-partial-\(Int(Date().timeIntervalSince1970)).bin"
        var w = Writer()
        w.u32(storage); w.u16(0x3000); w.u16(0); w.u32(UInt32(first))
        w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.u32(dir); w.u16(0); w.u32(0); w.u32(0)
        w.str(fname); w.str(""); w.str(""); w.str("")
        let r = try await cmd(Op.sendObjectInfo, [storage, dir], out: w.d).0
        let h = r.params[2]
        let t0 = Date()
        _ = try await cmd(Op.sendObject, [], out: file.subdata(in: 0..<first))
        print("首块 SendObject \(first)B OK，handle=\(hex(h, 8))，共 \(size)B")
        _ = try await cmd(Op.beginEditObject, [h])
        var off = first
        var lastPrint = Date()
        while off < size {
            let n = min(chunk, size - off)
            let o = UInt64(off)
            _ = try await cmd(Op.sendPartialObject, [h, UInt32(o & 0xFFFF_FFFF), UInt32(o >> 32), UInt32(n)], out: file.subdata(in: off..<(off + n)))
            off += n
            if Date().timeIntervalSince(lastPrint) > 5 { print("  \(off / 1_048_576)MB  平均 \(mb(off, Date().timeIntervalSince(t0)))"); lastPrint = Date() }
        }
        _ = try await cmd(Op.endEditObject, [h])
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "分段写完成：%lld 字节 / %.2fs = %@", size, dt, mb(size, dt)))
        let devSize = try await objectSize(h)
        let tail = min(size, 1_048_576), toff = UInt64(size - tail)
        let back = try await cmd(Op.getPartialObject64, [h, UInt32(toff & 0xFFFF_FFFF), UInt32(toff >> 32), UInt32(tail)]).1
        let mid = UInt64(size / 2) & ~0xFFFF
        let backMid = try await cmd(Op.getPartialObject64, [h, UInt32(mid & 0xFFFF_FFFF), UInt32(mid >> 32), 65536]).1
        print("回读：ObjectSize=\(devSize)（\(devSize == UInt64(size) ? "一致 ✅" : "不一致 ❌")），末尾 1MB \(back == file.subdata(in: Int(toff)..<size) ? "一致 ✅" : "不一致 ❌")，中段 64KB \(backMid == file.subdata(in: Int(mid)..<Int(mid) + 65536) ? "一致 ✅" : "不一致 ❌")")
    }

    // MARK: 安装存储写大文件

    func install(storage: UInt32, variant: String, chunk: Int) async throws {
        guard let src = ProcessInfo.processInfo.environment["SRC_FILE"] else { throw PTPError(description: "需要 SRC_FILE") }
        // 允许：5: SD Card install 根目录；或 1: SD Card 的 SwitchMTP-spike 测试目录（PARENT 指定）
        var root: UInt32 = 0xFFFF_FFFF
        if storage == 0x0001_0001, let p = ProcessInfo.processInfo.environment["PARENT"] {
            root = UInt32(parseNum(p))
            try await verifyTestDir(storage, root)
        } else {
            guard storage == 0x0001_0005 else { throw PTPError(description: "只允许写 5: SD Card install 或 SD 卡测试目录") }
        }
        let url = URL(fileURLWithPath: src)
        let fh = try FileHandle(forReadingFrom: url)
        let size = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        let name = url.lastPathComponent
        print("文件 \(name)，\(size) 字节，方式 \(variant)，每段 \(chunk >> 20) MB")

        func propList() -> Data {
            var w = Writer()
            let nameProp = UInt16(parseNum(ProcessInfo.processInfo.environment["NAME_PROP"] ?? "0xDC07"))
            w.u32(1)
            w.u32(0); w.u16(nameProp); w.u16(0xFFFF); w.str(name)
            return w.d
        }
        var h: UInt32
        if let reuse = ProcessInfo.processInfo.environment["HANDLE"] {
            h = UInt32(parseNum(reuse))
        } else if variant == "B" {
            var w = Writer()
            w.u32(storage); w.u16(0x3000); w.u16(0); w.u32(0xFFFF_FFFF)
            w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
            w.u32(root); w.u16(0); w.u32(0); w.u32(0)
            w.str(name); w.str(""); w.str(""); w.str("")
            h = try await cmd(Op.sendObjectInfo, [storage, root], out: w.d).0.params[2]
        } else {
            let r = try await cmd(Op.sendObjectPropList, [storage, root, 0x3000, UInt32(size >> 32), UInt32(size & 0xFFFF_FFFF)], out: propList()).0
            print("SendObjectPropList 响应参数 \(r.params.map { hex($0, 8) })")
            h = r.params[2]
        }
        print("新对象 handle=\(hex(h, 8))")

        var off: UInt64 = 0
        let t0 = Date()
        if variant == "C" || variant == "B" {
            let first = try fh.read(upToCount: chunk)!
            _ = try await cmd(Op.sendObject, [], out: first)
            off = UInt64(first.count)
            print("首块 SendObject \(first.count) 字节 OK")
            if ProcessInfo.processInfo.environment["STOP_AFTER_FIRST"] != nil {
                try? await Task.sleep(for: .seconds(8))
                let sz = try? await objectSize(h)
                print("8 秒后对象大小：\(sz.map(String.init) ?? "对象已不存在")")
                return
            }
        }
        let edit = ProcessInfo.processInfo.environment["SKIP_EDIT"] == nil
        if edit { _ = try await cmd(Op.beginEditObject, [h]) }
        try fh.seek(toOffset: off)
        var lastPrint = Date()
        while off < size {
            let n = Int(min(UInt64(chunk), size - off))
            let data = try fh.read(upToCount: n)!
            _ = try await cmd(Op.sendPartialObject, [h, UInt32(off & 0xFFFF_FFFF), UInt32(off >> 32), UInt32(n)], out: data)
            off += UInt64(n)
            if off == UInt64(n) || Date().timeIntervalSince(lastPrint) > 10 {
                print("  \(off >> 20) / \(size >> 20) MB  平均 \(mb(Int(off), Date().timeIntervalSince(t0)))"); lastPrint = Date()
            }
        }
        if edit { _ = try await cmd(Op.endEditObject, [h]) }
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "全部写完：%.0fs，平均 %@", dt, mb(Int(size), dt)))
        try? await Task.sleep(for: .seconds(5))
        let left = try? await objectSize(h)
        print("写完 5 秒后对象大小：\(left.map(String.init) ?? "对象已不存在")")
    }
}

// MARK: - main

setvbuf(stdout, nil, _IONBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let spike = MainActor.assumeIsolated { Spike() }
Task { @MainActor in
    do {
        let cmdName = args.first ?? "info"
        let cam = try await spike.findDBI()
        let waitReady = cmdName == "media" ? 120.0 : Double(ProcessInfo.processInfo.environment["WAIT_READY"] ?? "0")!
        try await spike.open(cam, waitReady: waitReady)
        switch cmdName {
        case "info": try await spike.info()
        case "ls":
            var budget = Int(ProcessInfo.processInfo.environment["LS_MAX"] ?? "300")!
            let t0 = Date()
            let storage = UInt32(parseNum(args[1]))
            let parent: UInt32 = args.count > 2 ? UInt32(parseNum(args[2])) : 0xFFFF_FFFF
            let depth = args.count > 3 ? Int(args[3])! : 1
            try await spike.ls(storage: storage, parent: parent, depth: depth, budget: &budget)
            print(String(format: "（遍历用时 %.2fs）", Date().timeIntervalSince(t0)))
        case "props": try await spike.props(UInt32(parseNum(args[1])))
        case "media": spike.media()
        case "read":
            try await spike.read(UInt32(parseNum(args[1])), chunk: Int(args[2])! * 1_048_576,
                                 maxBytes: args.count > 3 ? UInt64(args[3])! * 1_048_576 : .max)
        case "write":
            try await spike.write(storage: UInt32(parseNum(args[1])), parent: UInt32(parseNum(args[2])),
                                  sizeKB: args.count > 3 ? Int(args[3])! : 64)
        case "cmp":
            // cmp <handle> <offsetMB...>：比对设备端与 SRC_FILE 在各偏移处的 1 MB
            let file = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRC_FILE"]!), options: .alwaysMapped)
            let h = UInt32(parseNum(args[1]))
            print("ObjectSize=\(try await spike.objectSize(h))")
            for a in args.dropFirst(2) {
                let o = UInt64(a)! * 1_048_576
                let d = try await spike.cmd(Op.getPartialObject64, [h, UInt32(o & 0xFFFF_FFFF), UInt32(o >> 32), 1_048_576]).1
                let end = min(file.count, Int(o) + 1_048_576)
                let exp = file.subdata(in: Int(o)..<end)
                var wrap = "-"
                if o >= 1 << 32 { let w = Int(o - (1 << 32)); wrap = file.subdata(in: w..<(w + d.count)) == d ? "等于源文件 offset-4GB 处 ⚠️" : "否" }
                print("  @\(a)MB 收到 \(d.count)B，与源一致：\(d == exp ? "✅" : "❌")，回绕检查：\(wrap)")
            }
        case "crud":
            try await spike.crud(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])), iterations: Int(args[3])!)
        case "probe-names":
            try await spike.probeNames(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])))
        case "probe-edit":
            try await spike.probeEdit(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])))
        case "probe-chars":
            try await spike.probeChars(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])), chars: Array(args.dropFirst(3)))
        case "probe-move":
            try await spike.probeMove(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])))
        case "rminstall":
            // 只删 5: SD Card install 根目录下、名字和 SRC_FILE 一致的对象
            let h = UInt32(parseNum(args[1]))
            let (_, d) = try await spike.cmd(Op.getObjectInfo, [h])
            let o = ObjectInfo(d)
            let want = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRC_FILE"]!).lastPathComponent
            guard o.storage == 0x0001_0005, o.name == want else { throw PTPError(description: "拒绝删除 \(o.name)") }
            _ = try await spike.cmd(0x100B, [h, 0])
            print("已删除 \(o.name)")
        case "rmfile":
            try await spike.verifyTestDir(0x0001_0001, UInt32(parseNum(args[2])))
            try await spike.safeDelete(UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])))
            print("已删除")
        case "install":
            try await spike.install(storage: UInt32(parseNum(args[1])), variant: args[2], chunk: Int(args[3])! << 20)
        case "rmtest":
            try await spike.rmtest(storage: UInt32(parseNum(args[1])), testDir: UInt32(parseNum(args[2])))
        case "pwrite":
            try await spike.pwrite(storage: UInt32(parseNum(args[1])), dir: UInt32(parseNum(args[2])), chunk: Int(args[3])! * 1_048_576)
        default: print("未知子命令 \(cmdName)")
        }
        try? await cam.requestCloseSession()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    } catch {
        print("❌ \(error)")
        exit(1)
    }
}
RunLoop.main.run()
