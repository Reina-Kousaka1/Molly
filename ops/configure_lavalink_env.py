#!/usr/bin/env python3
"""Copy Molly's required Lavalink credentials into a separate protected env file.

The source is the already-running Tori Lavalink container. This script only
reads its environment and never prints any credential values.
"""

import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


MOLLY_ENV = Path("/etc/molly/molly.env")
TARGET = Path("/etc/molly/lavalink.env")
SOURCE_CONTAINER = "tori-main-lavalink-1"
REQUIRED_SOURCE_KEYS = (
    "LAVALINK_SERVER_PASSWORD",
    "SPOTIFY_CLIENT_ID",
    "SPOTIFY_CLIENT_SECRET",
)


def parse_env_text(content):
    values = {}
    for line in content.splitlines():
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not match:
            continue
        key, value = match.groups()
        if key in values:
            raise ValueError("duplicate_environment_key")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def extract_container_env(inspected):
    if not isinstance(inspected, list) or len(inspected) != 1:
        raise ValueError("source_container_unavailable")
    entries = inspected[0].get("Config", {}).get("Env", [])
    values = {}
    for entry in entries:
        key, separator, value = entry.partition("=")
        if key in REQUIRED_SOURCE_KEYS and separator:
            if key in values:
                raise ValueError("duplicate_source_setting")
            values[key] = value
    for key in REQUIRED_SOURCE_KEYS:
        value = values.get(key, "")
        if not value or "\n" in value or "\r" in value:
            raise ValueError("source_credential_unavailable")
    return values


def render_env(values):
    lines = []
    for key in REQUIRED_SOURCE_KEYS:
        value = values.get(key)
        if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
            raise ValueError("credential_invalid")
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def verify_molly_password(molly_values, source_values):
    if molly_values.get("MOLLY_LAVALINK_PASSWORD") != source_values.get("LAVALINK_SERVER_PASSWORD"):
        raise ValueError("molly_lavalink_auth_mismatch")


def _read_source():
    result = subprocess.run(
        ["docker", "inspect", SOURCE_CONTAINER],
        check=True,
        capture_output=True,
        text=True,
    )
    return extract_container_env(json.loads(result.stdout))


def _install_atomically(content):
    writer = (
        "set -eu; umask 077; "
        "temporary=$(mktemp /target/.lavalink.env.XXXXXX); "
        "trap 'rm -f \"$temporary\"' EXIT; "
        "cat > \"$temporary\"; "
        "chown 1000:1000 \"$temporary\"; chmod 600 \"$temporary\"; "
        "mv -f \"$temporary\" /target/lavalink.env"
    )
    result = subprocess.run(
        [
            "docker", "run", "--rm", "--interactive", "--user", "0:0",
            "--network", "none", "--entrypoint", "/bin/sh",
            "--mount", f"type=bind,source={TARGET.parent},target=/target",
            "molly:local", "-c", writer,
        ],
        input=content,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError("protected_file_write_failed")


def main():
    try:
        parent = TARGET.parent.stat()
        parent_mode = stat.S_IMODE(parent.st_mode)
        if parent.st_uid != 0 or parent_mode & 0o022:
            raise ValueError("secret_directory_permissions_invalid")

        molly_metadata = MOLLY_ENV.stat()
        if (
            not stat.S_ISREG(molly_metadata.st_mode)
            or molly_metadata.st_uid != os.getuid()
            or stat.S_IMODE(molly_metadata.st_mode) != 0o600
        ):
            raise ValueError("molly_environment_permissions_invalid")
        molly_values = parse_env_text(MOLLY_ENV.read_text(encoding="utf-8"))

        source_values = _read_source()
        verify_molly_password(molly_values, source_values)

        _install_atomically(render_env(source_values))
    except subprocess.CalledProcessError:
        print("Lavalink source credentials could not be read; Molly configuration was not changed.", file=sys.stderr)
        return 1
    except (OSError, ValueError, json.JSONDecodeError):
        print("Lavalink credentials could not be safely prepared; Molly configuration was not changed.", file=sys.stderr)
        return 1

    print("Molly Lavalink runtime environment configured; credentials were not displayed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
