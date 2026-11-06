import Foundation
import NetworkExtension
import Darwin
import HevSocks5Tunnel

/*
 * iOS Packet Tunnel Provider —— 基于 MIT 开源 hev-socks5-tunnel 的系统级 SOCKS5 VPN。
 *
 * 架构（依据上游 hev 源码，见 README「为什么这样桥接」）：
 *
 *   NEPacketTunnelFlow (纯 IP 包)
 *        |  readPackets / writePackets
 *        v
 *   [Swift 桥接层]  加 4 字节协议族头 / 剥 4 字节协议族头
 *        |
 *        v
 *   AF_UNIX SOCK_DGRAM socketpair  fds[1] <---> fds[0]
 *                                              |
 *                                              v  tun_fd
 *                                  hev_socks5_tunnel_main_from_str()
 *
 * 三条不可违反的事实（均已核对上游源码）：
 *  1. tunnel_init(extern_tun_fd)：传入 >= 0 的 fd 时 hev 直接采用它作为 tun_fd，
 *     不会再自己打开设备、设置地址或 MTU（hev-socks5-tunnel.c:504-527）。
 *  2. hev-tunnel-macos.h 定义 HEV_TUNNEL_GENERIC_HEAD：hev 在 tun_fd 上用
 *     readv/writev 读写「4 字节协议族头(网络字节序) + IP 报文」；而
 *     NEPacketTunnelFlow 收发的是纯 IP 报文 —— 必须做加/剥头转换。
 *  3. iOS NetworkExtension 沙盒不允许自行创建 utun；上游 hev_tunnel_open()
 *     在 iOS 上直接 return 0，明确要求外部提供 fd。故这里用 socketpair，
 *     SOCK_DGRAM 保证一次 writev 对应一个完整 IP 包、不会粘包。
 */
final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// 交给 hev 的 tun_fd（socketpair 的一端）
    private var hevFd: Int32 = -1
    /// Swift 侧桥接端（socketpair 的另一端）
    private var bridgeFd: Int32 = -1

    private var readSource: DispatchSourceRead?
    private let bridgeQueue = DispatchQueue(label: "com.myraderval.tunnel.bridge",
                                            qos: .userInitiated)
    private var hevThread: Thread?
    private let hevDone = DispatchSemaphore(value: 0)
    private let stopLock = NSLock()
    private var stopped = false

    /// 网络字节序的 4 字节协议族头：AF_INET = 2，AF_INET6 = 30（Darwin）
    private static let afInetHeader: [UInt8]  = [0x00, 0x00, 0x00, 0x02]
    private static let afInet6Header: [UInt8] = [0x00, 0x00, 0x00, 0x1E]

    // MARK: - 启动

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let serverAddress = proto.serverAddress else {
            completionHandler(Self.makeError(1001, "缺少隧道配置（serverAddress）"))
            return
        }

        let cfg = proto.providerConfiguration ?? [:]
        let host = (cfg["host"] as? String) ?? serverAddress
        let port = (cfg["port"] as? NSNumber)?.intValue ?? 1080
        let user = cfg["username"] as? String
        let pass = cfg["password"] as? String
        let tunnelIPv4 = (cfg["tunnelIPv4"] as? String) ?? "198.18.0.1"
        // 必须与 NEPacketTunnelNetworkSettings.mtu 一致：hev 用它分配 pbuf
        let mtu = (cfg["mtu"] as? NSNumber)?.intValue ?? 1500

        // 1) 告诉 iOS 把流量路由进本隧道
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)
        let ipv4 = NEIPv4Settings(addresses: [tunnelIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: mtu)
        // 注：DNS 走 UDP/53，需要 SOCKS5 服务端支持 UDP ASSOCIATE
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }

            // 2) 创建 tun fd 对（iOS 上不打开真实 utun，见文件头说明）
            var fds: [Int32] = [-1, -1]
            guard hev_tunnel_pair_open(&fds) == 0, fds[0] >= 0, fds[1] >= 0 else {
                completionHandler(Self.makeError(1002,
                    "创建 tun fd 对失败（socketpair errno=\(errno)）"))
                return
            }
            self.hevFd = fds[0]
            self.bridgeFd = fds[1]
            NSLog("[MyraderValTunnel] tun fd 就绪 hev=%d bridge=%d",
                  self.hevFd, self.bridgeFd)

            // 3) 构造 hev 配置并在独立线程启动（该调用会阻塞直到 quit）
            let config = HevTunnelConfig(socks5Host: host, socks5Port: port,
                                         username: user, password: pass,
                                         tunnelIPv4: tunnelIPv4, mtu: mtu)
            let yamlBytes = Array(config.yaml().utf8)
            let tunFd = self.hevFd

            self.startBridge()
            self.hevThread = Thread { [weak self] in
                // withUnsafeBufferPointer 的指针在整个阻塞调用期间有效，
                // hev 会在入口处（hev_config_init_from_str）完成配置解析。
                let rc = yamlBytes.withUnsafeBufferPointer { buf -> Int32 in
                    guard let base = buf.baseAddress else { return -1 }
                    return hev_socks5_tunnel_main_from_str(base, UInt32(buf.count), tunFd)
                }
                NSLog("[MyraderValTunnel] hev 已退出 rc=%d", rc)
                self?.hevDone.signal()
            }
            self.hevThread?.stackSize = 1 << 20
            self.hevThread?.name = "hev-socks5-tunnel"
            self.hevThread?.start()

            completionHandler(nil)
        }
    }

    // MARK: - 停止

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        stopLock.lock()
        if stopped {
            stopLock.unlock()
            completionHandler()
            return
        }
        stopped = true
        stopLock.unlock()

        NSLog("[MyraderValTunnel] stopTunnel reason=%d", reason.rawValue)

        // 先让 hev 自行退出，再关闭 fd（否则正在 readv/writev 的 fd 被 close）
        hev_socks5_tunnel_quit()
        if hevDone.wait(timeout: .now() + .seconds(5)) == .timedOut {
            NSLog("[MyraderValTunnel] hev 未在 5s 内退出，继续清理")
        }

        readSource?.cancel()
        readSource = nil
        if bridgeFd >= 0 { close(bridgeFd); bridgeFd = -1 }
        if hevFd >= 0 { close(hevFd); hevFd = -1 }
        hevThread = nil

        completionHandler()
    }

    // MARK: - 桥接：hev 侧 <-> NEPacketTunnelFlow 侧

    private func startBridge() {
        // hev -> packetFlow：读到带 4 字节头的 datagram，剥头后交给 NE
        let source = DispatchSource.makeReadSource(fileDescriptor: bridgeFd,
                                                   queue: bridgeQueue)
        source.setEventHandler { [weak self] in
            self?.drainBridgeFd()
        }
        source.resume()
        readSource = source

        // packetFlow -> hev：纯 IP 包加 4 字节头写入 bridgeFd
        readFromPacketFlow()
    }

    /// 循环读取直到 EAGAIN，避免同一次可读事件里排队的多个报文被漏掉
    private func drainBridgeFd() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while bridgeFd >= 0 {
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                read(bridgeFd, ptr.baseAddress, ptr.count)
            }
            if n > 4 {
                // 前 4 字节是 hev 写入的协议族头，直接丢弃
                let version = buf[4] >> 4
                let proto = NSNumber(value: version == 6 ? AF_INET6 : AF_INET)
                let packet = Data(buf[4..<n])
                packetFlow.writePackets([packet], withProtocols: [proto])
            } else if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                NSLog("[MyraderValTunnel] bridge read errno=%d", errno)
                break
            } else {
                // n == 0（对端关闭）或 n <= 4（畸形帧），丢弃并结束本轮
                break
            }
        }
    }

    private func readFromPacketFlow() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self, self.bridgeFd >= 0 else { return }
            for packet in packets {
                let bytes = [UInt8](packet)
                guard let first = bytes.first else { continue }
                var frame = (first >> 4) == 6
                    ? Self.afInet6Header : Self.afInetHeader
                frame.append(contentsOf: bytes)

                let written = frame.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return write(self.bridgeFd, base, ptr.count)
                }
                if written < 0 {
                    // 缓冲已满等极端情况；TunPair.c 已放大 SO_SNDBUF，正常不触发
                    NSLog("[MyraderValTunnel] bridge write errno=%d", errno)
                }
            }
            if self.bridgeFd >= 0 {
                self.readFromPacketFlow()
            }
        }
    }

    private static func makeError(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "MyraderValTunnel", code: code,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
