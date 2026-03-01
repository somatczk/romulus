FROM willfarrell/autoheal:1.2.0

# Patch entrypoint for plain-HTTP TCP socket-proxy support:
#   1. Remove file-existence check on DOCKER_SOCK (fails for tcp:// URLs)
#   2. Use http:// instead of https:// for TCP endpoints (socket-proxy has no TLS)
#   3. Clear TLS cert flags (not needed for plain HTTP)
RUN sed -i 's/&& \[ -e "$DOCKER_SOCK" \]//' /docker-entrypoint && \
    sed -i 's|tcp://#https://|tcp://#http://|' /docker-entrypoint && \
    sed -i 's|CA="--cacert.*"|CA=""|' /docker-entrypoint && \
    sed -i 's|CLIENT_KEY="--key.*"|CLIENT_KEY=""|' /docker-entrypoint && \
    sed -i 's|CLIENT_CERT="--cert.*"|CLIENT_CERT=""|' /docker-entrypoint
