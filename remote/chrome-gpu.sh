#!/usr/bin/env bash
# Chrome wrapper for the rented Linux GPU box. Puppeteer starts this file instead of Chrome
# (setup.sh sets PUPPETEER_EXECUTABLE_PATH to it), so render.mjs, render-chunks.mjs and stills.mjs run unchanged.
#
# Why: the channel scripts pass macOS flags (--use-angle=metal). On Linux, headless Chrome disables the GPU by default
# and falls back to SwiftShader (software, far slower and a different picture). This wrapper drops the macOS GL flags and
# adds the Linux NVIDIA ones. Sources: developer.chrome.com/blog/supercharge-web-ai-testing (Vulkan flags for NVIDIA),
# Remotion's open-browser.ts (same Vulkan set plus --use-vulkan=native and --disable-vulkan-fallback-to-gl-for-testing).
#
#   XR_GL=egl (default)  ANGLE on OpenGL ES via NVIDIA EGL. Tested 11 Nov 2026 on RTX 4090 / driver 580.159: 0 GL errors,
#                        V03 studio loads in 4.6 s, 6.7 fps in one window.
#   XR_GL=vulkan         ANGLE on Vulkan (the Chrome team's recipe). Same box: 809x "createPipeline ... Internal Vulkan error (-13)"
#                        and 270x "NVVM compilation failed" on the studio's shaders, i.e. missing draws, and 1.8 fps. Do not use.
#   XR_CHROME_BIN        the real Chrome binary (written by setup.sh into /opt/xr/env)
set -euo pipefail
[ -f /opt/xr/env ] && . /opt/xr/env
REAL="${XR_CHROME_BIN:?XR_CHROME_BIN not set: run setup.sh first}"
GL="${XR_GL:-egl}"

args=()
features=""
has_headless=0
for a in "$@"; do
  case "$a" in
    --use-angle=*|--use-gl=*|--use-vulkan=*) ;;                     # macOS values from the channel scripts: dropped
    --enable-features=*) features="${a#--enable-features=}" ;;       # merged below, so puppeteer's own features survive
    --headless|--headless=*) has_headless=1; args+=("$a") ;;
    *) args+=("$a") ;;
  esac
done
# render.mjs without --headless asks for a visible window; there is no display here, so run the new headless mode.
[ "$has_headless" = 1 ] || args+=(--headless=new)

case "$GL" in
  vulkan)
    features="${features:+$features,}Vulkan"
    gl=(--use-angle=vulkan --use-vulkan=native --disable-vulkan-fallback-to-gl-for-testing --disable-vulkan-surface)
    ;;
  egl)
    gl=(--use-gl=angle --use-angle=gl-egl)
    ;;
  *) echo "chrome-gpu.sh: unknown XR_GL=$GL (use vulkan or egl)" >&2; exit 2 ;;
esac
[ -n "$features" ] && gl+=("--enable-features=$features")

# --no-sandbox: the container runs as root. --disable-dev-shm-usage: Docker's small /dev/shm crashes big pages.
# --font-render-hinting=none: closer to macOS glyph shapes for DOM text (labels, captions, kinetic type).
exec "$REAL" "${args[@]}" "${gl[@]}" --enable-gpu --ignore-gpu-blocklist --no-sandbox --disable-dev-shm-usage \
  --font-render-hinting=none
