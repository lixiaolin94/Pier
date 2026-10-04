import Foundation
@preconcurrency import ImageCaptureCore
import os

private let log = Logger(subsystem: "work.xiaolin.Pier", category: "Device")

/// 一台已连接的 MTP 设备（界面层模型，只在主线程访问）
@MainActor
public final class MTPDevice: Identifiable {
    public enum State: Sendable {
        case connecting
        case ready
        case failed(String)
    }

    /// 本次连接内唯一的 ID（ImageCaptureCore 的 UUID）
    public let id: String
    /// 跨连接稳定的标识：厂商 ID + 产品 ID + 序列号，用于收藏、偏好设置
    public let persistentID: String
    public let name: String
    public private(set) var state: State = .connecting
    public private(set) var session: MTPSession?
    public private(set) var storages: [MTPStorage] = []

    fileprivate let camera: ICCameraDevice
    fileprivate var openContinuation: CheckedContinuation<Void, Error>?

    fileprivate init(camera: ICCameraDevice) {
        self.camera = camera
        id = camera.uuidString ?? UUID().uuidString
        persistentID = String(format: "%04X:%04X:", camera.usbVendorID, camera.usbProductID) + (camera.serialNumberString ?? id)
        name = camera.name ?? "MTP 设备"
    }

    public var deviceInfo: PTPDeviceInfo? { session?.deviceInfo }
    public var quirks: DeviceQuirks? { session?.quirks }
    public var isReady: Bool { if case .ready = state { true } else { false } }

    fileprivate var probing = false
    fileprivate var storageReloadTask: Task<Void, Never>?

    /// 重新读取存储列表（容量等）
    public func reloadStorages() async throws {
        guard let session else { return }
        storages = try await session.storages()
        DeviceManager.shared.notifyChange(self)
    }

    fileprivate func set(state: State, session: MTPSession? = nil, storages: [MTPStorage]? = nil) {
        self.state = state
        if let session { self.session = session }
        if let storages { self.storages = storages }
    }
}

/// 发现并管理 MTP 设备。设备列表变化时发出 `DeviceManager.devicesDidChange` 通知。
@MainActor
public final class DeviceManager: NSObject {
    public static let shared = DeviceManager()

    /// 设备增删、状态变化、存储变化都会发这个通知；`object` 是 DeviceManager，userInfo["device"] 是变化的设备（如有）
    public static let devicesDidChange = Notification.Name("work.xiaolin.Pier.devicesDidChange")
    /// 设备发来 PTP 事件（对象增删等）。userInfo["device"] 是 MTPDevice，userInfo["event"] 是 PTPEvent
    public static let deviceEvent = Notification.Name("work.xiaolin.Pier.deviceEvent")

    public private(set) var devices: [MTPDevice] = []

    private let browser = ICDeviceBrowser()
    private var started = false

    public func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
        log.info("ICDeviceBrowser started")
    }

    public func device(withID id: String) -> MTPDevice? { devices.first { $0.id == id } }

    /// 按持久标识找已就绪的设备（传输续传、收藏、窗口恢复用）
    public func readyDevice(persistentID: String) -> MTPDevice? {
        devices.first { $0.persistentID == persistentID && $0.isReady }
    }

    /// 退出前关闭所有会话，把设备干净地交还给 ptpcamerad（进程被强行结束时设备可能一直处于占用状态）
    public func closeAllSessions() {
        for device in devices { device.camera.requestCloseSession() }
    }

    /// 重新连接：关闭会话后重新打开。用于设备长时间无响应之后恢复。
    public func reconnect(_ device: MTPDevice) {
        let camera = device.camera
        log.info("reconnecting \(device.name, privacy: .public)")
        camera.requestCloseSession()
        remove(device)
        Task {
            try? await Task.sleep(for: .seconds(1))
            connect(camera)
        }
    }

    /// 某条指令超时后：用 GetDeviceInfo 探一下，设备仍无响应就重新连接
    fileprivate func handleTimeout(_ device: MTPDevice) {
        guard !device.probing, let session = device.session, devices.contains(where: { $0 === device }) else { return }
        device.probing = true
        log.error("command timed out on \(device.name, privacy: .public), probing")
        Task {
            defer { device.probing = false }
            do {
                _ = try await session.send(PTPCommand(.getDeviceInfo), priority: .interactive)
            } catch {
                guard devices.contains(where: { $0 === device }) else { return }
                reconnect(device)
            }
        }
    }

    fileprivate func handle(_ event: PTPEvent, from device: MTPDevice) {
        log.info("event \(event.description, privacy: .public) from \(device.name, privacy: .public)")
        switch event.code {
        case .storeAdded, .storeRemoved, .storageInfoChanged, .storeFull:
            // 合并短时间内的多个事件
            device.storageReloadTask?.cancel()
            device.storageReloadTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                try? await device.reloadStorages()
            }
        default:
            break
        }
        NotificationCenter.default.post(name: Self.deviceEvent, object: self, userInfo: ["device": device, "event": event])
    }

    /// 关闭会话（"推出"）。设备仍插着，但从列表中移除，直到重新插拔。
    public func eject(_ device: MTPDevice) {
        device.camera.requestCloseSession()
        remove(device)
    }

    fileprivate func notifyChange(_ device: MTPDevice? = nil) {
        NotificationCenter.default.post(name: Self.devicesDidChange, object: self, userInfo: device.map { ["device": $0] })
    }

    private func remove(_ device: MTPDevice) {
        devices.removeAll { $0 === device }
        notifyChange()
    }

    private func connect(_ camera: ICCameraDevice) {
        // Apple 设备（iPhone/iPad）也会以相机身份出现，它们不是 MTP，避免去开会话
        guard camera.usbVendorID != 0x05AC else { return }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else { return }
        guard !devices.contains(where: { $0.camera === camera }) else { return }

        let device = MTPDevice(camera: camera)
        devices.append(device)
        camera.delegate = self
        notifyChange(device)
        log.info("connecting \(device.name, privacy: .public) \(device.persistentID, privacy: .public)")

        Task {
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    device.openContinuation = c
                    camera.requestOpenSession()
                }
                let transport = makeTransport(camera, for: device)
                let infoResp = try await transport.execute(PTPCommand(.getDeviceInfo), outData: nil)
                guard infoResp.code == .ok else { throw PTPError.response(infoResp.code, .getDeviceInfo) }
                let info = try PTPDeviceInfo(data: infoResp.data)
                guard info.isMTP else {
                    // 普通 PTP 相机：不是我们要管的设备
                    log.info("\(device.name, privacy: .public) is not MTP, ignored")
                    try? await camera.requestCloseSession()
                    remove(device)
                    return
                }
                let session = MTPSession(transport: transport, deviceInfo: info)
                let storages = try await session.storages()
                device.set(state: .ready, session: session, storages: storages)
                log.info("ready \(device.name, privacy: .public): \(storages.count) storages")
            } catch {
                log.error("connect failed: \(String(describing: error), privacy: .public)")
                device.set(state: .failed(String(describing: error)))
            }
            notifyChange(device)
        }
    }

    private func makeTransport(_ camera: ICCameraDevice, for device: MTPDevice) -> ImageCaptureTransport {
        ImageCaptureTransport(device: camera) { [weak self, weak device] in
            Task { @MainActor in
                if let self, let device { self.handleTimeout(device) }
            }
        }
    }

    private func device(for icDevice: ICDevice) -> MTPDevice? {
        devices.first { $0.camera === icDevice }
    }
}

// MARK: - ICDeviceBrowserDelegate / ICCameraDeviceDelegate
// ImageCaptureCore 在主线程回调

extension DeviceManager: ICDeviceBrowserDelegate {
    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            if let camera = device as? ICCameraDevice { connect(camera) }
        }
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            if let d = self.device(for: device) { remove(d) }
        }
    }
}

extension DeviceManager: ICCameraDeviceDelegate {
    nonisolated public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let d = self.device(for: device), let c = d.openContinuation else { return }
            d.openContinuation = nil
            if let error { c.resume(throwing: PTPError.transport(error.localizedDescription)) } else { c.resume() }
        }
    }

    nonisolated public func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated {
            if let d = self.device(for: device) { remove(d) }
        }
    }

    nonisolated public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated public func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        log.error("device error: \(String(describing: error), privacy: .public)")
    }
    nonisolated public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard let event = try? PTPEvent(container: eventData) else { return }
        MainActor.assumeIsolated {
            if let d = self.device(for: camera), d.isReady { handle(event, from: d) }
        }
    }
    nonisolated public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
