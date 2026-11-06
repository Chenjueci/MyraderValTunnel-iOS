/*
 * TunPair.c — 见 TunPair.h 中的原理说明。
 * 仅使用 POSIX / Darwin 公开 API，可在 iOS NetworkExtension 进程内运行。
 */
#include "TunPair.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int
hev_tunnel_pair_open (int fds[2])
{
    int bufsz = 256 * 1024;
    int flags;

    if (socketpair (AF_UNIX, SOCK_DGRAM, 0, fds) < 0)
        return -1;

    /*
     * hev 以 tunnel.mtu 分配 pbuf，且 lwIP 可能一次写出接近 MTU 的包。
     * 放大 SO_SNDBUF/SO_RCVBUF，避免 AF_UNIX 数据报因默认缓冲过小而
     * EMSGSIZE / ENOBUFS 丢包。
     */
    (void) setsockopt (fds[0], SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof (bufsz));
    (void) setsockopt (fds[0], SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof (bufsz));
    (void) setsockopt (fds[1], SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof (bufsz));
    (void) setsockopt (fds[1], SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof (bufsz));

#ifdef SO_NOSIGPIPE
    /* 对端关闭后写 fds[1] 不触发 SIGPIPE（iOS/macOS 有效） */
    {
        int on = 1;
        (void) setsockopt (fds[1], SOL_SOCKET, SO_NOSIGPIPE,
                           (const void *) &on, sizeof (on));
    }
#endif

    /*
     * bridge 端非阻塞：DispatchSourceRead 的 handler 内可循环 read 直到
     * EAGAIN，既不阻塞 GCD 队列，也不会漏掉同一次可读事件里排队的多个包。
     */
    flags = fcntl (fds[1], F_GETFL, 0);
    if (flags >= 0)
        (void) fcntl (fds[1], F_SETFL, flags | O_NONBLOCK);

    return 0;
}
