# ColorDrop

**ColorDrop** 是一款使用 **100% 原生 Swift / SwiftUI** 编写的轻量化 macOS 局域网手机互联辅助工具，支持在同一 Wi-Fi 局域网下与支持跨屏互联协议的 Android 手机（如 ColorOS / OxygenOS / Realme UI 设备）进行快速设备连接、状态栏悬浮拖拽快传、按需目录浏览与双向文件传输、短信验证码自动复制及来电桌面通知。

## 核心特性

- **原生轻量架构**：摒弃体积庞大的 Electron / Chromium 渲染进程，采用 macOS 原生 SwiftUI 构建，常驻物理内存占用仅约 `30–40 MB`，平时静默驻留菜单栏，无感稳定。
- **同 Wi-Fi 自动发现与无感重连**：基于局域网 Bonjour 与跨屏互联发现机制自动识别设备真实型号（如 `OnePlus 15` / `OPPO Find X8`），记住上次配对连接的手机；手机离开网络后再次回到同一 Wi-Fi 时自动重连（手动点击断开除外）。
- **状态栏悬浮拖拽虚拟窗与双模式文件上传**：
  - **状态栏快捷快传（默认保存至 `Download/ColorDrop`）**：点击顶部菜单栏图标中的「发送文件」，或在 Mac 上拖动任意文件移向顶部状态栏时，ColorDrop 图标下方会自动弹出**悬浮拖拽小虚拟窗**，松手即可将文件直接发送至手机 `Download/ColorDrop` 文件夹，无需打开主窗口；
  - **主窗口目录直传（跟随当前浏览目录）**：在主界面「传输」页浏览任意手机文件夹时，直接将 Mac 文件拖入主窗口或点击「上传到当前目录」，文件将直接上传至当前停留的手机文件夹根目录下。
- **按需加载的手机文件管理器**：
  - 仅在打开目录时按需请求当前层级文件列表，准确解析并展示手机端文件与文件夹的**真实修改时间**；
  - 默认隐藏以 `.` 开头的系统及缓存目录，可在设置中一键开启「显示隐藏文件」；
  - 支持单选/多选批量下载、右键菜单删除文件/文件夹（带二次确认弹窗防误删）、实时同步本地已下载文件状态及自定义接收保存位置。
- **短信验证码自动复制与来电提醒**：
  - 实时同步手机短信与来电通知，严格过滤微信、QQ 等非短信社交应用通知干扰；
  - 收到验证码短信时自动提取 4–8 位验证码写入 Mac 剪贴板，支持点击在「大号验证码」与「完整短信正文」间切换，并在顶部菜单栏弹窗中随时查看复制；
  - 手机来电响铃时弹出精简通知横幅（`{号码或联系人}` / `来电 · {归属地}`），并支持在 Mac 端一键挂断。
- **真实设备信息面板**：实时展示手机电量与充电状态、局域网 ICMP 延迟、手机真实系统版本与硬件型号（如 `ColorOS 17 · PLK110` 及屏幕分辨率）以及手机端可传输共享文件统计。

## 目录结构

```text
OppoLiteConnect/
├── Package.swift
├── README.md
├── build_app.sh
└── Sources/
    └── OppoLiteConnect/
        ├── OppoLiteConnectApp.swift          # 应用入口、菜单栏常驻与自检逻辑
        ├── Models/
        │   └── OppoModels.swift              # 设备、远端文件（含修改时间解析）、传输任务与通知模型
        ├── Protocol/
        │   ├── DspIPCClient.swift            # 本地跨屏互联 IPC 通信与文件操作协议封装
        │   ├── LanSdpDiscovery.swift         # 局域网 Bonjour 自动发现与网络状态监听
        │   └── OShareEngine.swift            # 高速文件互传桥接与接收目录监听
        ├── Services/
        │   ├── ConnectCoordinator.swift      # 核心状态协调器（连接、双路径上传、目录浏览、通知）
        │   └── SMSNotificationService.swift  # 短信验证码提取、去重与来电通知服务
        └── Views/
            ├── MainConnectView.swift         # 主窗口视图（设备 / 传输 / 消息 / 设置）
            ├── MenuBarConnectView.swift      # 顶部菜单栏快捷弹窗视图
            └── StatusBarDropController.swift # 状态栏拖拽感应悬浮小虚拟窗控制器
```

## 本地编译与运行

### 环境要求

- macOS 13.0 (Ventura) 及以上（Apple Silicon `arm64`）
- Xcode Command Line Tools (`swiftc`)

### 构建应用包

```bash
chmod +x build_app.sh
./build_app.sh
```

构建完成后将生成 `ColorDrop.app`，双击即可运行；也可通过命令行运行内置自检：

```bash
./ColorDrop.app/Contents/MacOS/OppoLiteConnect --self-test
```

## 免责声明与非官方声明 (Legal Disclaimer & Non-Affiliation Notice)

1. **非官方独立项目**：本项目（**ColorDrop**）由个人开发者出于技术研究、学习交流与提升日常 macOS 桌面使用体验的目的独立开发，**与广东欧加控股有限公司（OPPO）、一加科技（OnePlus）、真我（Realme）及其任何关联公司不存在任何隶属、合作、赞助、授权、背书或官方关联**。
2. **商标权归属**：「OPPO」、「OnePlus（一加）」、「Realme（真我）」、「ColorOS」、「OxygenOS」、「Realme UI」、「跨屏互联」、「O+ 互联（O+ Connect）」及相关图形、标识均为其各自合法权利人的注册商标或商标。本仓库及文档中提及上述名称，仅作为兼容性与适用设备范围的客观说明（Nominative Fair Use），不代表任何官方身份。
3. **不包含受版权保护的第三方专有二进制文件**：本开源仓库仅提供 ColorDrop 原生 Swift 源代码与构建脚本，不分发任何第三方专有动态库、服务程序或数字证书。用户在本地构建或运行时如需调用相关底层协议组件，须自行确保已合法安装官方客户端并遵守其最终用户许可协议（EULA）。
4. **按「原样」提供与使用风险自担**：本软件按「原样（AS IS）」免费开源提供，不附带任何明示或暗示的担保（包括但不限于适销性、特定用途适用性及不侵权担保）。在任何情况下，作者或贡献者均不对因使用或无法使用本软件而产生的任何直接、间接、偶然或数据丢失损失承担责任。
5. **严禁商业用途与侵权告知**：本项目严禁用于任何商业售卖、捆绑分发或违法违规用途。若相关权利人认为本仓库中的任何内容侵犯了您的合法权益，请通过 GitHub Issue 联系作者，我们将在收到通知后第一时间予以配合、修改或移除。

## 开源许可

本项目源代码采用 [MIT License](https://opensource.org/licenses/MIT) 开源许可协议，仅供个人技术学习与研究使用。
