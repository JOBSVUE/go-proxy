# ===== Build Stage =====
FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY go.mod ./

RUN go mod download
COPY . .

# build the binary as "go-proxy" (matches README: ./go-proxy)
RUN CGO_ENABLED=0 GOOS=linux go build -buildvcs=false -o /out/go-proxy main.go

# ===== Runtime Stage =====
FROM alpine:latest

# Install required packages for tunnel and networking
RUN apk --no-cache add iproute2 curl bash

WORKDIR /app

COPY --from=builder /app/go-proxy .

COPY config.example.yaml /app/config.yaml


# ===== HE Tunnel Configuration =====
# Tunnel interface name
ENV TUN_IF=${TUN_IF}
# HE Server IPv4 (do not change unless HE updates it)
ENV HE_SERVER_V4=${HE_SERVER_V4}
# Your client IPv4 (replace with your actual IPv4)
ENV MY_V4=${MY_V4}
# Tunnel IPv6 addresses (do not change unless HE updates them)
ENV HE_TUN_CLIENT6=${HE_TUN_CLIENT6}
ENV HE_TUN_SERVER6=${HE_TUN_SERVER6}
# Tunnel MTU (recommended by HE)
ENV HE_TUN_MTU=${HE_TUN_MTU}
# Routed subnet (replace with your actual routed /64 or /48)
ENV ROUTED_SUBNET=${ROUTED_SUBNET}

# ===== Proxy Configuration =====
ENV BIND=${BIND}
ENV WORKERS=${WORKERS}


ENV LISTEN_ADDRESS=${LISTEN_ADDRESS:-"::"}
ENV LISTEN_PORT=${LISTEN_PORT:-"8778"}
ENV DEBUG_MODE=${DEBUG_MODE:-"false"}
ENV TEST_PORT=${TEST_PORT:-"0"}
ENV NETWORK_TYPE=${NETWORK_TYPE:-"tcp6"}
ENV MAX_TIMEOUT=${MAX_TIMEOUT:-"30"}

ENV AUTH_TYPE=${AUTH_TYPE:-"credentials"}
ENV AUTH_USERNAME=${AUTH_USERNAME:-"username"}
ENV AUTH_PASSWORD=${AUTH_PASSWORD:-"password"}
ENV AUTH_REDIS_DSN=${AUTH_REDIS_DSN:-"redis://localhost:6379"}

ENV BIND_PREFIX_1=${BIND_PREFIX_1:-"2a14:dead:beef::1/48"}
ENV BIND_PREFIX_2=${BIND_PREFIX_2:-"2a14:dead:feed::1/48"}

ENV ENABLE_FALLBACK=${ENABLE_FALLBACK:-"true"}
ENV FALLBACK_PREFIX_1=${FALLBACK_PREFIX_1:-"1.2.3.4/32"}

ENV LOCATED_US_1=${LOCATED_US_1:-"2a14:dead:beef::/48"}
ENV LOCATED_UK_1=${LOCATED_UK_1:-"2a14:dead:feed::/48"}

ENV REPLACE_KEY=${REPLACE_KEY:-"1.2.3.0/24"}
ENV REPLACE_VALUE=${REPLACE_VALUE:-"2a14:dead:beef::"}

ENV DEL_HDR_1=${DEL_HDR_1:-"Proxy-Authorization"}
ENV DEL_HDR_2=${DEL_HDR_2:-"Proxy-Connection"}






# Copy the startup script with detailed debug prints and IPv6 isolation
COPY <<'EOF' /app/start.sh
#!/bin/bash
set -e

debug_print() {
    echo "[DEBUG] $1"
}

error_print() {
    echo "[ERROR] $1" >&2
}

success_print() {
    echo "[SUCCESS] $1"
}

debug_print "Starting HE IPv6 tunnel setup..."

# Step 1: Disable IPv6 on eth0 to prevent host IPv6 leakage
debug_print "Disabling IPv6 on eth0..."
if ip -6 addr flush dev eth0 2>/dev/null; then
    success_print "IPv6 disabled on eth0."
else
    error_print "Failed to disable IPv6 on eth0."
    #exit 1
fi

# Step 2: Create the tunnel
debug_print "Creating HE IPv6 tunnel interface '$TUN_IF'..."
if ip tunnel add "$TUN_IF" mode sit remote "$HE_SERVER_V4" local "$MY_V4" ttl 255; then
    success_print "Tunnel interface '$TUN_IF' created successfully."
else
    error_print "Failed to create tunnel interface '$TUN_IF'."
    exit 1
fi

# Step 3: Set MTU and bring the interface up
debug_print "Setting MTU to '$HE_TUN_MTU' and bringing '$TUN_IF' up..."
if ip link set "$TUN_IF" mtu "$HE_TUN_MTU" up; then
    success_print "MTU set and interface '$TUN_IF' is up."
else
    error_print "Failed to set MTU or bring '$TUN_IF' up."
    exit 1
fi

# Step 4: Assign IPv6 address to the tunnel
debug_print "Assigning IPv6 address '$HE_TUN_CLIENT6' to '$TUN_IF'..."
if ip -6 addr add "$HE_TUN_CLIENT6" dev "$TUN_IF"; then
    success_print "IPv6 address '$HE_TUN_CLIENT6' assigned to '$TUN_IF'."
else
    error_print "Failed to assign IPv6 address '$HE_TUN_CLIENT6' to '$TUN_IF'."
    exit 1
fi

# Step 5: Remove any existing IPv6 default routes that might use the host's IPv6
debug_print "Removing any existing IPv6 default routes..."
ip -6 route del default 2>/dev/null || true

# Step 6: Set default IPv6 route via HE
debug_print "Setting default IPv6 route via '$HE_TUN_SERVER6'..."
if ip -6 route replace default via "$HE_TUN_SERVER6" dev "$TUN_IF"; then
    success_print "Default IPv6 route set via '$HE_TUN_SERVER6'."
else
    error_print "Failed to set default IPv6 route via '$HE_TUN_SERVER6'."
    exit 1
fi

# Step 7: Route the routed subnet via the tunnel
debug_print "Routing '$ROUTED_SUBNET' via '$TUN_IF'..."
if ip -6 route add "$ROUTED_SUBNET" dev "$TUN_IF"; then
    success_print "Subnet '$ROUTED_SUBNET' routed via '$TUN_IF'."
else
    error_print "Failed to route '$ROUTED_SUBNET' via '$TUN_IF'."
    exit 1
fi

# Step 8: Enable non-local IPv6 binding
debug_print "Enabling non-local IPv6 binding..."
if sysctl -w net.ipv6.ip_nonlocal_bind=1; then
    success_print "Non-local IPv6 binding enabled."
else
    error_print "Failed to enable non-local IPv6 binding."
    exit 1
fi

# Step 9: Print IPv6 routing state
debug_print "IPv6 routing state:"
ip -6 addr show dev "$TUN_IF"
ip -6 route show




# --- WRITE /app/config.yaml at runtime (env overrides optional) ---
cat > /app/config.yaml <<EOF2
listen_address: "${LISTEN_ADDRESS:-::}"
listen_port: ${LISTEN_PORT:-8778}
debug_mode: ${DEBUG_MODE:-false}
test_port: ${TEST_PORT:-0}
network_type: "${NETWORK_TYPE:-tcp6}"
max_timeout: ${MAX_TIMEOUT:-30}
auth:
  type: "${AUTH_TYPE:-credentials}"
  credentials:
    username: "${AUTH_USERNAME:-username}"
    password: "${AUTH_PASSWORD:-password}"
  redis:
    dsn: "${AUTH_REDIS_DSN:-redis://localhost:6379}"
bind_prefixes:
  - "${BIND_PREFIX_1:-2a14:dead:beef::1/48}"
  - "${BIND_PREFIX_2:-2a14:dead:feed::1/48}"
enable_fallback: ${ENABLE_FALLBACK:-true}
fallback_prefixes:
  - "${FALLBACK_PREFIX_1:-1.2.3.4/32}"
located_prefixes:
  us:
    - ${LOCATED_US_1:-2a14:dead:beef::/48}
  uk:
    - ${LOCATED_UK_1:-2a14:dead:feed::/48}
replace_ips:
  "${REPLACE_KEY:-1.2.3.0/24}": "${REPLACE_VALUE:-2a14:dead:beef::}"
deleted_headers:
  - "${DEL_HDR_1:-Proxy-Authorization}"
  - "${DEL_HDR_2:-Proxy-Connection}"
EOF2



# Step 10: Start the proxy BINARY (no flags; reads /app/config.yaml)
debug_print "Starting go-proxy using /app/config.yaml ..."
exec /app/go-proxy
EOF

# Make the startup script executable
RUN chmod +x /app/start.sh /app/go-proxy

# Your service hint (host networking ignores this but harmless)
EXPOSE 8778


HEALTHCHECK --interval=35s --timeout=7s --start-period=25s --retries=4 \
  CMD exit 0

  
CMD ["/app/start.sh"]
