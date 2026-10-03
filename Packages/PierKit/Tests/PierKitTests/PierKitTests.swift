import Foundation
import Testing
@testable import PierKit

// MARK: - 编解码

@Test func commandContainerLayout() {
    let c = PTPCommand(.getObjectHandles, [0x0001_0001, 0, 0xFFFF_FFFF]).container(transactionID: 7)
    #expect(c.count == 24)
    #expect([UInt8](c.prefix(12)) == [24, 0, 0, 0, 1, 0, 0x07, 0x10, 7, 0, 0, 0])
}

@Test func stringRoundTrip() throws {
    for s in ["", "ascii.bin", "中文名.bin", "emoji-🎮.bin"] {
        var w = PTPDataWriter()
        w.string(s)
        var r = PTPDataReader(w.data)
        #expect(try r.string() == s)
        #expect(r.remaining == 0)
    }
}

@Test func objectInfoRoundTrip() throws {
    let info = PTPObjectInfo(storageID: 0x0001_0001, format: .association, size: 0, parent: 0x0100_0005, filename: "Roms 目录")
    let decoded = try PTPObjectInfo(data: info.encoded())
    #expect(decoded.storageID == 0x0001_0001)
    #expect(decoded.isFolder)
    #expect(decoded.parent == 0x0100_0005)
    #expect(decoded.filename == "Roms 目录")
}

@Test func responseContainerParsing() throws {
    var w = PTPDataWriter()
    w.u32(24); w.u16(3); w.u16(0x2001); w.u32(5)
    w.u32(0x0001_0001); w.u32(0xFFFF_FFFF); w.u32(0x0100_086F)
    let r = try PTPResponse(responseContainer: w.data, data: Data())
    #expect(r.code == .ok)
    #expect(r.parameters == [0x0001_0001, 0xFFFF_FFFF, 0x0100_086F])
}

@Test func truncatedDataThrows() {
    var r = PTPDataReader(Data([1, 2, 3]))
    #expect(throws: PTPError.self) { try r.u32() }
}

@Test func ptpDateParsing() {
    #expect("19700101T080000".ptpDate == nil)
    #expect("20260103T120000".ptpDate != nil)
}

// MARK: - 调度

/// 记录执行顺序的假传输：每条指令耗时 `delay`
final class MockTransport: PTPTransport, @unchecked Sendable {
    let lock = NSLock()
    private(set) var log: [UInt32] = []
    let delay: Duration
    let maxOutDataLength = 1024

    init(delay: Duration = .milliseconds(20)) { self.delay = delay }

    func execute(_ command: PTPCommand, outData: Data?) async throws -> PTPResponse {
        try await Task.sleep(for: delay)
        lock.withLock { log.append(command.parameters.first ?? 0) }
        return PTPResponse(code: .ok)
    }
}

func makeDeviceInfo() throws -> PTPDeviceInfo {
    var w = PTPDataWriter()
    w.u16(100); w.u32(6); w.u16(100); w.string("microsoft.com: 1.0;"); w.u16(0)
    w.u32(1); w.u16(0x1001)   // ops
    w.u32(0); w.u32(0); w.u32(0); w.u32(0)
    w.string("Test"); w.string("Device"); w.string("1.0"); w.string("SN")
    return try PTPDeviceInfo(data: w.data)
}

@Test func interactiveRequestsJumpAheadOfBackground() async throws {
    let transport = MockTransport()
    let session = MTPSession(transport: transport, deviceInfo: try makeDeviceInfo())

    // 先占住通道，再同时排入 3 个后台请求和 1 个前台请求
    async let first: Void = { try await session.send(PTPCommand(.getObjectInfo, [0]), priority: .background) }()
    try await Task.sleep(for: .milliseconds(5))
    async let b1: Void = { try await session.send(PTPCommand(.getObjectInfo, [1]), priority: .background) }()
    async let b2: Void = { try await session.send(PTPCommand(.getObjectInfo, [2]), priority: .background) }()
    try await Task.sleep(for: .milliseconds(2))
    async let fg: Void = { try await session.send(PTPCommand(.getObjectInfo, [99]), priority: .interactive) }()
    _ = try await (first, b1, b2, fg)

    // 前台请求应该紧跟在正在执行的那条之后
    #expect(transport.log.first == 0)
    #expect(transport.log[1] == 99)
}

@Test func oversizedPayloadIsRejectedBeforeTransport() async throws {
    let transport = MockTransport(delay: .zero)
    let session = MTPSession(transport: transport, deviceInfo: try makeDeviceInfo())
    await #expect(throws: PTPError.self) {
        try await session.send(PTPCommand(.sendObject), outData: Data(count: 2048), priority: .userInitiated)
    }
    #expect(transport.log.isEmpty)
}

@Test func cancelledWaiterDoesNotRun() async throws {
    let transport = MockTransport(delay: .milliseconds(50))
    let session = MTPSession(transport: transport, deviceInfo: try makeDeviceInfo())
    async let first: Void = { try await session.send(PTPCommand(.getObjectInfo, [0]), priority: .background) }()
    try await Task.sleep(for: .milliseconds(5))
    let waiter = Task { try await session.send(PTPCommand(.getObjectInfo, [1]), priority: .background) }
    try await Task.sleep(for: .milliseconds(5))
    waiter.cancel()
    _ = try await first
    _ = await waiter.result
    try await Task.sleep(for: .milliseconds(60))
    #expect(transport.log == [0])
}
