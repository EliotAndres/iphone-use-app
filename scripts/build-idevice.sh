#!/bin/bash
# Builds libidevice_ffi.a (+ idevice.h) from upstream idevice plus our patch
# (idevice-patch/: CoreDevice screenshot/touch/keys for the agent) and copies
# them into StikDebug/idevice/. Needs rustup with the aarch64-apple-ios target.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${IDEVICE_SRC:-$ROOT/.build/idevice}
COMMIT=3854a5d  # jkcoxson/idevice, "fix(ffi): preserve usbmuxd connection ownership (#138)"

if [ ! -d "$SRC" ]; then
  git clone https://github.com/jkcoxson/idevice.git "$SRC"
  git -C "$SRC" checkout -q $COMMIT
  git -C "$SRC" apply "$ROOT/idevice-patch/idevice.patch"
  cp "$ROOT/idevice-patch/probe.rs" "$SRC/ffi/src/core_device/probe.rs"
fi

cd "$SRC"
export PATH="$(dirname "$(rustup which cargo)"):$PATH"
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --release -p idevice-ffi --target aarch64-apple-ios --features obfuscate
cp target/aarch64-apple-ios/release/libidevice_ffi.a ffi/idevice.h "$ROOT/StikDebug/idevice/"
