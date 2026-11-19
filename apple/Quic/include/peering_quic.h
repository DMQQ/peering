#ifndef PEERING_QUIC_H
#define PEERING_QUIC_H

#include <stddef.h>
#include <stdint.h>
#include "quiche.h"

/// A configuration whose TLS identity is the keychain's DER certificate and X9.63 P-256 key. Null when either cannot be read. Freed with quiche_config_free.
quiche_config *peering_quic_config_new(const uint8_t *certificate, size_t certificate_len,
                                       const uint8_t *private_key, size_t private_key_len);

/// quiche_conn_send that also reports how long to hold the packet (pacing). quiche's own send time is always zero on Apple platforms.
ssize_t peering_quic_conn_send(quiche_conn *conn, uint8_t *out, size_t out_len,
                               struct sockaddr_storage *to, socklen_t *to_len, uint64_t *delay_nanos);

#endif
