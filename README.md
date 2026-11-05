<div align="center">

# 🎨 ColorDrop

**使用 100% 原生 Swift / SwiftUI 编写的轻量化 macOS 局域网手机互联辅助工具**

[![Version](https://img.shields.io/badge/Version-v1.1.2-0A84FF?style=flat-square)](#)
[![Platform](https://img.shields.io/badge/Platform-macOS-4A90E2?style=flat-square)](#)
[![Swift](https://img.shields.io/badge/Built%20with-Swift%20%2F%20SwiftUI-F05138?style=flat-square&logo=swift)](#)
[![License](https://img.shields.io/badge/License-MIT-2ECC71?style=flat-square)](#)

支持在同一 Wi-Fi 局域网下，与支持跨屏互联协议的 Android 手机（如 ColorOS / OxygenOS / Realme UI 设备）进行快速设备连接、**手机屏幕镜像与 Mac 键鼠反控**、状态栏悬浮拖拽快传、按需目录浏览与双向文件传输、跨设备双向剪切板同步、短信验证码自动复制及原生系统通知栏来电挂断。

</div>

> **官方客户端引导**：本项目为个人出于技术学习与轻量化体验研究编写的第三方非官方开源客户端，仅对部分高频基础互联功能进行 macOS 原生界面探索。**如需获得最完整、最稳定的跨屏互联功能体验（如应用接力、随身工作台、多应用分身投屏等）及官方售后支持，请前往 OPPO 官方网站下载安装正版客户端：[https://connect.oppo.com/#/](https://connect.oppo.com/#/)**

## ✨ 核心特性

- **🧩 原生轻量架构**
  - 摒弃体积庞大的 Electron / Chromium 渲染进程，采用 macOS 原生 SwiftUI 构建，常驻物理内存占用仅约 `30–40 MB`，平时静默驻留菜单栏，无感稳定。

- **📡 同 Wi-Fi 自动发现与无感重连**
  - 基于局域网 Bonjour 与跨屏互联发现机制自动识别设备真实型号（如 `OnePlus 15` / `OPPO Find X8`），记住上次配对连接的手机；
  - 手机离开网络后再次回到同一 Wi-Fi 时自动重连（手动点击断开除外）。

- **📱 手机屏幕镜像与 Mac 键鼠操控**
  - 已连接设备卡片右侧（及顶部菜单栏快捷面板）内置 **「手机镜像」** 按钮，也支持从手机端跨屏互联直接发起投屏；
  - 支持在 Mac 桌面上实时显示手机屏幕，并直接使用 **Mac 鼠标/触控板点击滑动、键盘输入及快捷键（`Cmd+B` 返回、`Cmd+H` 主页、`Cmd+T` 多任务）** 操控手机。

- **📤 状态栏悬浮拖拽虚拟窗与双模式文件上传**
  - **状态栏快捷快传（默认保存至 `Download/ColorDrop`）**：点击顶部菜单栏图标中的「发送文件」，或在 Mac 上拖动任意文件移向顶部状态栏时，ColorDrop 图标下方会自动弹出**悬浮拖拽小虚拟窗**，松手即可将文件直接发送至手机 `Download/ColorDrop` 文件夹，无需打开主窗口；
  - **主窗口目录直传（跟随当前浏览目录）**：在主界面「传输」页浏览任意手机文件夹时，直接将 Mac 文件拖入主窗口或点击「上传到当前目录」，文件将直接上传至当前停留的手机文件夹根目录下。

- **📂 按需加载的手机文件管理器**
  - 仅在打开目录时按需请求当前层级文件列表，准确解析并展示手机端文件与文件夹的**真实修改时间**；
  - 默认隐藏以 `.` 开头的系统及缓存目录，可在设置中一键开启「显示隐藏文件」；
  - 支持单选/多选批量下载、右键菜单删除文件/文件夹（带二次确认弹窗防误删）、实时同步本地已下载文件状态及自定义接收保存位置（默认保存在 `~/Downloads/ColorDrop`）。

- **📋 跨设备双向剪切板同步（「剪切板」页）**
  - 支持 Mac 与手机之间双向实时复制粘贴，在任一设备复制文字后自动同步至另一端；
  - 左侧「剪切板」页面集中展示历史复制记录（标注来源设备与时间），支持单条一键复制（带「已复制 ✓」状态反馈）、单条独立删除以及带二次确认弹窗的一键清空。

- **🔔 macOS 原生通知栏来电提醒与一键挂断**
  - 手机来电响铃时，直接调用 **macOS 原生系统通知横幅（`UNUserNotificationCenter`）** 弹出提醒，通知栏、主界面顶部横幅及菜单栏弹窗均支持一键点击 **「挂断」**。

- **🔑 短信验证码自动复制与通知过滤（「消息」页）**
  - 实时同步手机短信与来电通知，严格过滤微信、QQ 等非短信社交应用通知干扰；
  - 收到验证码短信时自动提取 4–8 位验证码写入 Mac 剪贴板，支持点击在「大号验证码」与「完整短信正文」间切换，消息列表提供二次确认清空保护。

- **📊 真实设备信息面板**
  - 实时展示手机电量与充电状态、局域网 ICMP 延迟、手机真实系统版本与硬件型号（如 `ColorOS 17 · PLK110` 及屏幕分辨率）以及手机端可传输共享文件统计。

## 🖥️ 系统支持与安装

可在项目的 [**Releases**](../../releases) 页面直接下载最新打包版本：

| 平台 | 架构要求 | 安装包格式 | 内置组件说明 |
| :--- | :--- | :--- | :--- |
| **macOS** | Apple Silicon `arm64` (macOS 13.0+) | `ColorDrop-v*-macOS-arm64.dmg` | 已内置跨屏互联基础通信服务、互传动态库与手机镜像运行组件，拖拽至 `Applications` 即可运行 |

> **macOS 首次打开提示**：若系统提示「已损坏」或「无法验证开发者」，由于开源构建未绑定付费 Apple Developer ID 公证证书，macOS Gatekeeper 默认会拦截从浏览器下载的应用。请在终端执行以下命令清除隔离属性后正常打开：
> ```bash
> sudo xattr -rd com.apple.quarantine /Applications/ColorDrop.app
> ```

## 🚀 安装与使用

1. **下载安装镜像**
   - 前往 [Releases](../../releases) 页面下载最新版本的 `ColorDrop-v*-macOS-arm64.dmg` 安装镜像（如需官方完整功能，请前往 [OPPO 跨屏互联官网](https://connect.oppo.com/#/) 下载官方客户端）。
2. **安装应用**
   - 双击打开 DMG 镜像，将 **ColorDrop.app** 拖入右侧的 **Applications（应用程序）** 文件夹。
3. **首次运行权限与手机端设置**
   - 首次启动弹出「“ColorDrop”想要查找并连接到本地网络上的设备」与系统通知权限请求时，请点击 **「允许」**；
   - 确保手机与 Mac 连接在**同一 Wi-Fi 局域网**下，手机端在「设置 → 连接与共享 → 跨屏互联」中开启开关，或直接使用跨屏互联扫码连接。
4. **运行内置自检**
   - 如需在终端运行内置自检（安装在「应用程序」目录时）：
     ```bash
     /Applications/ColorDrop.app/Contents/MacOS/OppoLiteConnect --self-test
     ```

## 🛠️ 开发者本地构建

### 环境要求

- macOS 13.0 (Ventura) 及以上（Apple Silicon `arm64`）
- Xcode Command Line Tools (`swiftc`)

### 常用命令

```bash
# 1. 进入克隆后的仓库根目录
cd ColorDrop

# 2. 赋予构建脚本执行权限
chmod +x build_app.sh

# 3. 构建应用包（自动解压 Vendor 运行组件并生成 ./dist/ColorDrop.app）
./build_app.sh

# 4. 可选：同时打包 DMG 安装镜像
./build_app.sh --dmg

# 5. 运行内置自检
./dist/ColorDrop.app/Contents/MacOS/OppoLiteConnect --self-test
```

构建脚本会自动解压 `Vendor/runtime.tar.xz` 与 `Vendor/mirror.tar.xz` 内置运行组件并生成完整应用包（如需同时打包 DMG 可执行 `./build_app.sh --dmg`）。

## 📂 项目目录结构

```text
ColorDrop/
├── Package.swift
├── README.md
├── build_app.sh
├── Vendor/
│   ├── iconbase_192.png                      # 应用图标素材
│   ├── runtime.tar.xz                        # 跨端互联基础通信与传输动态库压缩包
│   └── mirror.tar.xz                         # 手机屏幕镜像运行组件压缩包
└── Sources/
    └── OppoLiteConnect/
        ├── OppoLiteConnectApp.swift          # 应用入口、菜单栏常驻、Dock 唤醒与自检逻辑
        ├── Models/
        │   └── OppoModels.swift              # 设备、远端文件、剪切板历史、传输任务与通知模型
        ├── Protocol/
        │   ├── DspIPCClient.swift            # 本地跨屏互联 IPC、跨端剪切板与来电挂断协议封装
        │   ├── LanSdpDiscovery.swift         # 局域网 Bonjour 自动发现与网络状态监听
        │   └── OShareEngine.swift            # 高速文件互传桥接与接收目录监听
        ├── Services/
        │   ├── ConnectCoordinator.swift      # 核心状态协调器（连接、镜像、传输、剪切板与消息）
        │   ├── ScreenMirrorService.swift     # 手机屏幕镜像与 Mac 键鼠反控服务
        │   └── SMSNotificationService.swift  # 短信验证码提取与 macOS 原生通知栏来电挂断服务
        └── Views/
            ├── MainConnectView.swift         # 主窗口视图（设备 / 传输 / 剪切板 / 消息 / 设置）
            ├── MenuBarConnectView.swift      # 顶部菜单栏快捷弹窗视图
            └── StatusBarDropController.swift # 状态栏拖拽感应悬浮小虚拟窗控制器
```

## ⚖️ 免责声明与非官方声明

1. **非官方独立项目与官方客户端引导**：本项目（**ColorDrop**）由个人开发者出于技术研究、学习交流与提升日常 macOS 桌面使用体验的目的独立编写，**与广东欧加控股有限公司（OPPO）、一加科技（OnePlus）、真我（Realme）及其任何关联公司不存在任何隶属、合作、赞助、授权、背书或官方关联**。如果您需要最完整、最稳定的跨端协同体验及官方技术支持，请直接前往 OPPO 官方网站下载安装官方正版软件：**[https://connect.oppo.com/#/](https://connect.oppo.com/#/)**。
2. **商标权与底层组件著作权归属**：「OPPO」、「OnePlus（一加）」、「Realme（真我）」、「ColorOS」、「OxygenOS」、「Realme UI」、「跨屏互联」、「O+ 互联」及相关图形、标识均为其各自合法权利人的注册商标或商标；本项目为实现与手机端系统协议的互操作兼容性所调用的底层通信服务、传输库及投屏组件（如 `O+Connect Service`、`libOshareLib.dylib`、`手机投屏.app` 及 `Odmf.framework`），其著作权与一切知识产权均归属于原权利人（OPPO 及其关联公司）所有。本仓库提及上述名称仅用于兼容性说明，不代表任何官方身份。
3. **互操作性研究声明**：本项目中的 Swift / SwiftUI 界面与桥接代码仅用于局域网设备互联与跨端协作的互操作性（Interoperability）技术研究，必须配合用户本人合法持有的受支持手机设备方可使用，不包含任何绕过账号付费鉴权、破解硬件限制或窃取用户隐私数据的行为。
4. **按「原样」提供与使用风险自担**：本软件按「原样」免费开源提供，不附带任何明示或暗示的担保（包括但不限于适销性、特定用途适用性及不侵权担保）。在任何情况下，作者或贡献者均不对因使用或无法使用本软件而产生的任何直接、间接、偶然或数据丢失损失承担责任。
5. **严禁商业用途与权利人移除机制（DMCA / Takedown）**：本项目完全免费开源，**严禁任何人将其用于商业售卖、收费代装、捆绑分发或任何商业盈利行为**。我们高度尊重原权利人的知识产权，若 OPPO 或相关权利人认为本仓库中的任何二进制组件、代码或表述存在不妥或侵犯了您的合法权益，请随时通过 GitHub Issue 或邮件联系作者，作者将在收到通知后**立即无条件配合修改、移除相关二进制文件或下架整个仓库**。

## 📄 开源许可

本项目中由作者独立编写的 Swift / SwiftUI 源代码采用 [MIT License](https://opensource.org/licenses/MIT) 开源许可协议，仅供个人技术学习与研究使用；项目所引用或调用的第三方/官方底层二进制组件，其知识产权归原权利人所有，不在 MIT 许可授权范围内。
