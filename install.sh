#!/bin/bash
# Hopper installer — one-liner bootstrap untuk Termux / RF
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Fluxyyy333/hopper_web/main/install.sh) <LICENSE>

set -e

LICENSE="$1"
SERVER_URL="http://203.194.114.193:3000"

echo ""
echo "==========================================="
echo "   Hopper Installer (RF / Termux)"
echo "==========================================="
echo ""

if [ -z "$LICENSE" ]; then
  echo "[x] Usage: bash install.sh <LICENSE>"
  echo "    License didapat dari dashboard saat register."
  exit 1
fi

if ! echo "$LICENSE" | grep -qE '^[A-F0-9]{32}$'; then
  echo "[x] License format invalid (harus 32-char hex uppercase)"
  exit 1
fi

# ============================================================
# Mirror fallback + retry helpers (adapted from wintercode installer)
# Handles flaky Termux mirrors: sync lag, NO_PUBKEY, size mismatch, etc.
# ============================================================
FALLBACK_MIRRORS=(
  "https://packages-cf.termux.dev/apt/termux-main"
  "https://packages.termux.dev/apt/termux-main"
  "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
  "https://mirrors.ustc.edu.cn/termux/termux-main"
  "https://grimler.se/termux/termux-main"
  "https://mirror.quantum5.ca/termux/termux-main"
)
APT_DIR="$PREFIX/etc/apt"
APT_LISTS="$PREFIX/var/lib/apt/lists"
_MIRROR_IDX=0

switch_mirror() {
  local mirror="${FALLBACK_MIRRORS[$_MIRROR_IDX]}"
  _MIRROR_IDX=$(( (_MIRROR_IDX + 1) % ${#FALLBACK_MIRRORS[@]} ))
  echo "    -> switch mirror: $mirror"
  rm -rf "$APT_LISTS"/* 2>/dev/null
  echo "deb $mirror stable main" > "$APT_DIR/sources.list"
  if [ -d "$APT_DIR/sources.list.d" ]; then
    for f in "$APT_DIR/sources.list.d"/*.list; do
      [ -f "$f" ] || continue
      sed -i "s|deb [^ ]*/termux-main|deb $mirror|" "$f" 2>/dev/null
    done
  fi
}

is_mirror_error() {
  echo "$1" | grep -qiE "unexpected size|Mirror sync in progress|Failed to fetch|Some index files failed|does not have a Release file|Redirection from https|is not signed|NO_PUBKEY"
}

pkg_update_retry() {
  local attempt=0 max=6 rc out
  while [ $attempt -lt $max ]; do
    rc=0
    out=$(pkg update -y 2>&1) || rc=$?
    echo "$out" | tail -3
    if [ $rc -eq 0 ]; then
      return 0
    fi
    if is_mirror_error "$out"; then
      attempt=$((attempt + 1))
      echo "    mirror error ($attempt/$max), switch mirror..."
      switch_mirror
      sleep 2
    else
      echo "[x] pkg update failed: non-mirror error"
      return 1
    fi
  done
  echo "[x] pkg update gagal setelah $max percobaan"
  return 1
}

pkg_install_retry() {
  local pkg="$1" attempt=0 max=4 rc out
  while [ $attempt -lt $max ]; do
    rc=0
    out=$(pkg install -y "$pkg" 2>&1) || rc=$?
    echo "$out" | tail -3
    if [ $rc -eq 0 ]; then
      return 0
    fi
    if is_mirror_error "$out"; then
      attempt=$((attempt + 1))
      echo "    $pkg mirror error ($attempt/$max), retry update..."
      pkg_update_retry || true
    else
      echo "[x] $pkg install failed: non-mirror error"
      return 1
    fi
  done
  echo "[x] $pkg gagal setelah $max percobaan"
  return 1
}

echo "[1/7] Install dependencies (lua, curl, sqlite)..."
# Sync package index + upgrade existing libs first — avoids ABI mismatch
# (e.g. libngtcp2_crypto_ossl.so vs stale openssl → curl segfault)
pkg_update_retry || { echo "[x] Tidak bisa update package index. Abort."; exit 1; }

echo "    pkg upgrade (sync libs)..."
DEBIAN_FRONTEND=noninteractive pkg upgrade -y -o Dpkg::Options::="--force-confnew" 2>&1 | tail -3 || true

pkg_install_retry lua54 || pkg_install_retry lua || { echo "[x] Gagal install lua"; exit 1; }
pkg_install_retry curl   || { echo "[x] Gagal install curl"; exit 1; }
pkg_install_retry sqlite || { echo "[x] Gagal install sqlite"; exit 1; }

if ! command -v lua >/dev/null 2>&1; then
  if command -v lua5.4 >/dev/null 2>&1; then
    ln -sf "$(command -v lua5.4)" "$PREFIX/bin/lua"
  fi
fi
echo "    lua    : $(command -v lua || echo MISSING)"
echo "    curl   : $(command -v curl || echo MISSING)"
echo "    sqlite3: $(command -v sqlite3 || echo MISSING)"

echo ""
echo "[2/7] Device config"
read -rp "    Device ID (unique, contoh '01'): " DEVICE_ID
DEVICE_ID="${DEVICE_ID:-01}"
read -rp "    Roblox package name [com.deltb]: " PKG
PKG="${PKG:-com.deltb}"
read -rp "    Hop interval (menit) [12]: " HOP
HOP="${HOP:-12}"

echo ""
echo "[3/7] Writing config to /sdcard..."
printf '%s' "$SERVER_URL" > /sdcard/.hopper_server
printf '%s' "$DEVICE_ID"  > /sdcard/.hopper_devid
printf '%s' "$LICENSE"    > /sdcard/.hopper_license
printf '%s' "$PKG"        > /sdcard/.hopper_pkg
printf '%s' "$HOP"        > /sdcard/.hopper_hop
printf 'regular'          > /sdcard/.hopper_mode

echo "[4/7] Downloading hopper.lua (rendered from backend)..."
curl -fsSL -H "X-License: $LICENSE" "$SERVER_URL/api/installer/hopper.lua" -o /sdcard/hopper.lua
echo "    $(wc -l < /sdcard/hopper.lua) lines"
if ! grep -q 'Daemon v2' /sdcard/hopper.lua; then
  echo "[x] Downloaded hopper.lua looks invalid. Periksa license."
  exit 1
fi

echo "[5/7] Registering device with backend..."
REGISTER_RESP=$(curl -fsS -X POST "$SERVER_URL/api/devices/register" \
  -H "Content-Type: application/json" \
  -H "X-License: $LICENSE" \
  -d "{\"id\":\"$DEVICE_ID\",\"name\":\"$DEVICE_ID\",\"pkg_name\":\"$PKG\"}")
echo "    Response: $REGISTER_RESP"

if echo "$REGISTER_RESP" | grep -q '"error"'; then
  echo "[x] Registration failed. Periksa license + device_id."
  exit 1
fi

echo "[6/7] Killing old hopper daemon..."
pgrep -x lua | xargs -r kill 2>/dev/null || true
sleep 1

echo "[7/7] Starting hopper daemon..."
setsid -f lua /sdcard/hopper.lua </dev/null >/sdcard/hopper_daemon.log 2>&1
sleep 2

PID=$(pgrep -x lua || true)
if [ -n "$PID" ]; then
  echo ""
  echo "==========================================="
  echo "   SUCCESS — daemon running (PID=$PID)"
  echo "==========================================="
  echo ""
  echo "   Tail log:  tail -f /sdcard/hopper_daemon.log"
  echo "   Dashboard: http://203.194.114.193:5173"
  echo ""
  echo "   Device-mu akan muncul di dashboard akun yang sesuai."
else
  echo "[x] Daemon failed to start. Cek /sdcard/hopper_daemon.log:"
  tail -n 20 /sdcard/hopper_daemon.log 2>/dev/null || true
  exit 1
fi
