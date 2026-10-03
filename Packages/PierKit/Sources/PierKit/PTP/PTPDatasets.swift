import Foundation

/// GetDeviceInfo 数据集
public struct PTPDeviceInfo: Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operationsSupported: Set<UInt16>
    public var eventsSupported: Set<UInt16>
    public var devicePropertiesSupported: Set<UInt16>
    public var captureFormats: [UInt16]
    public var playbackFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(data: Data) throws {
        var r = PTPDataReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDescription = try r.string()
        functionalMode = try r.u16()
        operationsSupported = Set(try r.array16())
        eventsSupported = Set(try r.array16())
        devicePropertiesSupported = Set(try r.array16())
        captureFormats = try r.array16()
        playbackFormats = try r.array16()
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = try r.string()
        serialNumber = try r.string()
    }

    public func supports(_ op: PTPOperation) -> Bool { operationsSupported.contains(op.rawValue) }

    /// 是否是 MTP 设备（Microsoft 厂商扩展，或支持 MTP 对象属性指令）
    public var isMTP: Bool {
        vendorExtensionID == 0x0000_0006 || vendorExtensionDescription.contains("microsoft.com") || supports(.getObjectPropsSupported)
    }
}

/// GetStorageInfo 数据集
public struct PTPStorageInfo: Sendable {
    public enum AccessCapability: UInt16, Sendable {
        case readWrite = 0, readOnlyWithoutDeletion = 1, readOnlyWithDeletion = 2
    }

    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: AccessCapability
    public var maxCapacity: UInt64
    public var freeSpace: UInt64
    public var freeSpaceInObjects: UInt32
    public var storageDescription: String
    public var volumeLabel: String

    public init(data: Data) throws {
        var r = PTPDataReader(data)
        storageType = try r.u16()
        filesystemType = try r.u16()
        accessCapability = AccessCapability(rawValue: try r.u16()) ?? .readOnlyWithoutDeletion
        maxCapacity = try r.u64()
        freeSpace = try r.u64()
        freeSpaceInObjects = try r.u32()
        storageDescription = try r.string()
        volumeLabel = try r.string()
    }
}

/// GetObjectInfo / SendObjectInfo 数据集
public struct PTPObjectInfo: Sendable {
    public var storageID: UInt32
    public var format: PTPObjectFormat
    public var protectionStatus: UInt16
    /// 32 位大小；大于 4 GB 的对象这里是 0xFFFFFFFF，需要另读 MTP 属性 0xDC04
    public var compressedSize: UInt32
    public var parent: UInt32
    public var associationType: UInt16
    public var filename: String
    public var captureDate: String
    public var modificationDate: String

    public var isFolder: Bool { format == .association }

    public init(storageID: UInt32, format: PTPObjectFormat, size: UInt64, parent: UInt32, filename: String) {
        self.storageID = storageID
        self.format = format
        protectionStatus = 0
        compressedSize = UInt32(min(size, 0xFFFF_FFFF))
        self.parent = parent
        associationType = format == .association ? 1 : 0
        self.filename = filename
        captureDate = ""
        modificationDate = ""
    }

    public init(data: Data) throws {
        var r = PTPDataReader(data)
        storageID = try r.u32()
        format = PTPObjectFormat(rawValue: try r.u16())
        protectionStatus = try r.u16()
        compressedSize = try r.u32()
        _ = try r.u16()                         // ThumbFormat
        for _ in 0..<6 { _ = try r.u32() }      // ThumbCompressedSize … ImageBitDepth
        parent = try r.u32()
        associationType = try r.u16()
        _ = try r.u32()                         // AssociationDesc
        _ = try r.u32()                         // SequenceNumber
        filename = try r.string()
        captureDate = (try? r.string()) ?? ""
        modificationDate = (try? r.string()) ?? ""
    }

    public func encoded() -> Data {
        var w = PTPDataWriter()
        w.u32(storageID)
        w.u16(format.rawValue)
        w.u16(protectionStatus)
        w.u32(compressedSize)
        w.u16(0)
        for _ in 0..<6 { w.u32(0) }
        w.u32(parent)
        w.u16(associationType)
        w.u32(0)
        w.u32(0)
        w.string(filename)
        w.string(captureDate)
        w.string(modificationDate)
        w.string("")   // Keywords
        return w.data
    }
}

// DateFormatter 创建成本高、解析线程安全，全局复用一个
private let ptpDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd'T'HHmmss"
    return f
}()

extension String {
    /// PTP 日期 "YYYYMMDDThhmmss[.s][Z|±hhmm]" → Date。设备给的 1970 年视为无效。
    public var ptpDate: Date? {
        guard count >= 15 else { return nil }
        guard let d = ptpDateFormatter.date(from: String(prefix(15))), d.timeIntervalSince1970 > 86_400 * 2 else { return nil }
        return d
    }
}
