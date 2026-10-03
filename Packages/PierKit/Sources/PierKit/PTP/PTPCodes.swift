import Foundation

/// PTP / MTP 操作码（含 MTP 与 Android 扩展）
public struct PTPOperation: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo = Self(rawValue: 0x1001)
    public static let openSession = Self(rawValue: 0x1002)
    public static let closeSession = Self(rawValue: 0x1003)
    public static let getStorageIDs = Self(rawValue: 0x1004)
    public static let getStorageInfo = Self(rawValue: 0x1005)
    public static let getObjectHandles = Self(rawValue: 0x1007)
    public static let getObjectInfo = Self(rawValue: 0x1008)
    public static let getObject = Self(rawValue: 0x1009)
    public static let deleteObject = Self(rawValue: 0x100B)
    public static let sendObjectInfo = Self(rawValue: 0x100C)
    public static let sendObject = Self(rawValue: 0x100D)
    public static let moveObject = Self(rawValue: 0x1019)
    public static let copyObject = Self(rawValue: 0x101A)
    public static let getPartialObject = Self(rawValue: 0x101B)

    // Android 扩展
    public static let getPartialObject64 = Self(rawValue: 0x95C1)
    public static let sendPartialObject = Self(rawValue: 0x95C2)
    public static let truncateObject = Self(rawValue: 0x95C3)
    public static let beginEditObject = Self(rawValue: 0x95C4)
    public static let endEditObject = Self(rawValue: 0x95C5)

    // MTP 扩展
    public static let getObjectPropsSupported = Self(rawValue: 0x9801)
    public static let getObjectPropDesc = Self(rawValue: 0x9802)
    public static let getObjectPropValue = Self(rawValue: 0x9803)
    public static let setObjectPropValue = Self(rawValue: 0x9804)
    public static let getObjectPropList = Self(rawValue: 0x9805)
    public static let sendObjectPropList = Self(rawValue: 0x9808)

    public var description: String { String(format: "0x%04X", rawValue) }
}

/// PTP 响应码
public struct PTPResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let ok = Self(rawValue: 0x2001)
    public static let generalError = Self(rawValue: 0x2002)
    public static let sessionNotOpen = Self(rawValue: 0x2003)
    public static let operationNotSupported = Self(rawValue: 0x2005)
    public static let invalidStorageID = Self(rawValue: 0x2008)
    public static let invalidObjectHandle = Self(rawValue: 0x2009)
    public static let storeFull = Self(rawValue: 0x200C)
    public static let accessDenied = Self(rawValue: 0x200F)
    public static let deviceBusy = Self(rawValue: 0x2019)
    public static let invalidParentObject = Self(rawValue: 0x201A)
    public static let invalidParameter = Self(rawValue: 0x201D)
    public static let invalidObjectPropCode = Self(rawValue: 0xA801)
    public static let objectTooLarge = Self(rawValue: 0xA809)

    public var description: String { String(format: "0x%04X", rawValue) }
}

/// MTP 对象属性码
public struct MTPObjectProperty: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let storageID = Self(rawValue: 0xDC01)
    public static let objectFormat = Self(rawValue: 0xDC02)
    public static let objectSize = Self(rawValue: 0xDC04)
    public static let objectFileName = Self(rawValue: 0xDC07)
    public static let dateModified = Self(rawValue: 0xDC09)
    public static let parentObject = Self(rawValue: 0xDC0B)
    public static let name = Self(rawValue: 0xDC44)
}

/// PTP 对象格式码（只列用得到的）
public struct PTPObjectFormat: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let undefined = Self(rawValue: 0x3000)
    public static let association = Self(rawValue: 0x3001)   // 文件夹
}

/// 对象句柄与存储 ID 的特殊值
public enum PTPHandle {
    /// GetObjectHandles 的 parent 参数：存储根目录
    public static let root: UInt32 = 0xFFFF_FFFF
    /// GetObjectHandles 的 format 参数：所有格式
    public static let allFormats: UInt32 = 0
}
