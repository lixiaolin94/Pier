# SwitchMTP — 交接上下文

目标：用现代 macOS 技术重写 Android File Transfer（AFT），主要用于和 Switch 上的 **DBI**（MTP 模式）传文件。
当前阶段：**方案 A 可行性验证（spike）**。验证结论写回本文件末尾「验证记录」，供后续会话继续。

## 环境
- macOS 27.0.1（Apple 芯片），Xcode 27.0，Swift 6.4
- DBI 的 USB 信息：idVendor 0x057E（1406，Nintendo），idProduct 0x201D（8221），产品名 `DBI`，序列号 `XAW00000000000`
- 检查连接：`ioreg -p IOUSB -w0 | grep DBI@`
- 查接口被谁独占：`ioreg -r -n DBI -l -w0 | grep UsbExclusiveOwner`

## 已查明的事实（2026-10-03）
1. **AFT 只支持 MTP over USB**，只有 x86_64 版本（1.0.12），要靠 Rosetta 运行。macOS 27 升级后 Rosetta 丢了，AFT 打不开（LaunchServices 报 -10669），之后已手动重装 Rosetta。
2. **DBI 的 MTP 在 macOS 看来是一台 PTP 相机**，系统的 `ptpcamerad`（`/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`，按需启动的 MachService）会独占这个 USB 接口。
3. **`ptpcamerad` 受 SIP 保护**：`launchctl disable gui/501/com.apple.ptpcamerad` 和 `bootout` 都**无效**，被 kill 后会立刻被 launchd 重新拉起。实测会请求它的程序有：`icdd`（开机自启）、Google Drive（有"备份 USB 设备照片"的功能）、照片 App 等。
4. **USB 接口是先占先得**：AFT 一旦拿到独占权，`ptpcamerad` 再怎么重启也抢不走。实测 AFT 一退出，`ptpcamerad` 马上就把 DBI 占走了。
5. 现行的临时方案：`~/bin/aft-mtp`，由 `/Applications/Switch MTP AFT.app`（AppleScript 小程序）在后台调用。做法是"杀掉 ptpcamerad → 打开 AFT → 确认 AFT 拿到独占权，没拿到就重试；AFT 运行期间只在 ptpcamerad 抢走接口时才出手"。副本见 `aft-mtp.reference.sh`。AFT Agent 已经通过把文件改名为 `.disabled` 来禁用。

## 两条技术路线
**方案 A（优先验证）：ImageCaptureCore，跟 ptpcamerad 合作，不跟它抢**
- 用 `ICDeviceBrowser` 发现设备 → `ICCameraDevice` 调 `requestOpenSession` → 用 `requestSendPTPCommand:outData:completion:` 发送原始 PTP/MTP 指令。
- 如果走得通：不用再抢接口，能开 App Sandbox，甚至能上架 App Store。
- 风险：数据要经过 XPC 中转，大文件可能变慢；`ptpcamerad` 可能过滤 MTP 扩展指令，或者 DBI 的非标准行为。

**方案 B（备选）：IOUSBHost 或 libusb 直接操作 USB，自己实现 MTP**（可参考 libmtp、OpenMTP 的 kalam）
- 完全自己掌控，速度最快，但还得先跟 ptpcamerad 抢接口，根本问题没解决。

## 方案 A 要回答的三个问题
1. `ICDeviceBrowser`（要同时开 local + USB 的 browsedDeviceTypeMask）**能不能看到 DBI**？它是 `ICCameraDevice` 吗？能列出哪些 capabilities？
2. 用 `requestSendPTPCommand` 发 MTP 指令，能不能拿到完整的目录树？
   - `GetDeviceInfo` 0x1001、`OpenSession` 0x1002（框架可能已经替你开好了）、`GetStorageIDs` 0x1004、`GetStorageInfo` 0x1005、`GetObjectHandles` 0x1007（参数：storageID, 0 = 所有格式, parent = 0xFFFFFFFF 表示根目录）、`GetObjectInfo` 0x1008、`GetObject` 0x1009、`GetPartialObject` 0x101B
   - MTP 扩展指令：`GetObjectPropsSupported` 0x9801、`GetObjectPropValue` 0x9803（ObjectSize 0xDC04 是 64 位）、`GetObjectPropList` 0x9805
   - 写入：`SendObjectInfo` 0x100C + `SendObject` 0x100D（这是上传，也是 DBI 装游戏的关键）。**先只在一个测试目录里写个小文件，不要往 DBI 的安装目录里写东西。**
   - 对照：ICCameraDevice 自带的 `mediaFiles` 和 `contents` 能看到多少东西（很可能只看得到媒体文件）。
3. **吞吐量**：用 `GetPartialObject` 分块读取一个大文件（≥1 GB），测 MB/s；如果写入可行，也测一下写入速度。跟 AFT 的体感速度对比。

## 注意事项
- 测试前**先退出 AFT**（`osascript -e 'quit app "Android File Transfer"'`），把设备让给 ptpcamerad。方案 A 本来就要求 ptpcamerad 拿着设备。
- ImageCaptureCore 在 macOS 上可能需要 entitlement 或权限弹窗（相机 / USB / 照片）。命令行工具如果因为 TCC 拿不到设备，就改成一个最小的 SwiftUI 或 AppKit app target。
- spike 代码保持简单，放在 `spike/` 目录下，Swift Package 或单文件都可以。
- 用户偏好：简体中文交流；代码标识符保持英文。

## 验证记录
（待填写：每个问题的结论、关键日志或输出、吞吐量数据，以及最终选方案 A 还是方案 B）
