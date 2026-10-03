// 增删改查稳定性测试 + 测试目录清理。所有写/删操作都限制在 SD 卡根目录下的 SwitchMTP-spike 里。

import Foundation

extension Op {
    static let deleteObject: UInt16 = 0x100B
    static let moveObject: UInt16 = 0x1019
    static let truncateObject: UInt16 = 0x95C3
    static let setObjectPropValue: UInt16 = 0x9804
}

let testDirName = "SwitchMTP-spike"
let sdStorage: UInt32 = 0x0001_0001

/// 根目录对象的 ParentObject：规范是 0 / 0xFFFFFFFF，DBI 实际填的是存储 ID
func isRootParent(_ p: UInt32) -> Bool { p == 0 || p == 0xFFFF_FFFF || p == sdStorage }

/// 简单的可复现伪随机数（xorshift）
struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func bytes(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { p in for i in 0..<n { p[i] = UInt8(truncatingIfNeeded: next()) } }
        return d
    }
}

struct OpStat {
    var ok = 0, fail = 0, total: Double = 0, max: Double = 0
    var errors: [String] = []
}

extension Spike {
    // MARK: 基础操作

    func info(_ h: UInt32) async throws -> ObjectInfo { ObjectInfo(try await cmd(Op.getObjectInfo, [h]).1) }

    func children(_ storage: UInt32, _ parent: UInt32) async throws -> [(UInt32, ObjectInfo)] {
        var r = Reader(try await cmd(Op.getObjectHandles, [storage, 0, parent]).1)
        var out: [(UInt32, ObjectInfo)] = []
        for h in r.arr32() { out.append((h, try await info(h))) }
        return out
    }

    func objectInfoData(storage: UInt32, parent: UInt32, name: String, format: UInt16, size: Int) -> Data {
        var w = Writer()
        w.u32(storage); w.u16(format); w.u16(0); w.u32(UInt32(min(size, 0xFFFF_FFFF)))
        w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.u32(parent); w.u16(format == 0x3001 ? 1 : 0); w.u32(0); w.u32(0)
        w.str(name); w.str(""); w.str(""); w.str("")
        return w.d
    }

    func createDir(_ storage: UInt32, _ parent: UInt32, _ name: String) async throws -> UInt32 {
        let r = try await cmd(Op.sendObjectInfo, [storage, parent], out: objectInfoData(storage: storage, parent: parent, name: name, format: 0x3001, size: 0)).0
        return r.params[2]
    }

    func createFile(_ storage: UInt32, _ parent: UInt32, _ name: String, _ data: Data) async throws -> UInt32 {
        let r = try await cmd(Op.sendObjectInfo, [storage, parent], out: objectInfoData(storage: storage, parent: parent, name: name, format: 0x3000, size: data.count)).0
        _ = try await cmd(Op.sendObject, [], out: data)
        return r.params[2]
    }

    /// 删除前确认对象位于 SD 卡的 SwitchMTP-spike 目录之内（沿 parent 链向上找）
    func assertInsideTestDir(_ h: UInt32, testDir: UInt32) async throws {
        var cur = h
        for _ in 0..<32 {
            if cur == testDir { return }
            let oi = try await info(cur)
            guard oi.storage == sdStorage else { break }
            if isRootParent(oi.parent) { break }
            cur = oi.parent
        }
        throw PTPError(description: "安全保护：\(hex(h, 8)) 不在测试目录内，拒绝删除")
    }

    func safeDelete(_ h: UInt32, testDir: UInt32) async throws {
        try await assertInsideTestDir(h, testDir: testDir)
        _ = try await cmd(Op.deleteObject, [h, 0])
    }

    func verifyTestDir(_ storage: UInt32, _ testDir: UInt32) async throws {
        let oi = try await info(testDir)
        guard storage == sdStorage, oi.storage == sdStorage, oi.isDir, oi.name == testDirName, isRootParent(oi.parent) else {
            throw PTPError(description: "安全保护：\(hex(testDir, 8)) 不是 SD 卡根目录下的 \(testDirName)（实际 name=\(oi.name) parent=\(hex(oi.parent, 8))）")
        }
    }

    // MARK: rmtest

    func rmtest(storage: UInt32, testDir: UInt32) async throws {
        try await verifyTestDir(storage, testDir)
        var deleted = 0, failed = 0
        func rm(_ parent: UInt32) async throws {
            for (h, oi) in try await children(storage, parent) {
                if oi.isDir { try await rm(h) }
                do {
                    try await safeDelete(h, testDir: testDir)
                    deleted += 1
                } catch let e as PTPError where e.code == 0x2009 {
                    print("  已不存在（重复 handle）：\(oi.name) \(hex(h, 8))")
                } catch {
                    failed += 1; print("  删除失败 \(oi.name) \(hex(h, 8))：\(error)")
                }
            }
        }
        try await rm(testDir)
        let left = try await children(storage, testDir)
        print("子项删除 \(deleted) 个，失败 \(failed) 个，目录内剩余 \(left.count) 项")
        guard left.isEmpty else { throw PTPError(description: "目录未清空，不删除目录本身") }
        _ = try await cmd(Op.deleteObject, [testDir, 0])
        let root = try await children(storage, 0xFFFF_FFFF)
        print("删除 \(testDirName)：\(root.contains { $0.1.name == testDirName } ? "仍存在 ❌" : "已删除 ✅")（根目录剩 \(root.count) 项）")
    }

    // MARK: probe-names：文件名字符集 / 0 字节 / 改名移动替代方案

    func probeNames(storage: UInt32, testDir: UInt32) async throws {
        try await verifyTestDir(storage, testDir)
        let dir = try await createDir(storage, testDir, "names-\(Int(Date().timeIntervalSince1970))")
        let cases: [(String, Int)] = [
            ("ascii.bin", 100), ("zero.bin", 0), ("with space.bin", 100), ("中文名.bin", 100),
            ("日本語テスト.bin", 100), ("accent-é.bin", 100), ("emoji-🎮.bin", 100), ("mixed 文件 é.bin", 0),
            ("[0100000000010000][v0].nsp", 100), ("a#b%c&d+e=f!.bin", 100),
        ]
        for (name, size) in cases {
            var r = RNG(s: 42)
            let data = r.bytes(size)
            var h: UInt32 = 0
            var result = ""
            do {
                let resp = try await cmd(Op.sendObjectInfo, [storage, dir], out: objectInfoData(storage: storage, parent: dir, name: name, format: 0x3000, size: size)).0
                h = resp.params[2]
                result = "SendObjectInfo OK"
                _ = try await cmd(Op.sendObject, [], out: data)
                result += "，SendObject OK"
            } catch { result += "，\(error)" }
            var after = ""
            if h != 0, let oi = try? await info(h) { after = "设备端名字=\"\(oi.name)\" size=\((try? await objectSize(h)) ?? 0)" }
            print(String(format: "  %-30@ %4dB → %@ | %@", name as NSString, size, result, after))
        }
        print("目录列表：\(try await children(storage, dir).map { $0.1.name })")
        // 0 字节：不带数据阶段的 SendObject（outData=nil）
        do {
            let resp = try await cmd(Op.sendObjectInfo, [storage, dir], out: objectInfoData(storage: storage, parent: dir, name: "zero-nil.bin", format: 0x3000, size: 0)).0
            _ = try await cmd(Op.sendObject, [], out: nil)
            print("0 字节 + outData=nil：OK，size=\(try await objectSize(resp.params[2]))")
        } catch { print("0 字节 + outData=nil：\(error)") }
        // 目录改名 / 目录移动也试一下
        let sub = try await createDir(storage, dir, "sub")
        var w = Writer(); w.str("sub-renamed")
        for p: UInt32 in [0xDC07, 0xDC44] {
            do { _ = try await cmd(Op.setObjectPropValue, [sub, p], out: w.d); print("目录改名 via \(hex(p))：OK → \(try await info(sub).name)") } catch { print("目录改名 via \(hex(p))：\(error)") }
        }
        let f = try await createFile(storage, dir, "tomove.bin", Data([1, 2, 3]))
        for (desc, params) in [("parent=sub", [f, storage, sub]), ("parent=0", [f, storage, 0]), ("parent=FFFFFFFF", [f, storage, 0xFFFF_FFFF])] as [(String, [UInt32])] {
            do { _ = try await cmd(Op.moveObject, params); print("MoveObject \(desc)：OK") } catch { print("MoveObject \(desc)：\(error)") }
        }
        do { _ = try await cmd(Op.getObjectPropDesc, [0xDC07, 0x3000]).1; print("GetObjectPropDesc(DC07) OK") } catch { print("GetObjectPropDesc(DC07)：\(error)") }
        do {
            var r = Reader(try await cmd(Op.getObjectPropDesc, [0xDC44, 0x3000]).1)
            let code = r.u16(), type = r.u16(), getSet = r.u8()
            print("GetObjectPropDesc(DC44)：code=\(hex(code)) type=\(hex(type)) getSet=\(getSet)（1=可写）")
        } catch { print("GetObjectPropDesc(DC44)：\(error)") }
        try await safeDelete(dir, testDir: testDir)
        print("清理 names 目录：\(try await children(storage, testDir).contains { $0.0 == dir } ? "❌" : "✅")")
    }

    // MARK: probe-edit：改名 / 移动在什么条件下可用

    func probeEdit(storage: UInt32, testDir: UInt32) async throws {
        try await verifyTestDir(storage, testDir)
        let dir = try await createDir(storage, testDir, "edit-\(Int(Date().timeIntervalSince1970))")
        let x = try await createDir(storage, dir, "X"), y = try await createDir(storage, dir, "Y")
        func rename(_ h: UInt32, _ n: String) async -> String {
            var w = Writer(); w.str(n)
            do { _ = try await cmd(Op.setObjectPropValue, [h, 0xDC07], out: w.d); return "OK → \((try? await info(h).name) ?? "?")" } catch { return "\(error)" }
        }
        func move(_ h: UInt32, _ to: UInt32) async -> String {
            do { _ = try await cmd(Op.moveObject, [h, storage, to]); return "OK，parent=\((try? await info(h).parent).map { hex($0, 8) } ?? "?")" } catch { return "\(error)" }
        }
        // 1. 刚建好、目录未枚举过
        let a = try await createFile(storage, x, "a.bin", Data([1, 2, 3]))
        print("新文件（目录未枚举）改名：\(await rename(a, "a2.bin"))")
        let b = try await createFile(storage, x, "b.bin", Data([1, 2, 3]))
        print("新文件（目录未枚举）移动 X→Y：\(await move(b, y))")
        // 2. 目录枚举后
        let lx = try await children(storage, x)
        print("枚举 X：\(lx.map { "\($0.1.name)@\(hex($0.0, 8))" })")
        let c = try await createFile(storage, x, "c.bin", Data([1, 2, 3]))
        print("新文件（目录已枚举）改名：\(await rename(c, "c2.bin"))")
        let d = try await createFile(storage, x, "d.bin", Data([1, 2, 3]))
        print("新文件（目录已枚举）移动 X→Y：\(await move(d, y))")
        // 3. 扫描登记出来的 handle（重复项里不是原 handle 的那个）
        if let scanned = lx.first(where: { $0.0 != a && $0.0 != b })?.0 {
            print("扫描 handle \(hex(scanned, 8)) 改名：\(await rename(scanned, "s2.bin"))")
        }
        // 4. 编辑过的文件
        let e = try await createFile(storage, x, "e.bin", Data(repeating: 7, count: 100))
        _ = try await cmd(Op.beginEditObject, [e]); _ = try await cmd(Op.truncateObject, [e, 10, 0]); _ = try await cmd(Op.endEditObject, [e])
        print("编辑后改名：\(await rename(e, "e2.bin"))，移动：\(await move(e, y))")
        // 5. 目标目录里已有同名文件
        let f1 = try await createFile(storage, x, "same.bin", Data([1])), _ = try await createFile(storage, y, "same.bin", Data([2]))
        print("移动到有同名文件的目录：\(await move(f1, y))")
        // 6. 移动到 parent=0：看 DBI 把它放哪
        let g = try await createFile(storage, x, "g-move-to-0.bin", Data([9]))
        print("MoveObject parent=0：\(await move(g, 0))")
        if let oi = try? await info(g), !(oi.parent == x || oi.parent == y) {
            print("  ⚠️ 文件被移出测试目录（parent=\(hex(oi.parent, 8))），移回 X：\(await move(g, x))")
        }
        // 7. 名字被删字的扫描 handle 能否读取
        let u = try await createDir(storage, dir, "U")
        _ = try await createFile(storage, u, "中文名.bin", Data([5, 6, 7]))
        for (h, oi) in try await children(storage, u) {
            do { let dd = try await cmd(Op.getObject, [h]).1; print("读取 \"\(oi.name)\"@\(hex(h, 8))：OK \(dd.count)B") } catch { print("读取 \"\(oi.name)\"@\(hex(h, 8))：\(error)") }
        }
        // 8. 日文字符逐个试
        for n in ["日本語.bin", "テスト.bin", "ひらがな.bin", "ｶﾀｶﾅ.bin", "한국어.bin", "Ελληνικά.bin", "测试テ.bin"] {
            do { let h = try await createFile(storage, u, n, Data([1])); print("  文件名 \(n)：OK → \(try await info(h).name)") } catch { print("  文件名 \(n)：\(error)") }
        }
        print("最终 X：\(try await children(storage, x).map { $0.1.name })  Y：\(try await children(storage, y).map { $0.1.name })")
        try await safeDelete(dir, testDir: testDir)
        print("清理 edit 目录：\(try await children(storage, testDir).contains { $0.0 == dir } ? "❌" : "✅")")
    }

    // MARK: probe-chars：逐字符测试文件名

    func probeChars(storage: UInt32, testDir: UInt32, chars: [String]) async throws {
        try await verifyTestDir(storage, testDir)
        let dir = try await createDir(storage, testDir, "chars-\(Int(Date().timeIntervalSince1970))")
        var ok: [String] = [], bad: [String] = []
        for c in chars {
            let u = c.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let name = c.contains(".") ? c : "x\(c).bin"   // 参数里带 . 的按完整文件名用
            do { _ = try await createFile(storage, dir, name, Data([1])); ok.append("\(c)(\(u))") } catch { bad.append("\(c)(\(u))") }
        }
        print("成功：\(ok.joined(separator: " "))")
        print("失败：\(bad.joined(separator: " "))")
        // 改名成中文 / 带空格
        let h = try await createFile(storage, dir, "ren.bin", Data([1]))
        for n in ["ren 2.bin", "改名.bin", "spike-renamed-1-2 改名.bin"] {
            var w = Writer(); w.str(n)
            do { _ = try await cmd(Op.setObjectPropValue, [h, 0xDC07], out: w.d); print("改名为 \(n)：OK → \(try await info(h).name)") } catch { print("改名为 \(n)：\(error)") }
        }
        try await safeDelete(dir, testDir: testDir)
    }

    // MARK: probe-move：MoveObject 的真实语义
    // 判定物理位置：目录首次被枚举时 DBI 会扫描文件系统、给每个物理文件分配新 handle。
    // 所以移动完成后再首次枚举各目录，"不是我们创建的 handle" 就代表物理上在该目录里的文件。

    func probeMove(storage: UInt32, testDir: UInt32) async throws {
        try await verifyTestDir(storage, testDir)
        let dir = try await createDir(storage, testDir, "move-\(Int(Date().timeIntervalSince1970))")
        let p = try await createDir(storage, dir, "P"), q = try await createDir(storage, dir, "Q"), r = try await createDir(storage, dir, "R")
        let names = [p: "P", q: "Q", r: "R"]
        var ours: Set<UInt32> = []
        var moved: [(String, UInt32)] = []
        let stay = try await createFile(storage, p, "stay.bin", Data("stay".utf8)); ours.insert(stay)
        for (n, from, to) in [("p2q", p, q), ("q2p", q, p), ("p2r", p, r)] as [(String, UInt32, UInt32)] {
            let h = try await createFile(storage, from, "\(n).bin", Data(n.utf8)); ours.insert(h)
            do {
                _ = try await cmd(Op.moveObject, [h, storage, to])
                let oi = try await info(h)
                let readable = (try? await cmd(Op.getObject, [h]).1) == Data(n.utf8)
                print("\(n)：MoveObject OK；原 handle 的 parent=\(names[oi.parent] ?? hex(oi.parent, 8))，原 handle 读取=\(readable ? "OK" : "失败")")
            } catch { print("\(n)：\(error)") }
            moved.append((n, h))
        }
        for (d, dn) in [(p, "P"), (q, "Q"), (r, "R")] {
            let list = try await children(storage, d)
            let cached = list.filter { ours.contains($0.0) }.map { $0.1.name }
            let physical = list.filter { !ours.contains($0.0) }
            var ph: [String] = []
            for (h, oi) in physical {
                let ok = (try? await cmd(Op.getObject, [h]).1).map { String(decoding: $0, as: UTF8.self) } ?? "不可读"
                ph.append("\(oi.name)(内容=\(ok))")
            }
            print("\(dn) 首次枚举：缓存项=\(cached)  扫描到的物理文件=\(ph)")
        }
        // 目标目录已枚举过的情况：S、T 都先枚举，再把 S 里的文件移到 T
        let sDir = try await createDir(storage, dir, "S"), tDir = try await createDir(storage, dir, "T")
        _ = try await children(storage, sDir); _ = try await children(storage, tDir)
        let m = try await createFile(storage, sDir, "s2t.bin", Data("s2t".utf8))
        _ = try await cmd(Op.moveObject, [m, storage, tDir])
        print("已枚举目录间移动后：S=\(try await children(storage, sDir).map { "\($0.1.name)@\(hex($0.0, 8))" }) T=\(try await children(storage, tDir).map { "\($0.1.name)@\(hex($0.0, 8))" })")
        // 在 T 里新建文件会不会触发重新扫描
        _ = try await createFile(storage, tDir, "new.bin", Data([1]))
        print("T 里新建文件后：T=\(try await children(storage, tDir).map { $0.1.name })")
        try await safeDelete(dir, testDir: testDir)
    }

    // MARK: crud

    func crud(storage: UInt32, testDir: UInt32, iterations: Int) async throws {
        try await verifyTestDir(storage, testDir)
        var rng = RNG(s: UInt64(Date().timeIntervalSince1970 * 1000) | 1)
        var stats: [String: OpStat] = [:]

        func timed<T>(_ op: String, _ body: () async throws -> T) async -> T? {
            let t0 = Date()
            do {
                let v = try await body()
                let dt = Date().timeIntervalSince(t0)
                stats[op, default: OpStat()].ok += 1
                stats[op]!.total += dt
                stats[op]!.max = Swift.max(stats[op]!.max, dt)
                return v
            } catch {
                stats[op, default: OpStat()].fail += 1
                if stats[op]!.errors.count < 5 { stats[op]!.errors.append("\(error)") }
                print("  ❌ \(op)：\(error)")
                return nil
            }
        }
        func check(_ op: String, _ cond: Bool, _ msg: @autoclosure () -> String) throws {
            if !cond { throw PTPError(description: "\(op) 校验失败：\(msg())") }
        }

        let root = try await createDir(storage, testDir, "crud-\(Int(Date().timeIntervalSince1970))")
        let dirA = try await createDir(storage, root, "A")
        let dirB = try await createDir(storage, root, ProcessInfo.processInfo.environment["CRUD_DIRB"] ?? "B 目录")
        print("测试目录 root=\(hex(root, 8)) A=\(hex(dirA, 8)) B=\(hex(dirB, 8))")

        // ---- 1. 重复 handle 现象：先建文件、后第一次枚举目录 ----
        print("== 重复 handle 测试 ==")
        let dupDir = try await createDir(storage, root, "dup")
        let dupData = rng.bytes(1000)
        let h1 = try await createFile(storage, dupDir, "dup.bin", dupData)
        let firstList = try await children(storage, dupDir)
        print("建文件后首次枚举：\(firstList.map { "\($0.1.name)@\(hex($0.0, 8))" })")
        let secondList = try await children(storage, dupDir)
        print("第二次枚举：\(secondList.count) 项")
        let h3 = try await createFile(storage, dupDir, "dup2.bin", dupData)
        let thirdList = try await children(storage, dupDir)
        print("目录已枚举过后再建文件：\(thirdList.map { "\($0.1.name)@\(hex($0.0, 8))" })（新 handle \(hex(h3, 8))）")
        if let other = firstList.first(where: { $0.0 != h1 && $0.1.name == "dup.bin" })?.0 {
            _ = try await cmd(Op.deleteObject, [h1, 0])
            print("删除原 handle \(hex(h1, 8)) 成功")
            do { let oi = try await info(other); print("另一个 handle \(hex(other, 8)) 仍可 GetObjectInfo：\(oi.name)") } catch { print("另一个 handle \(hex(other, 8)) GetObjectInfo：\(error)") }
            print("删除后枚举：\(try await children(storage, dupDir).map { "\($0.1.name)@\(hex($0.0, 8))" })")
            do { _ = try await cmd(Op.deleteObject, [other, 0]); print("再删另一个 handle：成功") } catch { print("再删另一个 handle：\(error)") }
        }
        // 删除非空目录：看 DBI 是否递归删除
        do {
            _ = try await cmd(Op.deleteObject, [dupDir, 0])
            let left = try await children(storage, root).contains { $0.0 == dupDir }
            print("删除非空目录 dup：成功（目录\(left ? "仍在" : "已消失")，\(try await children(storage, root).count) 项剩余）")
        } catch { print("删除非空目录 dup：\(error)") }

        // ---- 2. 随机增删改查 ----
        print("== 随机增删改查 \(iterations) 轮 ==")
        struct Live { var h: UInt32; var name: String; var data: Data; var dir: UInt32; var moved = false }
        var live: [Live] = []
        var deleted: Set<UInt32> = []
        // DBI 缓存残留计数（不算失败）：移动后原目录仍列出、删除后同名扫描项仍列出、列表里多出的项
        var staleAfterMove = 0, ghostAfterDelete = 0, maxExtra = 0
        // 0 字节（SendObject 必返回 0x2002）已在 probe-names 单独确认，这里不再生成
        let sizes = [1, 511, 4096, 65536, 1_048_576, 2_000_000]
        let t0 = Date()

        for i in 1...iterations {
            // 增 + 查
            let size = rng.int(3) == 0 ? sizes[rng.int(sizes.count)] : 1 + rng.int(300_000)
            let name = ["spike-\(i).bin", "spike \(i) 测试 文件.dat", "spike-\(i)-ünïcödé-🎮.txt"][rng.int(3)]
            let data = rng.bytes(size)
            let dir = rng.int(2) == 0 ? dirA : dirB
            if let h = await timed("create", { try await self.createFile(storage, dir, name, data) }) {
                let ok = await timed("read", {
                    let back = try await self.cmd(Op.getObject, [h]).1
                    try check("read", back == data, "内容不一致（\(back.count)/\(data.count)B）")
                    let sz = try await self.objectSize(h)
                    try check("read", sz == UInt64(size), "ObjectSize \(sz) ≠ \(size)")
                    let oi = try await self.info(h)
                    try check("read", oi.name == name && oi.parent == dir, "name=\(oi.name) parent=\(hex(oi.parent, 8))")
                })
                if ok != nil { live.append(Live(h: h, name: name, data: data, dir: dir)) }
            }

            // 随机挑一个现有文件做 改/重命名/移动/删除
            guard !live.isEmpty else { continue }
            let idx = rng.int(live.count)
            var f = live[idx]
            let actions = f.moved ? ["delete"] : ["edit", "truncate", "rename", "move", "delete", "delete"]
            let action = actions[rng.int(actions.count)]
            switch action {
            case "edit":
                let off = f.data.isEmpty ? 0 : rng.int(f.data.count + 1)
                let patch = rng.bytes(1 + rng.int(200_000))
                let r = await timed("edit", {
                    _ = try await self.cmd(Op.beginEditObject, [f.h])
                    _ = try await self.cmd(Op.sendPartialObject, [f.h, UInt32(off), 0, UInt32(patch.count)], out: patch)
                    _ = try await self.cmd(Op.endEditObject, [f.h])
                    var expect = f.data
                    if off + patch.count > expect.count { expect.count = off + patch.count }
                    expect.replaceSubrange(off..<(off + patch.count), with: patch)
                    let back = try await self.cmd(Op.getObject, [f.h]).1
                    try check("edit", back == expect, "内容不一致（期望 \(expect.count)B，收到 \(back.count)B，off=\(off) patch=\(patch.count)）")
                    return expect
                })
                if let r { f.data = r; live[idx] = f }
            case "truncate":
                let newSize = rng.int(f.data.count + 1)
                let r = await timed("truncate", {
                    _ = try await self.cmd(Op.beginEditObject, [f.h])
                    _ = try await self.cmd(Op.truncateObject, [f.h, UInt32(newSize), 0])
                    _ = try await self.cmd(Op.endEditObject, [f.h])
                    let back = try await self.cmd(Op.getObject, [f.h]).1
                    let sz = try await self.objectSize(f.h)
                    try check("truncate", back == f.data.prefix(newSize) && sz == UInt64(newSize), "收到 \(back.count)B，ObjectSize=\(sz)，期望 \(newSize)B")
                })
                if r != nil { f.data = f.data.prefix(newSize); live[idx] = f }
            case "rename":
                // 改成非 ASCII 名字必返回 0x2005（probe-chars 已确认），这里只测 ASCII 目标名
                let newName = "spike-renamed-\(i)-\(rng.int(1000)).bin"
                var w = Writer(); w.str(newName)
                let r = await timed("rename", {
                    _ = try await self.cmd(Op.setObjectPropValue, [f.h, 0xDC07], out: w.d)
                    let oi = try await self.info(f.h)
                    try check("rename", oi.name == newName, "ObjectInfo.name=\(oi.name)")
                    let entry = try await self.children(storage, f.dir).first { $0.0 == f.h }
                    try check("rename", entry?.1.name == newName, "目录列表里该 handle 的名字=\(entry?.1.name ?? "缺失")")
                })
                if r != nil { f.name = newName; live[idx] = f }
            case "move":
                let to = f.dir == dirA ? dirB : dirA
                let ascii = f.name.unicodeScalars.allSatisfy { $0.isASCII }
                let r = await timed(ascii ? "move-ascii" : "move-nonascii", {
                    // 实测语义（probe-move）：物理上移动正确，但 DBI 缓存不更新——原 handle 的 parent 不变、
                    // 仍列在原目录、仍可读；目标目录要等 DBI 重新扫描才会列出。这里按该语义校验。
                    _ = try await self.cmd(Op.moveObject, [f.h, storage, to])
                    let back = try await self.cmd(Op.getObject, [f.h]).1
                    try check("move", back == f.data, "移动后原 handle 读出的内容不一致")
                    if try await self.info(f.h).parent != to { staleAfterMove += 1 }
                })
                // 缓存里它仍在原目录，模型保持 f.dir 不变，list-verify 才能对上；同时它物理上已在 to，
                // 之后再移动/改名会作用于真实位置，所以移动过的文件只允许读和删除
                if r != nil { f.moved = true; live[idx] = f }
            default:
                let r = await timed("delete", {
                    try await self.safeDelete(f.h, testDir: testDir)
                    do { _ = try await self.info(f.h); throw PTPError(description: "删除后仍能 GetObjectInfo") } catch let e as PTPError where e.code != 0 {}
                    let list = try await self.children(storage, f.dir)
                    try check("delete", !list.contains { $0.0 == f.h }, "删除后目录列表里仍有该 handle")
                    if list.contains(where: { $0.1.name == f.name }) { ghostAfterDelete += 1 }
                })
                if r != nil { live.remove(at: idx); deleted.insert(f.h) }
            }

            // 每 20 轮全量核对目录列表与本地模型
            if i % 20 == 0 || i == iterations {
                _ = await timed("list-verify", {
                    for d in [dirA, dirB] {
                        // 以 handle 为准：存活文件必须在、已删 handle 不能在；其余多出的项（扫描重复/移动残留）只计数
                        let list = try await self.children(storage, d)
                        let got = Set(list.map { $0.0 })
                        let expect = live.filter { $0.dir == d }
                        let missing = expect.filter { !got.contains($0.h) }
                        let ghosts = got.intersection(deleted)
                        try check("list-verify", missing.isEmpty && ghosts.isEmpty, "目录 \(hex(d, 8)) 缺少 \(missing.map { $0.name }.prefix(3))，已删除却仍列出 \(ghosts.count) 个")
                        let wrongName = list.filter { e in expect.contains { $0.h == e.0 && $0.name != e.1.name } }
                        try check("list-verify", wrongName.isEmpty, "名字不符：\(wrongName.map { $0.1.name }.prefix(3))")
                        maxExtra = Swift.max(maxExtra, list.count - expect.count)
                    }
                })
                print(String(format: "  第 %d 轮，存活 %d 个文件，用时 %.1fs", i, live.count, Date().timeIntervalSince(t0)))
            }
        }

        // ---- 3. 清理本次 crud 目录 ----
        for f in live { _ = await timed("delete", { try await self.safeDelete(f.h, testDir: testDir) }) }
        for d in [dirA, dirB, root] { _ = await timed("rmdir", { try await self.safeDelete(d, testDir: testDir) }) }
        let leftover = try await children(storage, testDir).filter { $0.0 == root }
        print("清理 crud 目录：\(leftover.isEmpty ? "✅" : "❌ 仍存在")")

        print("== 统计 ==")
        for (op, s) in stats.sorted(by: { $0.key < $1.key }) {
            let avg = s.ok > 0 ? s.total / Double(s.ok) * 1000 : 0
            print(String(format: "  %-12@ 成功 %4d  失败 %3d  平均 %7.1fms  最大 %7.1fms", op as NSString, s.ok, s.fail, avg, s.max * 1000))
            for e in s.errors { print("      \(e)") }
        }
        print("DBI 缓存残留：移动后原 handle 的 parent 未更新 \(staleAfterMove) 次，删除后同名扫描项仍列出 \(ghostAfterDelete) 次，目录列表最多多出 \(maxExtra) 项")
    }
}
