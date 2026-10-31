# Molly Lavalink v4 service

This directory contains Molly's own Lavalink v4 service and is included by
`../molly-container.yml`. The authenticated healthcheck gates Molly startup.
It uses host networking because DNS from the existing Tori Lavalink container
fails for its source APIs; the Molly node itself binds only to
`127.0.0.1:2333`. Tori's service and configuration remain unchanged.

- Runtime image: official `ghcr.io/lavalink-devs/lavalink:4.2.2`, pinned by
  manifest digest.
- Plugins: YouTube Source `1.18.2` and LavaSrc `4.8.3`, versions verified on
  the Pi's existing Lavalink v4.2.2 node.
- Ordinary text searches use YouTube. Explicit `spsearch:` searches and Spotify
  URLs resolve through LavaSrc with artist enrichment disabled; Spotify track
  metadata is mirrored to YouTube because Spotify is not itself an audio source.
- Credentials are supplied to this service only from
  `/etc/molly/lavalink.env`, separate from the Molly bot's environment.
- `restart: unless-stopped` keeps the service available across host and
  container restarts. Its authenticated `/version` healthcheck is bounded.
- No port is published to LAN or the public network.

Refresh the protected runtime file and deploy from the repository root:

```sh
python3 ops/configure_lavalink_env.py
docker compose -f ops/molly-container.yml config --quiet
docker compose -f ops/molly-container.yml up -d
```

The helper reads the running Tori Lavalink container but never prints its
password or Spotify credentials. It refuses to write if Molly's configured
Lavalink password does not match Tori's existing password. The output file is
installed atomically as `toriaa:toriaa` with mode `0600`.
