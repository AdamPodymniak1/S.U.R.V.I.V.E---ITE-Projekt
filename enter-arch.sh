#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export HOST_UID=${HOST_UID:-$(id -u)}
export HOST_GID=${HOST_GID:-$(id -g)}

if command -v docker-compose &> /dev/null; then
  docker-compose run --rm dev "$@"
elif docker compose version &> /dev/null; then
  docker compose run --rm dev "$@"
else
  echo "Neither 'docker-compose' nor 'docker compose' found."
  echo "Install docker-compose: sudo pacman -S docker-compose"
  exit 1
fi