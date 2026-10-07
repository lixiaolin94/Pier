import Foundation
import Testing
@testable import PierKit

private let smallTuning = TransferTuning(largeChunk: 8 << 10, smallChunk: 2 << 10, uploadChunk: 4 << 10, smallUploadChunk: 1 << 10)

private func makeSession(_ device: FakeDevice, operations: [PTPOperation] = FakeDevice.allOperations,
                         manufacturer: String = "Google") throws -> MTPSession {
    MTPSession(transport: device, deviceInfo: try FakeDevice.deviceInfo(operations: operations, manufacturer: manufacturer), tuning: smallTuning)
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PierKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - 引擎

@Test func downloadResumesFromPartialFile() async throws {
    let device = FakeDevice()
    let content = Data.pattern(100_000)
    let h = device.add("big.bin", data: content)
    let session = try makeSession(device)
    let dir = try tempDir()
    let file = dir.appendingPathComponent("big.bin.pierdownload")
    try content.prefix(30_000).write(to: file)

    let progress = TransferProgress()
    try await session.download(h, size: UInt64(content.count), into: file, progress: progress)

    #expect(try Data(contentsOf: file) == content)
    #expect(progress.snapshot.completedBytes == UInt64(content.count))
    // 只读了剩下的 70000 字节：8 KB 一块，9 块
    #expect(device.ops().filter { $0 == .getPartialObject }.count == 9)
}

@Test func uploadSingleSendObject() async throws {
    let device = FakeDevice()
    let session = try makeSession(device)
    let dir = try tempDir()
    let file = dir.appendingPathComponent("a.bin")
    let content = Data.pattern(50_000, seed: 3)
    try content.write(to: file)

    let h = try await session.upload(file: file, name: "a.bin", storage: FakeDevice.storage, parent: PTPHandle.root,
                                     progress: TransferProgress(), preferChunked: false)
    #expect(h > 0)
    #expect(device.find(["a.bin"])?.data == content)
    #expect(!device.ops().contains(.sendPartialObject))
}

@Test func uploadIsChunkedWhenLargerThanSingleCommandLimit() async throws {
    let device = FakeDevice(maxOutDataLength: 10_000)
    let session = try makeSession(device)
    let dir = try tempDir()
    let file = dir.appendingPathComponent("huge.bin")
    let content = Data.pattern(25_000, seed: 7)
    try content.write(to: file)

    let progress = TransferProgress()
    _ = try await session.upload(file: file, name: "huge.bin", storage: FakeDevice.storage, parent: PTPHandle.root,
                                 progress: progress, preferChunked: false)
    #expect(device.find(["huge.bin"])?.data == content)
    let ops = device.ops()
    #expect(ops.contains(.beginEditObject) && ops.contains(.endEditObject))
    #expect(ops.filter { $0 == .sendPartialObject }.count == 6)   // 首块 4 KB，之后 21000 / 4096 → 6 块
    #expect(device.declaredSizes == [4096])                         // SendObjectInfo 只声明首块大小
    #expect(progress.snapshot.completedBytes == 25_000)
}

@Test func uploadTooLargeWithoutEditExtensionFailsCleanly() async throws {
    let device = FakeDevice(maxOutDataLength: 10_000)
    let ops = FakeDevice.allOperations.filter { $0 != .beginEditObject }
    let session = try makeSession(device, operations: ops)
    let file = try tempDir().appendingPathComponent("huge.bin")
    try Data.pattern(25_000).write(to: file)

    await #expect(throws: TransferError.self) {
        _ = try await session.upload(file: file, name: "huge.bin", storage: FakeDevice.storage, parent: PTPHandle.root,
                                     progress: TransferProgress(), preferChunked: true)
    }
    #expect(device.objectCount == 0)
}

@Test func installTargetUploadSkipsVerificationAndKeepsObject() async throws {
    let device = FakeDevice()
    device.consumesUploads = true
    let session = try makeSession(device, manufacturer: "Nintendo")
    let src = try tempDir().appendingPathComponent("game.nsp")
    try Data.pattern(9_000).write(to: src)

    // 不跳过校验：回读到 0，判失败并删掉（0.1.3 及以前的行为）
    await #expect(throws: TransferError.self) {
        _ = try await session.upload(file: src, name: "game.nsp", storage: FakeDevice.storage, parent: PTPHandle.root,
                                     progress: TransferProgress(), preferChunked: false)
    }
    #expect(device.ops().contains(.deleteObject))

    // 安装存储跳过校验：算成功，不删
    let before = device.ops().filter { $0 == .deleteObject }.count
    _ = try await session.upload(file: src, name: "game.nsp", storage: FakeDevice.storage, parent: PTPHandle.root,
                                 progress: TransferProgress(), preferChunked: false, verify: false)
    #expect(device.ops().filter { $0 == .deleteObject }.count == before)
}

@Test func silentTruncationIsDetectedAndCleanedUp() async throws {
    let device = FakeDevice()
    device.truncateAt = 10_000   // 模拟 FAT32 静默截断
    let session = try makeSession(device)
    let file = try tempDir().appendingPathComponent("x.bin")
    try Data.pattern(20_000).write(to: file)

    do {
        _ = try await session.upload(file: file, name: "x.bin", storage: FakeDevice.storage, parent: PTPHandle.root,
                                     progress: TransferProgress(), preferChunked: false)
        Issue.record("应该抛出校验错误")
    } catch let TransferError.verificationFailed(expected, actual) {
        #expect(expected == 20_000 && actual == 10_000)
    }
    #expect(device.objectCount == 0)
}

@Test func zeroByteUploadToleratesGeneralError() async throws {
    let device = FakeDevice()
    let session = try makeSession(device)
    let file = try tempDir().appendingPathComponent("empty.txt")
    try Data().write(to: file)
    _ = try await session.upload(file: file, name: "empty.txt", storage: FakeDevice.storage, parent: PTPHandle.root,
                                 progress: TransferProgress(), preferChunked: false)
    #expect(device.find(["empty.txt"])?.data.isEmpty == true)
}

@Test func resolvesPathByNames() async throws {
    let device = FakeDevice()
    let a = device.add("A", folder: true)
    let b = device.add("B", in: a, folder: true)
    let session = try makeSession(device)
    let path = try await session.resolve(path: ["A", "B"], storage: FakeDevice.storage, priority: .interactive)
    #expect(path?.map(\.handle) == [a, b])
    let missing = try await session.resolve(path: ["A", "C"], storage: FakeDevice.storage, priority: .interactive)
    #expect(missing == nil)
}

// MARK: - 队列

@MainActor
private func waitForFinish(_ t: Transfer) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in t.onFinish { _ in c.resume() } }
}

@MainActor
private func makeQueue(_ session: MTPSession?, available: @escaping @MainActor () -> Bool = { true }) -> TransferQueue {
    TransferQueue(storeURL: nil) { _ in
        guard let session, available() else { return nil }
        return .init(session: session, storages: [], name: "Fake")
    }
}

@MainActor
@Test func queueDownloadsFolderTree() async throws {
    let device = FakeDevice()
    let a = device.add("A", folder: true)
    device.add("x.bin", in: a, data: .pattern(20_000, seed: 1))
    let b = device.add("B", in: a, folder: true)
    device.add("y.bin", in: b, data: .pattern(5_000, seed: 2))
    device.add("empty", in: b, folder: true)
    let session = try makeSession(device)
    let queue = makeQueue(session)
    let dest = try tempDir().appendingPathComponent("A")

    let folder = try await session.object(a, priority: .interactive)
    let t = queue.download(folder, from: [], deviceID: "fake", deviceName: "Fake", to: dest)
    await waitForFinish(t)

    #expect(t.state == .completed)
    #expect(try Data(contentsOf: dest.appendingPathComponent("x.bin")) == .pattern(20_000, seed: 1))
    #expect(try Data(contentsOf: dest.appendingPathComponent("B/y.bin")) == .pattern(5_000, seed: 2))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("B/empty").path))
    #expect(t.progress.snapshot.completedFiles == 2)
    #expect(t.progress.snapshot.completedBytes == 25_000)
    // 没有留下临时文件
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("x.bin.pierdownload").path))
}

@MainActor
@Test func queueUploadsFolderTreeAndSkipsDBICollisions() async throws {
    let device = FakeDevice()
    let session = try makeSession(device, manufacturer: "Nintendo")   // DBI 规则：判重忽略非 ASCII
    let queue = makeQueue(session)
    let src = try tempDir().appendingPathComponent("Roms")
    let fm = FileManager.default
    try fm.createDirectory(at: src.appendingPathComponent("gba"), withIntermediateDirectories: true)
    try Data.pattern(3_000).write(to: src.appendingPathComponent("gba/a.gba"))
    try Data.pattern(9_000).write(to: src.appendingPathComponent("游戏.nsp"))
    try Data.pattern(10).write(to: src.appendingPathComponent("存档.nsp"))   // 和 游戏.nsp 冲突，应被跳过
    try Data().write(to: src.appendingPathComponent(".DS_Store"))          // 隐藏文件不上传

    let t = queue.upload(src, to: [], storageID: FakeDevice.storage, deviceID: "fake", deviceName: "Fake")
    await waitForFinish(t)

    #expect(t.state == .completed)
    #expect(device.find(["Roms", "gba", "a.gba"])?.data == .pattern(3_000))
    #expect(t.skipped.count == 1)
    #expect(device.find(["Roms", ".DS_Store"]) == nil)
    #expect(t.createdObject?.name == "Roms")
    #expect(t.createdObject?.isFolder == true)
}

@MainActor
@Test func queueRejectsTopLevelNameConflict() async throws {
    let device = FakeDevice()
    device.add("Save.bin", data: .pattern(10))
    let session = try makeSession(device)
    let queue = makeQueue(session)
    let file = try tempDir().appendingPathComponent("save.BIN")
    try Data.pattern(10).write(to: file)

    let t = queue.upload(file, to: [], storageID: FakeDevice.storage, deviceID: "fake", deviceName: "Fake")
    await waitForFinish(t)
    #expect(t.state.isFailed)
}

@MainActor
@Test func queueReplacesExistingRemoteItem() async throws {
    let device = FakeDevice()
    device.add("a.bin", data: .pattern(10))
    let session = try makeSession(device)
    let queue = makeQueue(session)
    let file = try tempDir().appendingPathComponent("a.bin")
    try Data.pattern(500, seed: 9).write(to: file)

    let t = queue.upload(file, to: [], storageID: FakeDevice.storage, deviceID: "fake", deviceName: "Fake", replaceExisting: true)
    await waitForFinish(t)
    #expect(t.state == .completed)
    #expect(device.find(["a.bin"])?.data == .pattern(500, seed: 9))
}

@MainActor
@Test func queueWaitsForDeviceAndResumes() async throws {
    let device = FakeDevice()
    let h = device.add("a.bin", data: .pattern(30_000))
    let session = try makeSession(device)
    var available = false
    let queue = makeQueue(session) { available }
    let dest = try tempDir().appendingPathComponent("a.bin")
    let object = try await session.object(h, priority: .interactive)

    let t = queue.download(object, from: [], deviceID: "fake", deviceName: "Fake", to: dest)
    #expect(t.state == .waitingForDevice)
    available = true
    queue.devicesDidChange()
    await waitForFinish(t)
    #expect(t.state == .completed)
    #expect(try Data(contentsOf: dest) == .pattern(30_000))
}

@MainActor
@Test func cancelRemovesPartialDownload() async throws {
    let device = FakeDevice(delay: .milliseconds(20))
    let h = device.add("slow.bin", data: .pattern(200_000))
    let session = try makeSession(device)
    let queue = makeQueue(session)
    let dest = try tempDir().appendingPathComponent("slow.bin")
    let object = try await session.object(h, priority: .interactive)

    let t = queue.download(object, from: [], deviceID: "fake", deviceName: "Fake", to: dest)
    try await Task.sleep(for: .milliseconds(150))
    queue.cancel(t)
    await waitForFinish(t)
    #expect(t.state == .cancelled)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!FileManager.default.fileExists(atPath: TransferQueue.temporaryURL(for: dest).path))
    #expect(!FileManager.default.fileExists(atPath: dest.path))
}

@MainActor
@Test func pauseKeepsPartialAndResumeFinishes() async throws {
    let device = FakeDevice(delay: .milliseconds(10))
    let h = device.add("p.bin", data: .pattern(120_000))
    let session = try makeSession(device)
    let queue = makeQueue(session)
    let dest = try tempDir().appendingPathComponent("p.bin")
    let object = try await session.object(h, priority: .interactive)

    let t = queue.download(object, from: [], deviceID: "fake", deviceName: "Fake", to: dest)
    try await Task.sleep(for: .milliseconds(80))
    queue.pause(t)
    try await Task.sleep(for: .milliseconds(50))
    #expect(t.state == .paused)
    let partial = (try? FileManager.default.attributesOfItem(atPath: TransferQueue.temporaryURL(for: dest).path)[.size] as? Int) ?? 0
    #expect(partial > 0)
    queue.resume(t)
    await waitForFinish(t)
    #expect(t.state == .completed)
    #expect(try Data(contentsOf: dest) == .pattern(120_000))
}

// MARK: - 怪癖

@Test func dbiNameRules() throws {
    let quirks = DeviceQuirks(deviceInfo: try FakeDevice.deviceInfo(manufacturer: "Nintendo"))
    #expect(quirks.isDBI)
    #expect(quirks.problem(with: "存档.nsp", purpose: .create, siblings: ["游戏.nsp"]) != nil)
    #expect(quirks.problem(with: "a.bin", purpose: .create, siblings: ["a中.bin"]) != nil)
    #expect(quirks.problem(with: "b.bin", purpose: .create, siblings: ["a.bin"]) == nil)
    #expect(quirks.problem(with: "新名字", purpose: .rename, siblings: []) != nil)
    #expect(quirks.problem(with: "NEW", purpose: .rename, siblings: ["new"], original: "new") == nil)
    #expect(quirks.uniqueName(for: "a.bin", siblings: ["a.bin", "a 2.bin"]) == "a 3.bin")
    let untitled = quirks.untitledFolderName
    #expect(untitled.unicodeScalars.allSatisfy { $0.isASCII })
}

@Test func androidNameRules() throws {
    let quirks = DeviceQuirks(deviceInfo: try FakeDevice.deviceInfo())
    #expect(!quirks.isDBI)
    #expect(quirks.problem(with: "存档.nsp", purpose: .create, siblings: ["游戏.nsp"]) == nil)
    #expect(quirks.problem(with: "新名字", purpose: .rename, siblings: []) == nil)
    #expect(quirks.problem(with: "A.txt", purpose: .create, siblings: ["a.txt"]) != nil)
    #expect(quirks.problem(with: "a/b", purpose: .create, siblings: []) != nil)
}

@Test func eventContainerParsing() throws {
    var w = PTPDataWriter()
    w.u32(16); w.u16(4); w.u16(0x4002); w.u32(0); w.u32(0x0100_0042)
    let e = try PTPEvent(container: w.data)
    #expect(e.code == .objectAdded)
    #expect(e.parameters == [0x0100_0042])
}
