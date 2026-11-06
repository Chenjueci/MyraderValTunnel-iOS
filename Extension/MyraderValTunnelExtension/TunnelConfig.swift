import Foundation

/*
 * 生成 hev-socks5-tunnel 的 YAML 配置字符串（传给
 * hev_socks5_tunnel_main_from_str）。
 *
 * 依据上游源码的几点说明：
 *  - tun_fd 由 Extension 通过 socketpair 提供，因此 tunnel.* 里的
 *    name / ipv4 / ipv6 仅作标识，不会作用于设备：上游 tunnel_init()
 *    在 extern_tun_fd >= 0 时直接返回，不设地址、不设 MTU、不设状态。
 *  - tunnel.mtu 必须与 NEPacketTunnelNetworkSettings.mtu 保持一致：
 *    hev 用 hev_config_get_tunnel_mtu() 分配读包 pbuf，lwIP 也据此
 *    决定输出包大小（hev-socks5-tunnel.c:425、hev-tunnel.h:53）。
 *  - Apple 平台 hev 在 tun_fd 上收发「4 字节协议族头 + IP 包」，
 *    由 PacketTunnelProvider 在桥接层加/剥，配置本身无需感知。
 *  - misc.* 是 iOS 低内存优化：NetworkExtension 进程内存上限极小，
 *    上游 README「Low memory usage」及 hev-socks5-tunnel.c 中
 *    「iOS NE jetsam」注释都要求收紧 task 栈、TCP 缓冲与最大会话数。
 */
struct HevTunnelConfig {
    let socks5Host: String
    let socks5Port: Int
    let username: String?
    let password: String?
    let tunnelIPv4: String
    let mtu: Int

    func yaml() -> String {
        var s = ""
        s += "tunnel:\n"
        s += "  name: tun0\n"
        s += "  mtu: \(mtu)\n"
        s += "  ipv4: \(tunnelIPv4)\n"
        s += "  ipv6: 'fc00::1'\n"
        s += "  icmp: 'off'\n"
        s += "socks5:\n"
        s += "  port: \(socks5Port)\n"
        s += "  address: '\(escape(socks5Host))'\n"
        s += "  udp: 'udp'\n"
        if let u = username, !u.isEmpty {
            s += "  username: '\(escape(u))'\n"
        }
        if let p = password, !p.isEmpty {
            s += "  password: '\(escape(p))'\n"
        }
        s += "misc:\n"
        s += "  task-stack-size: 24576\n"   // 20480 + tcp-buffer-size
        s += "  tcp-buffer-size: 4096\n"
        s += "  max-session-count: 120\n"   // NE jetsam，可按设备内存上调
        s += "  log-level: 'warn'\n"
        return s
    }

    /// YAML 单引号字符串转义：内部单引号写成两个
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
