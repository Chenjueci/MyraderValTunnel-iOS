# MyraderValTunnel-iOS

基于 **hev-socks5-tunnel（MIT 开源）** 的 iOS **Packet Tunnel（系统级 VPN）** 源码工程。
容器 App（SwiftUI）负责配置 SOCKS5 出口与开关 VPN；NetworkExtension 扩展把
iOS 的 `NEPacketTunnelFlow` 接入 hev 的 lwIP 协议栈，实现全局 SOCKS5 隧道。

> ⚠️ **这是源码工程，不是现成 IPA。** iOS 应用必须在 **macOS + Xcode** 上编译、签名、
> 归档。本仓库预置了 GitHub Actions，在**云端 macOS Runner** 上自动出 IPA，
> 所以你**不需要拥有 Mac**。但请注意：仓库是在 Linux 环境编写与静态校验的，
> **所有 iOS 运行时行为尚未在真机验证**（见文末「验证清单」）。

---

## 目录结构

```
MyraderValTunnel-iOS/
├── README.md                       # 本文件
├── SIGNING.md                      # 签名版 CI 的 Secrets 配置与排错
├── project.yml                     # xcodegen 工程描述（App + Extension 两个 target）
├── scripts/
│   └── fetch-build-xcframework.sh  # 拉取上游并构建 HevSocks5Tunnel.xcframework
├── App/MyraderValTunnel/
│   ├── MyraderValTunnelApp.swift
│   ├── ContentView.swift           # 配置 SOCKS5 + NEVPNManager 开关
│   ├── Info.plist
│   └── MyraderValTunnel.entitlements
├── Extension/MyraderValTunnelExtension/
│   ├── PacketTunnelProvider.swift  # 核心：fd 对 ↔ packetFlow 桥接 + 调用 hev
│   ├── TunnelConfig.swift          # 运行时生成 hev YAML（含 iOS 低内存优化）
│   ├── TunPair.h / TunPair.c       # 创建 AF_UNIX/SOCK_DGRAM socket 对作为 tun_fd
│   ├── MyraderValTunnelExtension-Bridging-Header.h
│   ├── Info.plist
│   └── MyraderValTunnelExtension.entitlements
├── conf/hev-tunnel-example.yml     # hev 配置格式参考
└── .github/workflows/
    ├── build-ipa.yml               # 免签名 IPA（配合侧载工具重签）
    └── build-ipa-signed.yml        # 已签名 IPA（带 packet-tunnel 授权）
```

---

## 为什么这样桥接（关键，均已核对上游源码）

```
NEPacketTunnelFlow  ← 纯 IP 报文
        ↕  readPackets / writePackets
[PacketTunnelProvider]  加/剥 4 字节协议族头
        ↕
AF_UNIX / SOCK_DGRAM socketpair   fds[1] ←→ fds[0] (tun_fd)
                                              ↕
                     hev_socks5_tunnel_main_from_str(config, len, tun_fd)
```

三条不可违反的事实，来自 [heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)：

1. **外部 fd 会被直接采用**：`hev_socks5_tunnel_main_from_str()` → `tunnel_init(extern_tun_fd)`，
   当 `extern_tun_fd >= 0` 时 hev 只做 `ioctl(FIONBIO)` 就把它设为 `tun_fd`，
   **不会再自己打开设备、设置地址或 MTU**（`src/hev-socks5-tunnel.c`）。
2. **Apple 平台报文带 4 字节头**：`src/hev-tunnel-macos.h` 定义了
   `HEV_TUNNEL_GENERIC_HEAD`，于是 `hev_tunnel_read/write` 在 `tun_fd` 上用
   `readv/writev` 读写「**4 字节协议族头（网络字节序，AF_INET=2 / AF_INET6=30）+ IP 报文**」；
   而 `NEPacketTunnelFlow` 收发的是**纯 IP 报文**。两者格式不同，桥接层必须做转换，
   否则报文首字节被当作头丢掉，隧道必然不通。
3. **iOS 上不能自己开 utun**：上游 `hev_tunnel_open()` 在 `TARGET_OS_OSX` 才创建
   utun，在 iOS 直接 `return 0`；且 NetworkExtension 由系统管理 utun，
   App Extension 沙盒不允许自行 `socket(PF_SYSTEM, ..., SYSPROTO_CONTROL)`。
   因此这里用 **socketpair** 提供 fd，`SOCK_DGRAM` 保证一次 `writev` 对应
   一个完整 IP 包、不会粘包。

配套细节：
- `TunPair.c` 放大 `SO_SNDBUF/SO_RCVBUF` 到 256 KB，避免数据报超限丢包；
  `fds[1]` 设为非阻塞，桥接读循环到 `EAGAIN` 为止，不阻塞 GCD 队列。
- `tunnel.mtu` 必须与 `NEPacketTunnelNetworkSettings.mtu` 一致（默认 1500）：
  hev 用 `hev_config_get_tunnel_mtu()` 分配读包 pbuf，lwIP 也据此决定输出包大小。
- `misc.*` 是 iOS 低内存优化（上游 README「Low memory usage」及
  `hev-socks5-tunnel.c` 中「iOS NE jetsam」注释）：NE 进程内存上限极小，
  必须收紧 task 栈、TCP 缓冲与最大会话数。

### 相对初版已修正的问题

| 问题 | 后果 | 修正 |
| --- | --- | --- |
| 未处理 4 字节协议族头 | 报文被破坏，隧道永不连通 | 桥接层显式加/剥头 |
| 在 NE 沙盒内打开真实 utun | iOS 上几乎必然失败 | 改为 socketpair 提供 tun_fd |
| `OBJ_C_BRIDGING_HEADER` 拼写错误 | C 接口在 Swift 中找不到，编译失败 | 改为 `SWIFT_OBJC_BRIDGING_HEADER` |
| Extension `Info.plist` 缺 `NSExtensionPrincipalClass` | 系统找不到主类，扩展启动失败 | 补 `$(PRODUCT_MODULE_NAME).PacketTunnelProvider` |
| App `UIBackgroundModes = network`（非法值） | 审核/安装异常 | 移除 |
| Xcode 15+ 自动生成 Info.plist 冲突 | `Multiple commands produce Info.plist` | 设 `GENERATE_INFOPLIST_FILE=NO` |
| 静态库 XCFramework 被 embed | 构建报错 | `embed: false`，仅链接 |
| escaping 闭包里漏 `self.` | Swift 编译错误 | 用 `[weak self]` + 方法调用 |
| 免签名 IPA 未校验 `.appex` | 装上了却没扩展 | CI 增加嵌入校验 |
| 免签名 CI 构建 9 个平台切片 | 慢且易超时 | `IOS_ONLY=1` 只编译 iphoneos/arm64 |

---

## 快速开始：没有 Mac 也能拿到 IPA

### 路线 A：免签名 IPA（最简单）

1. 把本仓库推到 GitHub。
2. **Actions → Build iOS IPA (unsigned) → Run workflow**（或 push 到 main/master）。
3. 下载 Artifact `MyraderValTunnel-unsigned.ipa`。
4. 用 TrollStore / Sideloadly / AltStore 侧载安装。

> 免签名 IPA 的可运行性取决于侧载工具能否保留 `packet-tunnel` entitlement。
> 若装上后点「连接」VPN 不建立，走路线 B。

### 路线 B：已签名 IPA（推荐，扩展才会真正激活）

按 **[SIGNING.md](SIGNING.md)** 配置 6 个 Secrets（证书 p12 + 两份带
Network Extensions 能力的 provisioning profile + Team ID），然后：

1. **Actions → Build iOS IPA (signed) → Run workflow**，选 `development` 或 `ad-hoc`。
2. 下载 Artifact `MyraderValTunnel-signed.ipa`。
3. 用 Apple Configurator / Xcode Devices / Sideloadly 安装到已注册设备，
   并在 `设置 → 通用 → VPN 与设备管理` 信任开发者证书。

### 两条 CI 都会自动完成

`检出 → 装 xcodegen → 构建 HevSocks5Tunnel.xcframework → xcodegen generate
→ xcodebuild → 打包/导出 IPA → 上传 Artifact`。

---

## 本地有 Mac 时的开发流程

```bash
# 1) 构建 XCFramework（全平台，含模拟器，便于本地调试）
bash scripts/fetch-build-xcframework.sh

# 2) 生成 Xcode 工程
brew install xcodegen && xcodegen generate

# 3) 打开工程，选 Team 自动签名，真机运行
open MyraderValTunnel.xcodeproj
```

若手动在 Xcode 里新建工程（不用 xcodegen），要点：
- 建 iOS **App** + **Network Extension / Packet Tunnel Provider** 两个 target；
- 用本仓库对应目录的源文件替换模板；
- 把 `HevSocks5Tunnel.xcframework` 拖入并加入**两个** target 的
  *Link Binary With Libraries*（静态库**不要** embed）；
- Extension target 的 *Objective-C Bridging Header* 指向
  `.../MyraderValTunnelExtension-Bridging-Header.h`；
- 两个 target 分别设置各自的 `.entitlements`；
- `ContentView.swift` 的 `extensionBundleId` 与 Extension 的 Bundle ID 一致；
- **Packet Tunnel 在模拟器上功能受限，请用真机验证。**

归档出 IPA：`Product → Archive → Distribute App`。

---

## 配置说明

App 里填写 SOCKS5 出口（地址 / 端口 / 可选账号密码），写入
`NETunnelProviderProtocol.providerConfiguration`：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `host` | 表单输入 | SOCKS5 服务器 |
| `port` | `1080` | SOCKS5 端口 |
| `username` / `password` | 空 | 可选认证 |
| `tunnelIPv4` | `198.18.0.1` | 隧道本端地址（App 与 Extension 一致） |
| `mtu` | `1500` | 必须与 hev `tunnel.mtu` 一致 |

运行时由 `TunnelConfig.yaml()` 生成 hev 配置（格式见
`conf/hev-tunnel-example.yml`）。DNS 固定 `8.8.8.8 / 1.1.1.1`，走 UDP/53，
**需要 SOCKS5 服务端支持 UDP ASSOCIATE**（`udp: 'udp'`）。当前仅启用 IPv4 路由。

---

## 验证清单（⚠️ 尚未在真机执行）

仓库在 Linux 环境编写，只做了 YAML / plist / C 语法等**静态校验**，
以下必须在 macOS + 真机上确认：

- [ ] `xcodegen generate` 生成的工程能 `xcodebuild build` 通过；
- [ ] `HevSocks5Tunnel.xcframework` 的 module map 能被 Swift `import HevSocks5Tunnel`；
- [ ] App 内 `PlugIns/*.appex` 确实嵌入且带 `packet-tunnel` entitlement；
- [ ] `setTunnelNetworkSettings` 成功后 `socketpair` 创建成功、hev 线程正常启动；
- [ ] 桥接：状态栏出现 VPN 图标，`packetFlow` 与 hev 之间双向报文无丢包/乱序；
- [ ] `tunnel.mtu = 1500` 与 NE settings 一致；大数据包不触发 `EMSGSIZE`；
- [ ] SOCKS5 出口可达且支持 UDP；浏览器 / Speedtest 验证流量确实经代理；
- [ ] 断开时 `hev_socks5_tunnel_quit()` 后线程在 5s 内退出，fd 正常释放；
- [ ] 长时间运行不触发 iOS NE jetsam（必要时下调 `max-session-count`）。

---

## 限制与风险

| 限制 | 说明 |
| --- | --- |
| 本环境无法产出 IPA | 构建 iOS 应用物理上需要 macOS / Xcode / iOS SDK / 签名材料；仓库只提供云端一键出包的配置 |
| Packet Tunnel 是受限授权 | 免签名 / TrollStore 能装 App，但扩展常需带能力的 profile 背书才会激活（见 SIGNING.md） |
| 无源码无法复刻原 App | 最初的 `base.zip` 是 Android APK（`classes.dex` + ELF `.so`），DEX/ELF 在 iOS 不运行，本工程是**重新实现**的通用 SOCKS5 隧道，不含任何游戏相关逻辑 |
| 需要 SOCKS5 服务端 | 工程只是客户端；出口需自备并支持 UDP |
| 分发范围 | 个人账号只能装到注册设备；上架 App Store 需申请 Network Extensions 授权 |

---

## 许可证

- **hev-socks5-tunnel** 及其依赖（lwip / libyaml / hev-task-system）为 **MIT License**，
  见上游仓库 `LICENSE`。本工程仅做集成封装，遵循同等开源条款。
- 本工程不包含任何游戏破解/解密/外挂逻辑，仅提供通用的 SOCKS5 Packet Tunnel 能力。
