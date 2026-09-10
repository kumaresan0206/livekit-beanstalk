# Stage 1: LiveKit Official Binary (Pinned Version for Reproducible Deployment)
FROM livekit/livekit-server:v1.8.3 AS livekit-source

# Stage 2: Minimal Runtime with AWS CLI & Utilities
FROM alpine:3.19

# Install required utilities for Secrets Manager integration and networking
RUN apk add --no-cache \
    ca-certificates \
    aws-cli \
    curl \
    jq \
    bash

# Copy LiveKit Server binary from official pinned image
COPY --from=livekit-source /livekit-server /livekit-server

# Copy configuration and entrypoint
COPY livekit.yaml /etc/livekit.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Document exposed ports (Signaling: 7880, ICE TCP: 7881, Media UDP: 50000-60000)
EXPOSE 7880/tcp
EXPOSE 7881/tcp
EXPOSE 50000-60000/udp

HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:7880/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
