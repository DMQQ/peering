#ifndef PEERING_QUIC_H
#define PEERING_QUIC_H

#include <stddef.h>
#include <stdint.h>
#include "quiche.h"

/// A configuration whose TLS identity is the keychain's DER certificate and X9.63 P-256 key. Null when either cannot be read. Freed with quiche_config_free.
quiche_config *peering_quic_config_new(const uint8_t *certificate, size_t certificate_len,
                                       const uint8_t *private_key, size_t private_key_len);

#endif
