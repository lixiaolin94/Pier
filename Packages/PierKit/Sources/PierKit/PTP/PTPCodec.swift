import Foundation

/// PTP 小端数据读取器。越界读取抛出 `PTPError.malformedData`。
public struct PTPDataReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) { bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw PTPError.malformedData("读取越界 @\(offset)") }
        defer { offset += 1 }
        return bytes[offset]
    }
    public mutating func u16() throws -> UInt16 { UInt16(try u8()) | UInt16(try u8()) << 8 }
    public mutating func u32() throws -> UInt32 { UInt32(try u16()) | UInt32(try u16()) << 16 }
    public mutating func u64() throws -> UInt64 { UInt64(try u32()) | UInt64(try u32()) << 32 }

    /// PTP 字符串：u8 字符数（含结尾 0）+ UTF-16LE
    public mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func array16() throws -> [UInt16] {
        let n = Int(try u32())
        guard n * 2 <= remaining else { throw PTPError.malformedData("数组长度 \(n) 超出数据") }
        return try (0..<n).map { _ in try u16() }
    }

    public mutating func array32() throws -> [UInt32] {
        let n = Int(try u32())
        guard n * 4 <= remaining else { throw PTPError.malformedData("数组长度 \(n) 超出数据") }
        return try (0..<n).map { _ in try u32() }
    }
}

/// PTP 小端数据写入器
public struct PTPDataWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    /// PTP 字符串最多 255 个 UTF-16 单元（含结尾 0），超长会被截断
    public mutating func string(_ s: String) {
        guard !s.isEmpty else { u8(0); return }
        var units = Array(s.utf16.prefix(254))
        units.append(0)
        u8(UInt8(units.count))
        units.forEach { u16($0) }
    }
}

/// 一条 PTP 指令
public struct PTPCommand: Sendable, CustomStringConvertible {
    public var operation: PTPOperation
    public var parameters: [UInt32]

    public init(_ operation: PTPOperation, _ parameters: [UInt32] = []) {
        precondition(parameters.count <= 5, "PTP 指令最多 5 个参数")
        self.operation = operation
        self.parameters = parameters
    }

    /// 编码成 PTP USB 命令 container（ImageCaptureCore 的 requestSendPTPCommand 需要这个格式）
    public func container(transactionID: UInt32) -> Data {
        var w = PTPDataWriter()
        w.u32(UInt32(12 + 4 * parameters.count))
        w.u16(1)   // 命令块
        w.u16(operation.rawValue)
        w.u32(transactionID)
        parameters.forEach { w.u32($0) }
        return w.data
    }

    public var description: String {
        "\(operation)(\(parameters.map { String(format: "0x%08X", $0) }.joined(separator: ", ")))"
    }
}

/// 一条 PTP 指令的执行结果
public struct PTPResponse: Sendable {
    public var code: PTPResponseCode
    public var parameters: [UInt32]
    /// 数据阶段的负载（不含 container 头）
    public var data: Data

    public init(code: PTPResponseCode, parameters: [UInt32] = [], data: Data = Data()) {
        self.code = code
        self.parameters = parameters
        self.data = data
    }

    /// 解析 PTP USB 响应 container（type = 3）
    public init(responseContainer: Data, data: Data) throws {
        var r = PTPDataReader(responseContainer)
        let length = Int(try r.u32())
        let type = try r.u16()
        guard type == 3 else { throw PTPError.malformedData("响应 container 类型 \(type)") }
        code = PTPResponseCode(rawValue: try r.u16())
        _ = try r.u32()
        var params: [UInt32] = []
        while r.offset + 4 <= min(length, responseContainer.count) { params.append(try r.u32()) }
        parameters = params
        self.data = Self.stripDataContainer(data)
    }

    /// 某些情况下数据阶段可能带 12 字节 container 头（type = 2），去掉它
    static func stripDataContainer(_ d: Data) -> Data {
        guard d.count >= 12 else { return d }
        var r = PTPDataReader(d)
        guard let len = try? r.u32(), let type = try? r.u16(), type == 2, Int(len) == d.count else { return d }
        return d.dropFirst(12)
    }
}

public enum PTPError: Error, Sendable, CustomStringConvertible {
    /// 设备返回了非 OK 的响应码
    case response(PTPResponseCode, PTPOperation)
    /// 底层传输出错（ImageCaptureCore 报错、设备断开等）
    case transport(String)
    /// 指令超时无响应
    case timeout(PTPOperation)
    /// 数据格式不对
    case malformedData(String)
    /// 要发送的数据超过单条指令上限
    case payloadTooLarge(Int)
    /// 会话已关闭
    case sessionClosed

    public var description: String {
        switch self {
        case let .response(code, op): "指令 \(op) 失败：\(code)"
        case let .transport(msg): "传输错误：\(msg)"
        case let .timeout(op): "指令 \(op) 超时"
        case let .malformedData(msg): "数据格式错误：\(msg)"
        case let .payloadTooLarge(n): "数据过大（\(n) 字节）"
        case .sessionClosed: "会话已关闭"
        }
    }

    public var responseCode: PTPResponseCode? {
        if case let .response(code, _) = self { return code }
        return nil
    }
}
