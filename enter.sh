#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export HOST_UID=${HOST_UID:-$(id -u)}
export HOST_GID=${HOST_GID:-$(id -g)}

docker compose run --rm dev "$@"