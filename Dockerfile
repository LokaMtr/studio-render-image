# Prebaked render image: apt packages, fonts, Node 22.12.0, ffmpeg 9.0 and puppeteer 22.15.0's Chrome 127 are already inside,
# so a rented box only runs `setup.sh --boot` (NVIDIA graphics libs for that host's driver, npm ci, GPU check).
# Built by GitHub Actions (ci/image.yml) and pushed to GHCR; never built on the Mac (x86 emulation on an 8 GB M2).
# Nothing secret and no personal paths in here: only remote/setup.sh and remote/chrome-gpu.sh are copied.
# Tag = first 12 hex of sha256 over this file + remote/setup.sh + remote/chrome-gpu.sh (publish-image.sh computes the same).
FROM vastai/base-image:cuda-12.8.1-cudnn-devel-ubuntu22.04

# OpenGL/EGL/Vulkan from the host driver, not only CUDA (read by the NVIDIA container toolkit when the box starts)
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV WORK=/work

COPY remote/setup.sh remote/chrome-gpu.sh /opt/xr/src/
RUN chmod +x /opt/xr/src/*.sh \
 && bash /opt/xr/src/setup.sh --image \
 && npm install --prefix /opt/xr/warm --no-audit --no-fund --loglevel=error puppeteer@22.15.0 \
 && ls /root/.cache/puppeteer \
 && python3 -m pip install --no-cache-dir --quiet pillow numpy \
 && rm -rf /var/lib/apt/lists/* /root/.npm/_logs
