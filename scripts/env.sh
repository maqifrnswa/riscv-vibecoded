#!/usr/bin/env bash
#
# env.sh - Set up the OSS CAD Suite (+ optional RISC-V toolchain) environment
#          for the up5k-rv project.
#
# Safe to `source` from any Makefile, script, or interactive shell regardless
# of the current working directory. Idempotent: sourcing more than once is a
# no-op (guarded by $UP5K_RV_ENV_DONE).
#
# Usage:
#   source "$(repo_root)/scripts/env.sh"
#   # or, from within the repo:
#   source scripts/env.sh
#
# This script only sets environment variables (PATH, etc.). It never installs
# anything and never touches /etc/sandbox-persistent.sh. If the OSS CAD Suite
# is not installed, it prints a clear error pointing at the installer.
#
# The toolchains live in /home/agent/up5k-tools (OUTSIDE the repo), not under
# tools/. This is deliberate: the repo lives on a Windows-backed mount
# (/c/Users/...) that cannot create symlinks, which the OSS CAD Suite and the
# xPack toolchain require (libvvp.so, plugin .so, python3 links). /home/agent
# is native Linux and symlink-capable, so that's where the installs go.

# Resolve the repository root relative to this script's location (handles
# being sourced from any cwd, and works whether invoked via symlink or not).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Guard against double-sourcing. If already set up, return immediately.
if [ -n "${UP5K_RV_ENV_DONE:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# Tools are installed outside the repo under /home/agent/up5k-tools (the repo's
# Windows mount cannot create the symlinks the toolchains require). Override the
# location with the UP5K_TOOLS_ROOT environment variable if a different install
# path is in use.
TOOLS_ROOT="${UP5K_TOOLS_ROOT:-/home/agent/up5k-tools}"

OSS_CAD_DIR="$TOOLS_ROOT/oss-cad-suite"
OSS_CAD_ENV="$OSS_CAD_DIR/environment"

if [ -f "$OSS_CAD_ENV" ]; then
  # shellcheck disable=SC1091
  source "$OSS_CAD_ENV"
else
  echo "ERROR: OSS CAD Suite not found at $OSS_CAD_ENV" >&2
  echo "       Run the provisioning installer to install the toolchain first." >&2
  echo "       (See the repo's provisioning lane / docs for how to install.)" >&2
  return 1 2>/dev/null || exit 1
fi

# The RISC-V toolchain installs under ${TOOLS_ROOT}/riscv-toolchain/
# <release>/bin (e.g. xpack-riscv-none-elf-gcc-15.2.0-1/bin). Add it to PATH if
# present; tolerate its absence.
RV_TOOLCHAIN_ROOT="$TOOLS_ROOT/riscv-toolchain"
RV_TOOLCHAIN_BIN="$(ls -d "$RV_TOOLCHAIN_ROOT"/*/bin 2>/dev/null | head -n1)"
if [ -z "$RV_TOOLCHAIN_BIN" ] && [ -d "$RV_TOOLCHAIN_ROOT/bin" ]; then
  RV_TOOLCHAIN_BIN="$RV_TOOLCHAIN_ROOT/bin"
fi
if [ -n "$RV_TOOLCHAIN_BIN" ]; then
  export PATH="$RV_TOOLCHAIN_BIN:$PATH"
fi

# Mark as sourced so re-sourcing is a no-op.
export UP5K_RV_ENV_DONE=1
