# Pier 功能范围（v1）

> 状态：草案，2026-10-03。背景与技术验证见 [CONTEXT.md](../CONTEXT.md)。
> 标识：app 名 `Pier`，Bundle ID `work.xiaolin.Pier`。

## 产品哲学

1. **交互优先**：任何用户操作都必须立即得到反馈。主线程只做界面，绝不等设备。
2. **前台流畅、后台可靠**：浏览、选择、预览这些前台操作，永远排在大文件传输前面；耗时任务交给后台，进度可见、可取消、失败可重试，退出 app 前会提醒。
3. **像 Finder 一样**：用户已经熟悉的东西（布局、快捷键、拖放、Quick Look、行内改名）尽量照搬，不发明新交互。
4. **AppKit 原生**：不用 SwiftUI。全部采用 AppKit 成熟组件和系统标准行为，新系统上自动获得新外观（比如 macOS 26 的 Liquid Glass），旧系统上照样正常。

## 系统版本

- **最低支持 macOS 13 Ventura（已确认）**。理由：
  - 需要的 AppKit 组件最晚到 macOS 12 才有（`NSSearchToolbarItem`），13 已覆盖；
  - `OSAllocatedUnfairLock`（13+）可以做轻量的线程安全状态；
  - ImageCaptureCore 的 `requestSendPTPCommand:outData:completion:` 只要求 10.15。
- 更新系统才有的能力用 `if #available` 渐进启用，不提高最低版本。
- 用最新 SDK 构建（Xcode 27 / macOS 27 SDK），Swift 6 语言模式，开启严格并发检查。

| 组件 / 能力 | 最低系统 | 用途 |
|---|---|---|
| `NSWindow` 原生 tab（`tabbingMode`、`addTabbedWindow`） | 10.12 | 多 tab |
| `NSSplitViewController` + `NSSplitViewItem(sidebarWithViewController:)` | 10.11 | 侧边栏 + 内容区 |
| `NSWindow.toolbarStyle = .unified`、`NSTrackingSeparatorToolbarItem` | 11 | 全高侧边栏、Finder 式工具栏 |
| `NSTableView.style`（`.sourceList` / `.inset`） | 11 | 侧边栏 / 列表外观 |
| SF Symbols（`NSImage(systemSymbolName:)`） | 11 | 图标 |
| `NSSearchToolbarItem` | 12 | 工具栏搜索 |
| `NSCollectionViewCompositionalLayout` + diffable data source | 10.15 | 图标视图 |
| `NSFilePromiseProvider` / `NSFilePromiseReceiver` | 10.12 | 拖到 Finder（下载） |
| `QLPreviewPanel` | 10.6 | 空格键 Quick Look |
| `NSProgress` 发布文件进度（`publish()`） | 10.9 | Finder 里显示下载进度 |
| `NSWindowRestoration` | 10.7 | 重启后恢复窗口和 tab |

## 窗口结构（模仿 Finder）

```
┌──────────────────────────────────────────────────────────────┐
│ ● ● ●  ‹ ›  SD Card ▸ Roms ▸ gba      [▦ ☰ ▥]  [⋯]  [⬇︎ 2]  🔍 │  ← 统一工具栏
├──────────────┬───────────────────────────────────────────────┤
│ 设备          │  Tab: SD Card │ Installed games │ +           │  ← 原生窗口 tab
│ ▾ Switch     │───────────────────────────────────────────────│
│   SD Card    │  名称                    大小      种类         │
│   Nand USER  │  📁 atmosphere            —        文件夹       │
│   Installed… │  📁 Roms                  —        文件夹       │
│   SD install │  📄 hbmenu.nro          1.7 MB     NRO         │
│   …          │                                               │
│ ▾ Pixel 9    │                                               │
│   内部存储     │                                               │
│ 收藏          │                                               │
│   Roms/gba   │───────────────────────────────────────────────│
│              │  SD Card ▸ Roms ▸ gba          (路径栏)        │
│              │  32 项，剩余 38.1 GB             (状态栏)        │
└──────────────┴───────────────────────────────────────────────┘
```

- **单窗口 + 原生 tab**：每个 tab 是一个独立的浏览位置，有自己的前进/后退历史。⌘T 新建 tab，⌘W 关闭，⌘⇧[ / ⌘⇧] 切换，tab 可以拖出去变成新窗口（系统行为，免费得到）。也允许多窗口，就像 Finder。
- **侧边栏（source list）**：
  - 「设备」分组：每台已连接的设备一个节点，**下面列出它的所有存储**（DBI 有 8 个：SD Card、Nand USER、Installed games、SD Card install……）。单击在当前 tab 打开，⌘单击或中键在新 tab 打开。
  - 设备节点上有弹出按钮（⏏，对应 `requestCloseSession`），右键菜单里有「在新 tab 中打开所有存储」。
  - ~~「收藏」分组~~：0.1.2 去掉（用户认为对这类工具没有意义；常用位置靠标签页和窗口恢复）。
  - 存储节点显示容量条或剩余空间（注意 DBI 的剩余空间是缓存值，见 CONTEXT.md）。
- **工具栏**：后退/前进、当前位置标题、视图切换（图标 / 列表 / 分栏）、操作菜单（⋯）、传输按钮（带进度徽标，点击弹出传输列表）、搜索框。工具栏可自定义（`allowsUserCustomization`）。
- **路径栏**（`NSPathControl`）：位于底部，可以点击跳转，也可以作为拖放目标。
- **状态栏**：显示项目数、选中项数和大小、剩余空间、连接状态（"读取中…"之类）。

## 视图

| 视图 | 组件 | v1 | 说明 |
|---|---|---|---|
| 列表 | `NSOutlineView`（可展开文件夹，像 Finder 列表视图） | ✅ 主视图 | 列：名称、大小、种类，可排序、可调宽度、可隐藏；DBI 没有日期，日期列在设备不支持时自动隐藏 |
| 图标 | `NSCollectionView` | ✅ | 图片/视频缩略图在后台低优先级生成 |
| 分栏 | 每栏一个 `NSTableView`，横向排开 | ✅ 0.1.2 | 选中文件夹展开下一栏，选中文件显示预览栏 |
| 画廊 | `QLPreviewView` + 缩略图条 | ✅ 0.1.2 | 预览要先把文件下载到本机缓存，64 MB 以上不自动下载 |

- 大目录要秒开：先显示骨架（handle 数量），再分批补全名称和大小，**优先补全可见行**（滚动时调整优先级）。
- 记住每个文件夹的视图模式和排序（按设备 + 路径）。

## 文件操作

| 操作 | 交互 | v1 | 备注 |
|---|---|---|---|
| 浏览 / 打开文件夹 | 双击、⌘↓、⌘↑ 返回上级 | ✅ | |
| **下载**（设备 → Mac） | 拖到 Finder/桌面；右键「下载到…」；在 Pier 里 ⌘C，到 Finder 里 ⌘V | ✅ | 拖拽用 `NSFilePromiseProvider`，松手后才在后台传输；Finder 中显示文件进度 |
| **上传**（Mac → 设备） | 从 Finder 拖进列表或文件夹；拖到侧边栏的存储或路径栏上；在 Finder 里 ⌘C，到 Pier 里 ⌘V；菜单「上传…」 | ✅ | 支持文件夹（递归创建）。>4 GB 文件走分段写（SendPartialObject）；设备不支持时给出明确提示 |
| 打开 / 预览 | 空格 Quick Look；双击用默认 app 打开 | ✅ | 先下载到缓存目录（只下载需要的部分），再交给 QL 或 NSWorkspace |
| 新建文件夹 | ⌘⇧N，创建后直接进入改名状态 | ✅ | |
| 改名 | 回车 / 点击名称，行内编辑 | ✅ | 按设备能力预检（如 DBI 不能改成非 ASCII 名字），不合法时在编辑框里直接提示 |
| 删除 | ⌘⌫，**必须确认**（设备上没有废纸篓） | ✅ | 文件夹删除时显示项目数；DBI 删除文件夹会递归删除 |
| 设备内移动 | 在窗口内拖拽 | ✅ | 移动后由 app 自己更新目录模型（DBI 缓存不会刷新）；不支持的情况下禁止拖放并说明原因 |
| 设备内复制 | — | ❌ | MTP 设备普遍不支持 CopyObject；以后可能用"下载再上传"实现 |
| 显示简介 | ⌘I 面板：路径、大小（64 位）、格式、存储 | ✅ | |
| 搜索 | 工具栏搜索：先过滤当前文件夹（即时），回车后在后台递归搜索整个存储 | ✅ | 递归搜索属于可取消的后台任务 |
| 跨设备拖拽 | 从设备 A 拖到设备 B | ⏳ | 经本机中转 |

所有操作都支持多选、撤销提示（至少对改名）、右键菜单、标准快捷键。下载冲突（同名）弹出 Finder 风格的"替换 / 保留两者 / 跳过"。

## 传输系统（后台）

- **传输队列**：工具栏按钮弹出 popover，列出每个任务的进度、速度和剩余时间，支持暂停、继续、取消和失败重试；也可以打开独立的传输窗口。
- **下载**：分块读取（GetPartialObject/64），**可断点续传**，写入临时文件，完成后原子移动到目标位置。
- **上传**：
  - 一般文件：单次 SendObject（ImageCaptureCore 一次调用就发完，**拿不到真实进度**，只能按实测速度估算进度条；上限约 4 GB）；
  - 支持 Android 编辑扩展的设备：用 SendPartialObject 分块上传，能拿到真实进度，也能取消；
  - 完成后回读 ObjectSize 校验（DBI 写失败时不报错）。
- 退出 app 或拔线时如果还有任务未完成，会提示用户；重新连接后可以继续未完成的下载。
- 启动传输时开启 `ProcessInfo.beginActivity`，防止系统休眠打断传输。

## 架构原则（支撑"前台流畅"）

- **每台设备一个 `actor DeviceSession`**：它独占这台设备的 PTP 指令通道，内部有**优先级调度**：
  - `interactive`（列目录、取当前可见项的信息、Quick Look）> `userInitiated`（用户刚发起的小文件传输）> `background`（大文件分块、缩略图、递归搜索）；
  - 大传输按块交错执行：每块之间检查有没有更高优先级的请求，有就让路。所以即使正在传 10 GB，打开文件夹也只需等当前这一块；
  - 块大小自适应：没有交互请求时用 16 MB（吞吐 38 MB/s），有交互时降到 2–4 MB（单块延迟约 100 ms）。
  - 单次 SendObject（最长可能几分钟）无法打断，所以优先用分段上传；用不了分段时，明确告诉用户传输期间浏览会变慢。
- **目录模型由 app 自己维护**：设备侧缓存靠不住（DBI 的移动、重复 handle、残缺名字等问题），所以本地模型是唯一可信来源，操作后乐观更新界面，失败时回滚并提示。
- **设备能力/怪癖档案（`DeviceQuirks`）**：根据 VendorExtension、厂商/型号/序列号、OperationsSupported 生成，比如"不能改成非 ASCII 名字""文件名按去掉非 ASCII 后判重""剩余空间不刷新""0 字节文件 SendObject 返回 0x2002"等。界面根据档案启用/禁用功能并提前给出提示。
- **主线程只碰界面**：`@MainActor` 视图控制器 + 后台 actor；数据通过 diffable 快照推给界面。
- **分层**：`PierKit`（PTP/MTP 编解码、DeviceSession、传输引擎，纯逻辑，可单测）+ `Pier`（AppKit 界面）。spike 里的 Reader/Writer、数据集解析和 `send()` 直接迁移进 PierKit。

## v1 不做

- 插入设备自动弹出窗口（v1.1：菜单栏常驻助手，类似 AFT Agent）
- Wi-Fi / ADB 连接、同步、备份
- 分栏视图、画廊视图
- App Sandbox / 上架 App Store（架构上保留可能性，v1 不追求）
- 设备内复制

## 已确认的决定（2026-10-03）

1. 最低系统版本：**macOS 13**。
2. 用户数据：偏好设置放 `UserDefaults`；收藏和断点续传状态放 `~/Library/Application Support/Pier/` 下的文件。
3. **支持 Finder 式的 ⌘C / ⌘V**：在 Pier 里 ⌘C 后到 Finder 里 ⌘V 就是下载（剪贴板用 file promise）；在 Finder 里 ⌘C 后到 Pier 里 ⌘V 就是上传（剪贴板里是文件 URL）。
   - 技术风险：Finder 粘贴时是否接受剪贴板里的 file promise 需要先做实验验证。如果不接受，备选方案是 ⌘C 时把文件先下载到缓存再放文件 URL（小文件），大文件则提示用拖放或「下载到…」。
