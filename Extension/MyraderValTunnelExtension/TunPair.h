/*
 ============================================================================
 TunPair.h — 为 hev-socks5-tunnel 提供 tun_fd（iOS NetworkExtension）
 ============================================================================
 为什么不是打开真实 utun：
   * iOS 的 NetworkExtension 由系统管理 utun，App Extension 沙盒不允许自行
     socket(AF_SYSTEM, ..., SYSPROTO_CONTROL) 创建 utun 设备；
   * 上游 hev-tunnel-macos.c 中 hev_tunnel_open() 在非 TARGET_OS_OSX
     （即 iOS）直接 return 0，明确表示设备必须由外部提供；
   * 上游 tunnel_init(extern_tun_fd) 在 fd >= 0 时直接使用该 fd，不再
     打开设备 / 设置地址 / 设置 MTU。

 因此这里创建一对 AF_UNIX/SOCK_DGRAM socket：
   fds[0] -> 交给 hev 作为 tun_fd（hev 端读写格式见下）
   fds[1] -> 由 PacketTunnelProvider.swift 桥接到 NEPacketTunnelFlow

 报文格式（关键）：
   上游 hev-tunnel-macos.h 定义 HEV_TUNNEL_GENERIC_HEAD，故 hev 在 tun_fd 上
   读/写的是「4 字节协议族头(网络字节序, AF_INET=2 / AF_INET6=30) + IP 报文」；
   而 NEPacketTunnelFlow 收发的是纯 IP 报文。加/剥这 4 字节头在 Swift 桥接层完成。
   SOCK_DGRAM 保留消息边界，保证一次 writev/readv 对应一个完整 IP 包。
 ============================================================================
 */
#ifndef HEV_TUN_PAIR_H
#define HEV_TUN_PAIR_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 创建 socket 对并调大收发缓冲、把 fds[1] 设为非阻塞。
 * fds[0] 由上游 tunnel_init() 自行 ioctl(FIONBIO) 设为非阻塞，此处不重复设置。
 * 返回 0 成功，-1 失败（errno 由 socketpair 设置）。
 */
int hev_tunnel_pair_open(int fds[2]);

#ifdef __cplusplus
}
#endif

#endif /* HEV_TUN_PAIR_H */
