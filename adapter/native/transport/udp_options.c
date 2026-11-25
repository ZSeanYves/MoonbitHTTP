#ifdef _WIN32
#include <winsock2.h>
#include <mswsock.h>
#include <moonbit.h>

/* On a shared UDP socket, an ICMP reply to an earlier send has no source
 * address available to recvfrom. It cannot be attributed to the next peer. */
MOONBIT_FFI_EXPORT int32_t moon_http_udp_suppress_port_unreachable(void *fd) {
  BOOL report = FALSE;
  DWORD returned = 0;
  if (WSAIoctl((SOCKET)fd, SIO_UDP_CONNRESET, &report, sizeof(report), NULL,
               0, &returned, NULL, NULL) == SOCKET_ERROR) {
    return WSAGetLastError();
  }
  return 0;
}
#else
#include <moonbit.h>
MOONBIT_FFI_EXPORT int32_t moon_http_udp_suppress_port_unreachable(int fd) {
  (void)fd;
  return 0;
}
#endif
