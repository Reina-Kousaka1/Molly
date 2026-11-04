FROM debian:bookworm-slim

ENV HOME=/nonexistent \
    MOLLY_SEAWORLD_SOCKET=/run/seaworld-molly/seaworld.sock

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Keep the container identity aligned with the existing Pi service account so
# Molly can access its owner-only SeaWorld Unix socket when it is bind-mounted.
RUN groupadd --system --gid 983 molly \
    && useradd --system --uid 999 --gid 983 --no-create-home \
       --home-dir /nonexistent --shell /usr/sbin/nologin molly

COPY --chown=999:983 runtime/ ./runtime/
COPY --chown=999:983 deps/ ./deps/
COPY --chown=999:983 src/ ./src/
COPY --chown=999:983 tools/ ./tools/
COPY --chown=999:983 molly.lua ./molly.lua

USER 999:983

ENTRYPOINT ["/app/runtime/luvit", "/app/molly.lua"]
