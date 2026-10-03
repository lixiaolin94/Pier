# Pier — 交接上下文

**Pier**（2026-10-03 定名，取"码头"之意：设备插上来就像船靠岸，文件在这里装卸）：一个现代的 macOS 原生 Android MTP 文件传输 app，定位是 Android File Transfer（AFT）的现代替代品。
- **通用**：面向所有 MTP 设备（Android 手机/平板、Switch 上的 DBI 等），不只是 DBI。早期叫 SwitchMTP，是因为最初的需求是给 DBI 传文件。2026-10-03 起仓库迁到 `/Users/xiaolin/Documents/Xcode/Pier`（带完整历史，默认分支 `main`）；旧目录 `SwitchMTP` 只作存档。
- **学习 AFT 的体验**：插上设备自动弹出窗口、即插即用。
- **更现代**：**AppKit 原生界面（不用 SwiftUI）**，Finder 风格的单窗口加原生多 tab，支持拖放；交互优先，前台保持流畅，耗时任务放后台并保证可靠。功能范围见 [docs/SCOPE.md](docs/SCOPE.md)。
- 技术路线：**方案 A（ImageCaptureCore + requestSendPTPCommand）**，已验证可行，详见末尾「验证记录」。
- 标识：app 名 `Pier`，Bundle ID `work.xiaolin.Pier`。

当前阶段：可行性验证已完成，下一步是正式开发。注意：下面的验证数据都是用 Switch DBI 测的，换成普通 Android 手机时，MTP 行为（文件名、缓存、64 位扩展支持等）需要另外验证。

## 工程结构（2026-10-03 搭好骨架）
- `project.yml`：xcodegen 配置，执行 `xcodegen generate` 生成 `Pier.xcodeproj`（已提交）。`Pier/` 是同步文件夹，增删源文件不用重新生成，只有改 `project.yml` 才需要。
- `Packages/PierKit/`：本地 Swift Package，纯逻辑、不依赖 AppKit，可以 `swift test`。
  - `PTP/`：操作码、编解码（Reader/Writer、命令/响应 container）、数据集（DeviceInfo/StorageInfo/ObjectInfo）。
  - `Session/`：`PTPTransport` 协议；`ChannelScheduler`（按优先级分配指令通道，排队时可取消）；`MTPSession`（`send` 单条、`exclusive` 连续执行一组、`hasWaiters(above:)` 给长任务判断要不要让路）；`MTPOperations`（列目录、分批流式列出、建文件夹、改名、删除、分块读取）。
  - `Device/`：`ImageCaptureTransport`（经 ptpcamerad，带超时，拦截 ≥4 GB 的 outData）、`DeviceManager` + `MTPDevice`（ICDeviceBrowser 发现设备、开会话、GetDeviceInfo 判断是否为 MTP、读存储列表，变化时发 `devicesDidChange` 通知）。
- `Pier/`：AppKit 界面，纯代码，不用 storyboard/xib，Swift 6 严格并发，最低 macOS 13，Bundle ID `work.xiaolin.Pier`。
  - `App/`：`main.swift`、`AppDelegate`（窗口管理）、`MainMenu`（Finder 式菜单与快捷键；`BrowserActions` @objc 协议定义沿响应链分发的动作）。
  - `Browser/`：`BrowserWindowController`（一个窗口/tab：位置、前进/后退历史、工具栏、导航动作）、`BrowserSplitViewController`、`ContentViewController`（列表 + 路径栏 + 状态栏 + 未连接占位页）、`BrowserLocation`。
  - `Sidebar/`：source list，设备 → 存储，⌘单击在新 tab 打开，右键可"在标签页中打开所有存储"、推出。
  - `FileList/`：`NSOutlineView` 列表视图，分批流式显示、可展开文件夹（按需加载）、列排序/显示隐藏、搜索过滤、双击/⌘↓ 进入、⌘双击在新 tab 打开。
- 构建：`xcodebuild -project Pier.xcodeproj -scheme Pier -derivedDataPath build/DerivedData build`，产物在 `build/DerivedData/Build/Products/Debug/Pier.app`。
- 已实机验证（DBI）：设备发现、8 个存储、列目录（Installed games 115 项边读边显示）、展开、导航、返回、原生 tab。
- **下一阶段**（按 docs/SCOPE.md）：传输引擎（下载/上传队列、断点续传、进度）→ 拖放（`NSFilePromiseProvider` / 文件 URL）→ ⌘C/⌘V → 新建文件夹/改名/删除 → Quick Look/打开 → 显示简介 → 设备怪癖档案 → 图标视图 → 窗口状态恢复。
- 已知待办：PTP 事件（对象增删）还没接；指令超时后会话的恢复策略还没做；侧边栏"收藏"分组未做。

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

## 验证记录（2026-10-03，spike 代码：`spike/`）

实验程序：`spike/` 下的 Swift Package 命令行工具 `ptpspike`（用法见 `main.swift` 文件头）。
运行：`cd spike && swift build -c release && .build/release/ptpspike info`。测试时 AFT 未运行，DBI 接口由 ptpcamerad 独占（`UsbExclusiveOwner = ptpcamerad`）。
链路：DBI 是 **USB 2.0 High Speed**（ioreg `UsbLinkSpeed = 480000000`，`bcdUSB = 0x0200`），bulk 实际上限约 40 MB/s。

### 结论速览
| 项目 | 结果 |
|---|---|
| 命令行工具能否拿到设备 | ✅ 能。无 TCC 弹窗、无需 entitlement，不用改成 app |
| ICDeviceBrowser 发现 DBI | ✅ `ICCameraDevice`，name=`Switch`，capabilities = `CanDeleteOneFile` + `CanAcceptPTPCommands` |
| requestSendPTPCommand 原始指令 | ✅ 标准 PTP + MTP 扩展 + Android 扩展全部可用，ptpcamerad 不过滤 |
| 完整目录树 | ✅ 8 个存储全部可遍历；SD 卡 11596 个对象全树 17.3 s |
| 64 位文件大小 | ✅ GetObjectPropValue(0xDC04) 正确返回 >4 GB 大小 |
| 读取吞吐 | ✅ 38.5 MB/s（块 ≥16 MB），2.49 GB 完整读取 35.8 MB/s，已贴近 USB 2.0 上限 |
| 写入吞吐 | ✅ 单次 SendObject 30.7–32.5 MB/s；SendPartialObject 分段写 30–31 MB/s |
| 单次 SendObject 上限 | ⚠️ **4294967283 字节（4 GB−13）**，超过会让本进程崩溃（XPC 限制，见下） |
| ICC 自带 contents/mediaFiles | ❌ 都是 0 项，完全不可用，必须走原始 PTP |

### 问题 1：能不能看到 DBI
- mask = `ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal`（0x101）即可。`didAdd`：`name=Switch type=0x101 class=ICCameraDevice transport=ICTransportTypeUSB usbVID=0x057E usbPID=0x201D`，serial `XAW00000000000`。
- `requestOpenSession` 立即成功（0.00 s），随后很快收到 `deviceDidBecomeReady`。打开会话前后都不需要授权（macOS 上 ICC 没有授权 API，那些只在 iOS 上有）。
- 发送 PTP 指令不需要等 deviceDidBecomeReady。框架已替我们开好 PTP session，**不要再发 OpenSession**。

### 问题 2：MTP 指令与目录树
**指令格式**（已确认）：`ptpCommand` 是完整的 PTP USB 命令 container（`len u32, type=1 u16, code u16, txid u32, params…`，小端）。completion 的**第一个参数是数据阶段（不带 container 头的原始负载）**，第二个参数是 response container（`len=12+4n, type=3, code, txid, params`）。outData 同样是不带头的原始负载。
**GetDeviceInfo**：`StandardVersion=100 VendorExt=0x6 desc="microsoft.com: 1.0; android.com: 1.0;"`，Manufacturer=Nintendo，Model=Switch，Version=19.0.1。
OperationsSupported（27 条）：`1001 1002 1003 1004 1005 1007 1008 1009 100B 100C 100D 1014 1015 1016 1019 101B 95C1 95C2 95C3 95C4 95C5 9801 9802 9803 9804 9805 9808`。
即 GetPartialObject64(95C1)、SendPartialObject(95C2)、TruncateObject(95C3)、Begin/EndEditObject(95C4/95C5)、SendObjectPropList(9808)、DeleteObject(100B)、MoveObject(1019) 都有。Events：`4002 4003 4004 4005 400E 4007 C801`。
**存储**（GetStorageIDs → GetStorageInfo）：
| ID | 描述 | access |
|---|---|---|
| 0x00010001 | 1: SD Card（普通文件系统，可读写） | 0 读写 |
| 0x00010002 | 2: Nand USER | 1 只读 |
| 0x00010003 | 3: Nand SYSTEM | 1 只读 |
| 0x00010004 | 4: Installed games（已装游戏导出成虚拟 NSP） | 0 |
| 0x00010005 | 5: SD Card install（**安装目录，禁止测试写入**） | 0 |
| 0x00010006 | 6: NAND install（**安装目录，禁止测试写入**） | 0 |
| 0x00010007 | 7: Saves | 0 |
| 0x00010008 | 8: Album（空，容量 0） | 2 |
**遍历**：GetObjectHandles(storage, 0, parent；根 = 0xFFFFFFFF) + GetObjectInfo 正常。SD 卡全树（深度 4）11596 个对象（2457 目录 / 9139 文件），每个文件额外读一次 0xDC04，共约 2 万条指令，用时 17.33 s（约 0.85 ms/条）。如需更快可试 GetObjectPropList(parent, 0, 0xFFFFFFFF, 0, depth=1) 批量取。
**64 位大小**：>4 GB 的文件 ObjectInfo 里 size 为 0xFFFFFFFF，GetObjectPropValue(h, 0xDC04) 返回 u64 真值，例如 `SUPER MARIO ODYSSEY [0100000000010000][v0][Base].nsp` = 5611007880。
GetObjectPropsSupported(0x3000) = `DC41 PersistentUID, DC01 StorageID, DC0B ParentObject, DC02 ObjectFormat, DC04 ObjectSize, DC44 Name`。**没有日期属性**，ObjectInfo 里的修改时间全是 `19700101T080000`。GetObjectPropList(h, 0, 0xFFFFFFFF, 0, 0) 可用（返回 6 个元素）。
**写入**（只写在 `1: SD Card/SwitchMTP-spike/`）：SendObjectInfo(storage, parent) 的 response 参数 = `[storage, parent, newHandle]`；目录用 format 0x3001、AssociationType 1 创建。64 KB 文件 SendObject 后用 GetObject 回读，内容一致。
**对照**：`ICCameraDevice.contents` 顶层 0 项，`mediaFiles` 0 项（即使等到 deviceDidBecomeReady）。

### 问题 3：吞吐量（release 构建，不落盘）
**读取**（GetPartialObject，Silksong Base NSP，读 512 MB）：
| 块大小 | 吞吐 | 单块延迟中位 |
|---|---|---|
| 1 MB | 28.56 MB/s | 34.8 ms |
| 4 MB | 35.78 MB/s | 111.4 ms |
| 16 MB | 38.49 MB/s | 415.3 ms |
| 32 MB | 38.88 MB/s | 822.3 ms |
| 64 MB | 38.50 MB/s | 1656 ms |
- 完整读取 2492437328 字节（2.49 GB，16 MB 块）：66.31 s = **35.84 MB/s**。
- GetPartialObject64(0x95C1) 跨 4 GB 偏移（SMO Base 从 5000 MB 起读 256 MB）：35.73 MB/s，正常。
- 传输时 ptpcamerad CPU 约 4%，本进程约 1%；XPC 中转对吞吐基本没有影响，瓶颈在 USB 2.0 和 Switch 端（读的是 DBI 实时打包的虚拟 NSP）。
- 建议正式实现用 8–16 MB 块：吞吐已饱和，进度更新也够细。

**写入**：
- 单次 SendObject（mmap 本地文件作为 outData）：256 MB 31.37 MB/s；1 GB 32.46 MB/s；4294967283 字节 133.4 s = 30.70 MB/s。回读校验（ObjectSize + 末尾 1 MB）一致。
- 分段写（首块 SendObject 64 MB → BeginEditObject → SendPartialObject 64 MB × N → EndEditObject）：256 MB 30.08 MB/s，4.6 GB 30.99 MB/s。在 SD 卡普通目录可用。
- 内存：单次 SendObject 1 GB 时 ptpcamerad 的 RSS 线性涨到约 1 GB，但 **phys footprint 始终 15 MB**，本进程 footprint 约 1.3 MB。也就是说 XPC 走的是共享映射，没有真正复制，大文件不会吃内存。

### 关键限制与 DBI 怪癖（正式开发必须处理）
1. **ICC 单条指令的 outData ≤ 4 GB−1**：ImageCaptureCore 把 NSData 内联进 XPC 消息，`_xpc_data_serialize` 遇到 ≥ 2^32 字节就 `_xpc_api_misuse` 触发 **SIGTRAP 崩溃（无法 catch）**。本地用匿名 XPC 连接复现：4294967295 能过，4294967296 崩溃。再算上 PTP container 头的 12 字节，单次 SendObject 的实际上限是 4294967283 字节（已实测成功）。崩溃栈：`-[PTPCameraDeviceManager sendDevicePTPCommandImp:]` → `NSXPCConnection` → `_xpc_data_serialize` → `_xpc_api_misuse`。正式代码必须在发送前检查大小。
2. **超过 4 GB 的上传只能分段**：SendObjectInfo + 首块 SendObject + BeginEditObject + SendPartialObject(64 位偏移) + EndEditObject。在 SD 卡普通目录验证可行（64 位偏移参数被正确处理，没有回绕）。**但 DBI 的安装存储（5/6）是否接受分段写还没验证**（按要求没往安装目录写）。这是方案 A 剩下的唯一大风险，见「下一步」。
3. **SD 卡单文件写到约 4 GB 被截断，而且 DBI 不报错**：4.6 GB 分段写时，所有指令都返回 0x2001，但最终 ObjectSize = 4291821556，4 GB 以后的数据全部丢失（4 GB 之前的数据逐段校验一致）。基本可以确定这张 SD 卡是 **FAT32**（单文件上限 4 GB−1），DBI 写入失败时不返回错误。正式实现：**写完必须回读 ObjectSize 校验**；往 SD 普通目录写 >4 GB 文件前应提示（StorageInfo 的 FilesystemType 统一是 2，判断不出 FAT32/exFAT）。
4. **SendObjectInfo 之后如果没有 SendObject，会留下 0 字节的空文件**（4 次崩溃测试各留下一个）。
5. **重复 handle**：通过 SendObjectInfo 新建的对象，在 DBI 第一次扫描该目录时会再被登记一次（同名文件出现新旧两个 handle，之后不再增长）。正式实现需要按 (parent, name) 去重，或者上传后重新枚举目录。handle 只在 DBI 的这次 MTP 会话内有效；ptpcamerad 会一直保持 PTP 会话，所以多次运行本工具时 handle 是连续的。
6. 没有修改时间属性；Album 存储为空。
7. 根目录对象的 ObjectInfo.ParentObject 填的是**存储 ID**（如 0x00010001），不是规范里的 0 / 0xFFFFFFFF。
8. 更多增删改查相关的怪癖见下一节。

### 建议：选方案 A
理由：
- 三个问题都得到肯定答案：设备可见、MTP 全指令透传（含 Android 64 位扩展）、读写吞吐都已接近 USB 2.0 上限（读 36–39 MB/s，写 31–32 MB/s），XPC 中转几乎没有损耗。
- 不用跟 ptpcamerad 抢接口，彻底告别 `aft-mtp` 那套杀进程的做法；命令行工具无需任何权限即可工作，后续可以试 App Sandbox。
- 方案 B 的速度优势在 USB 2.0 链路下不存在（上限一样），却要永远跟受 SIP 保护的 ptpcamerad 抢接口。

**下一步（新会话）**：
1. **先补验证 >4 GB 游戏安装**（需要用户明确同意往 DBI 安装存储写入，并准备一个 >4 GB 的 NSP）：在 `5: SD Card install` 用 SendObjectInfo（size 字段填 0xFFFFFFFF，或者用 SendObjectPropList 0x9808 带 64 位 ObjectSize）+ 首块 SendObject + SendPartialObject 安装，看 DBI 能否识别并装好。≤4 GB 的 NSP 可以单次 SendObject，按目前数据应该没问题（同样建议先用一个小游戏实测安装）。
   - 如果 DBI 安装存储不接受分段写：>4 GB 游戏只能用方案 B 的 USB 直连路径（或者让用户在 DBI 里改用别的安装方式），其余功能仍走方案 A。
2. 开始正式 app：SwiftUI + ImageCaptureCore 的 PTP/MTP 封装层（可以直接复用 `spike/` 里的 Reader/Writer、数据集解析和 `send()`），注意事项见上面「关键限制与 DBI 怪癖」。
3. 测试残留：已清理（见下方「增删改查稳定性」）。

### 增删改查稳定性（2026-10-03 补充，`ptpspike crud / probe-* / rmtest`）
所有写和删都只发生在 `1: SD Card/SwitchMTP-spike/` 下，代码里有保护：删除前沿 parent 链确认对象在测试目录内。测试结束后已用 `rmtest` 递归删除整个测试目录（子项 20 个，0 失败），SD 根目录恢复为原来的 20 项。

**随机压测**（`crud … 300`）：300 轮，每轮新建（1 B–2 MB 随机内容，ASCII/中文/emoji 文件名）+ GetObject 全量回读校验，再随机挑一个文件做改写/截断/改名/移动/删除，每 20 轮按 handle 核对目录列表。约 3500 条指令，58.8 s，**没有挂起、断连或数据错误**：
| 操作 | 成功/失败 | 平均延迟 | 说明 |
|---|---|---|---|
| create（SendObjectInfo+SendObject） | 300/0 | 125 ms | 小文件也有约 110 ms 固定开销，应该是 DBI 在关闭文件 |
| read（GetObject+校验） | 300/0 | 14 ms | |
| edit（BeginEdit+SendPartialObject+EndEdit，含追加） | 45/0 | 138 ms | |
| truncate（BeginEdit+TruncateObject 0x95C3+EndEdit） | 65/0 | 15 ms | |
| rename（SetObjectPropValue 0xDC07，ASCII 新名） | 37/0 | 49 ms | |
| move（MoveObject，ASCII 文件名） | 15/0 | 18 ms | 语义见下 |
| move（非 ASCII 文件名） | 0/29 | — | 全部 0x2005，属已知限制 |
| delete（DeleteObject） | 300/0 | 24 ms | |
| list-verify | 15/0 | 88 ms | |

**确认的 DBI 行为（正式开发必须处理）**：
1. **文件名按"去掉非 ASCII 字符后的名字"判重**：中文、日文、韩文、emoji、é 等文件名本身都能写，但同一目录里两个名字去字后相同就会冲突，SendObjectInfo 返回 0x2002。例如有了 `游戏.nsp` 之后再建 `存档.nsp` 就失败（两者都是 `.nsp`）；有 `a中.bin` 后 `a文.bin`、`a.bin` 都会失败。上传前要做这个检查，并给出友好提示。
2. **DBI 扫描目录时登记的条目，名字里的非 ASCII 字符会被删掉**（`中文名.bin` 显示成 `.bin`，`emoji-🎮.bin` 显示成 `emoji-.bin`），但用这个 handle 读取正常（DBI 内部记的是真实路径）。也就是说，**SD 卡上原有的中文名文件，在 MTP 里看到的名字是残缺的**。这是 DBI 自身的问题，AFT 也一样。界面上可以提示"名称可能不完整"。
3. **改名成非 ASCII 名字返回 0x2005**；改成 ASCII 名字可以（文件和目录都行，0xDC07/0xDC44 都可用）。**非 ASCII 名字的文件不能 MoveObject**（0x2005）；目录名含非 ASCII 不影响移动。
4. **MoveObject 物理上移动正确，但 DBI 缓存不更新**（用"首次枚举会扫描文件系统"的方法确认了物理位置）：
   - 原 handle 的 ObjectInfo.parent 不变，仍列在原目录里，仍可读；
   - 目标目录如果已经枚举过，移动后**列表里看不到这个文件**（在目标目录新建文件也不会触发重新扫描）；只有首次枚举时才会扫出来；
   - parent 参数传 0 也返回 OK，行为不明。**不要传 0**；
   - 移到已有同名文件的目录返回 0x2005。
   - 正式实现：移动成功后由 app 自己更新目录模型，不要依赖重新枚举。或者干脆先不提供"移动"功能（设备不支持 CopyObject）。
5. **0 字节文件**：SendObject 一定返回 0x2002（outData 传空 Data 或 nil 都一样），但文件其实已经建出来了。上传 0 字节文件时只发 SendObjectInfo 即可，或者把这个 0x2002 当作成功处理。
6. **重复 handle**：在一个还没枚举过的目录里新建文件，之后第一次枚举时 DBI 会再登记一个扫描条目（名字可能被删字）。两个 handle 都能读，删掉其中一个后另一个仍有效，也能再删一次（返回 OK）。删除后，同名的扫描条目偶尔还会留在列表里（300 轮里出现 3 次）。
7. **删除非空目录会递归删除**，没有确认步骤。app 必须自己加确认。
8. **StorageInfo 的剩余空间不会实时更新**：写入约 10 GB 再删除，前后一直显示 39053 MB，应该是 DBI 会话开始时缓存的值。显示剩余空间时要注明，或在 DBI 重连后刷新。
9. SetObjectPropValue 虽然不在 GetObjectPropsSupported 里，但 0xDC07 可以写；GetObjectPropDesc(0xDC07) 返回 0xA80A，GetObjectPropDesc(0xDC44) 显示可写。

**总体判断**：MTP 读写本身很稳（数据零错误，没有挂起）。问题都集中在 DBI 的名字处理和目录缓存上，这些和走方案 A 还是方案 B 无关。正式 app 需要在本地维护目录模型，并做文件名预检。**仍然建议方案 A。**
