#!/usr/bin/env bash
# Prepares a rented Linux GPU box (Ubuntu 22.04 or 24.04, root, NVIDIA GPU) for the three.js studio renders.
# Runs ON THE BOX, started by run-remote.sh after the code has been uploaded to $WORK (a mirror of the Mac's home folder).
#   bash setup.sh           everything (fresh box: about 4-8 minutes, mostly apt + the Chrome download)
#   bash setup.sh --image   only what does not depend on the host: apt packages, fonts, Node (used by the Dockerfile)
#   bash setup.sh --boot    only what depends on the host: NVIDIA graphics libraries, npm install, Chrome wrapper, GPU check
# Idempotent: running it twice is fine. Writes /opt/xr/env and /opt/xr/chrome-gpu.sh.
set -euo pipefail
MODE="${1:---full}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/work}"
NODE_VERSION="${NODE_VERSION:-22.12.0}"   # the Mac runs v22.12.0 (checked 11 Nov 2026); same version here
log() { printf '\n== %s\n' "$*"; }

# Ubuntu 24.04 renamed several libraries (t64); take whichever name exists.
pick() { for p in "$@"; do if apt-cache show "$p" >/dev/null 2>&1; then echo "$p"; return 0; fi; done; echo "$1"; }

image_part() {
  log "apt packages (Chrome runtime, Vulkan loader, fonts)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl xz-utils rsync tmux procps python3 python3-venv \
    vulkan-tools libvulkan1 libegl1 libgles2 libgl1 libglvnd0 \
    libnss3 "$(pick libatk1.0-0t64 libatk1.0-0)" "$(pick libatk-bridge2.0-0t64 libatk-bridge2.0-0)" "$(pick libcups2t64 libcups2)" \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
    "$(pick libasound2t64 libasound2)" libxshmfence1 libx11-xcb1 libdbus-1-3 libexpat1 "$(pick libglib2.0-0t64 libglib2.0-0)" \
    fonts-dejavu-core fonts-liberation fonts-urw-base35 fontconfig
  # Fonts: the studios load Anton, Rajdhani, Archivo, IBM Plex Mono from Google Fonts (same files on both machines).
  # Canvas text that names fonts the page does not load falls back to system fonts: on the Mac Menlo / Helvetica Neue / Arial,
  # here DejaVu Sans Mono (Menlo is derived from it) / Nimbus Sans (URW) / Liberation Sans. Deliberately NOT installed:
  # "JetBrains Mono" and "Inter" - the Mac does not have those families either, installing them would make this box differ more.
  fc-cache -f >/dev/null

  # ffmpeg of the same generation as the Mac (9.0.1 on 11 Nov 2026). Ubuntu 22.04's ffmpeg 4.4 turns the full-range JPEG frames
  # into limited range (yuv420p tv) where the Mac keeps full range (yuvj420p pc): same picture in a player, different bytes,
  # +11.7 luma levels in a raw comparison (test 11 Nov 2026). Static build, GPL, from the FFmpeg-Builds project.
  log "ffmpeg 9.0 (static)"
  if ! ffmpeg -version 2>/dev/null | head -1 | grep -q "version n9\.0"; then
    local ft; ft="$(mktemp -d)"
    curl -fsSL -o "$ft/ff.tar.xz" "https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-linux64-gpl-9.0.tar.xz"
    rm -rf /opt/ffmpeg && mkdir -p /opt/ffmpeg && tar -xJf "$ft/ff.tar.xz" -C /opt/ffmpeg --strip-components=1
    ln -sf /opt/ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg; ln -sf /opt/ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
    rm -rf "$ft"
  fi
  ffmpeg -version | head -1

  log "Node $NODE_VERSION"
  if ! command -v node >/dev/null || [ "$(node -v)" != "v$NODE_VERSION" ]; then
    local tmp; tmp="$(mktemp -d)"
    local tar="node-v$NODE_VERSION-linux-x64.tar.xz"
    curl -fsSL -o "$tmp/$tar" "https://nodejs.org/dist/v$NODE_VERSION/$tar"
    curl -fsSL -o "$tmp/SHASUMS256.txt" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"
    (cd "$tmp" && grep " $tar\$" SHASUMS256.txt | sha256sum -c -)
    rm -rf /opt/node && mkdir -p /opt/node && tar -xJf "$tmp/$tar" -C /opt/node --strip-components=1
    ln -sf /opt/node/bin/node /usr/local/bin/node; ln -sf /opt/node/bin/npm /usr/local/bin/npm; ln -sf /opt/node/bin/npx /usr/local/bin/npx
    rm -rf "$tmp"
  fi
  node -v
  mkdir -p /opt/xr
  install -m 0755 "$HERE/chrome-gpu.sh" /opt/xr/chrome-gpu.sh
}

# Some hosts give the container only the CUDA part of the NVIDIA driver (no OpenGL/EGL/Vulkan), so WebGL cannot use the GPU.
# Vast.ai's own base image ships /opt/instance-tools/bin/install-display-drivers for exactly this (github.com/vast-ai/base-image).
# Elsewhere (RunPod, plain images) the same approach: download the .run of the host's exact driver version and extract the libs.
display_libs() {
  log "NVIDIA graphics libraries"
  command -v nvidia-smi >/dev/null || { echo "no nvidia-smi: this box has no NVIDIA GPU"; exit 3; }
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
  if vulkaninfo --summary 2>/dev/null | grep -qi 'nvidia'; then echo "Vulkan already sees the NVIDIA GPU"; return 0; fi
  if [ -x /opt/instance-tools/bin/install-display-drivers ]; then
    /opt/instance-tools/bin/install-display-drivers
  else
    local ver dir tmp run
    ver="$(head -n1 /proc/driver/nvidia/version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    [ -n "$ver" ] || { echo "cannot read the host driver version"; exit 3; }
    dir=/opt/nvidia-drivers
    if [ "$(cat "$dir/.driver-version" 2>/dev/null)" != "$ver" ]; then
      tmp="$(mktemp -d)"; run="NVIDIA-Linux-x86_64-$ver.run"
      curl -fL -o "$tmp/$run" "https://international.download.nvidia.com/XFree86/Linux-x86_64/$ver/$run" \
        || curl -fL -o "$tmp/$run" "https://international.download.nvidia.com/tesla/$ver/$run"
      sh "$tmp/$run" --extract-only --target "$tmp/x" >/dev/null
      rm -rf "$dir"; mkdir -p "$dir/lib64"
      cp -a "$tmp/x"/*.so* "$dir/lib64/"
      cp -a "$tmp/x/nvidia_icd.json" "$dir/" 2>/dev/null || true
      cp -a "$tmp/x/10_nvidia.json" "$dir/" 2>/dev/null || true
      echo "$ver" > "$dir/.driver-version"
      rm -rf "$tmp"
    fi
    # zz-: after the libraries the NVIDIA container toolkit already mounted, so those keep priority
    echo "$dir/lib64" > /etc/ld.so.conf.d/zz-nvidia-drivers.conf && ldconfig
    mkdir -p /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d
    [ -f /etc/vulkan/icd.d/nvidia_icd.json ] || [ ! -f "$dir/nvidia_icd.json" ] || cp "$dir/nvidia_icd.json" /etc/vulkan/icd.d/
    [ -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ] || [ ! -f "$dir/10_nvidia.json" ] || cp "$dir/10_nvidia.json" /usr/share/glvnd/egl_vendor.d/
  fi
  vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName|apiVersion' | head -6 || echo "vulkaninfo shows no device (EGL fallback will be tried)"
}

npm_part() {
  log "npm install (puppeteer 22.15.0 + its Chrome 127) in the uploaded pipelines"
  local first="" d
  # every uploaded pipeline: a package.json outside node_modules that depends on puppeteer (no names: this file goes into the image)
  for d in $(find "$WORK" -maxdepth 5 -name package.json -not -path '*/node_modules/*' -exec grep -l '"puppeteer"' {} + 2>/dev/null | xargs -r -n1 dirname | sort); do
    (cd "$d" && env -u PUPPETEER_EXECUTABLE_PATH npm ci --no-audit --no-fund --loglevel=error)
    [ -n "$first" ] || first="$d"
  done
  [ -n "$first" ] || { echo "no pipeline uploaded to $WORK yet"; exit 4; }
  local bin
  bin="$(cd "$first" && env -u PUPPETEER_EXECUTABLE_PATH node -e "console.log(require('puppeteer').executablePath())")"
  [ -x "$bin" ] || { echo "puppeteer's Chrome not found at $bin"; exit 4; }
  mkdir -p /opt/xr
  cat > /opt/xr/env <<EOF
export XR_CHROME_BIN="$bin"
export PUPPETEER_EXECUTABLE_PATH=/opt/xr/chrome-gpu.sh
export XR_GL="\${XR_GL:-egl}"
export XR_PIPE="$first"
EOF
  echo "Chrome: $bin"
}

gpu_check() {
  log "WebGL check"
  . /opt/xr/env
  # EGL first: ANGLE-Vulkan failed pipeline creation on the studio shaders (NVIDIA 580.x, 11 Nov 2026), see chrome-gpu.sh
  if XR_GL=egl node "$HERE/gpu-check.mjs" "$XR_PIPE"; then sed -i 's/^export XR_GL=.*/export XR_GL="${XR_GL:-egl}"/' /opt/xr/env; return 0; fi
  echo "EGL path failed, trying Vulkan (check the studio test for GL errors before trusting it)"
  if XR_GL=vulkan node "$HERE/gpu-check.mjs" "$XR_PIPE"; then sed -i 's/^export XR_GL=.*/export XR_GL="${XR_GL:-vulkan}"/' /opt/xr/env; return 0; fi
  echo "WebGL does not reach the GPU on this host: stop here (do not render in software)"; exit 5
}

case "$MODE" in
  --image) image_part ;;
  --boot)  mkdir -p /opt/xr && install -m 0755 "$HERE/chrome-gpu.sh" /opt/xr/chrome-gpu.sh   # newest wrapper, also on a prebaked image
           display_libs; npm_part; gpu_check ;;
  --full)  image_part; display_libs; npm_part; gpu_check ;;
  *) echo "usage: setup.sh [--full|--image|--boot]"; exit 2 ;;
esac
log "setup done ($MODE)"
