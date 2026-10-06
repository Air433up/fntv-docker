# =============================================================================
# trimmedia-linux-arm — Docker 化多阶段构建
#
# 目标平台: linux/arm64（斐讯 N1 / Amlogic S905 / 各类 arm64 盒子与 SBC）
#
# 构建:
#   docker build -t trimmedia-linux-arm:local .
#   # 国内网络下载 GitHub 资源慢时:
#   docker build --build-arg PROXY_PREFIX=https://ghproxy.net/ -t trimmedia-linux-arm:local .
#
# 说明:
#   - Stage1(builder): 用 Go 编译 4 个启动器 + gcc 编译 3 个 LD_PRELOAD 打桩库
#   - Stage2(assets):  下载 release v1 的 4 个资源包并做 sha256 校验、解压
#   - Stage3(runtime): debian trixie-slim（预编译核心最高需要 GLIBC_2.38）最终镜像
# =============================================================================

ARG GO_IMAGE=golang:1.26-trixie
ARG BASE_IMAGE=debian:trixie-slim

# -----------------------------------------------------------------------------
# Stage 1: 编译启动器与打桩库
# -----------------------------------------------------------------------------
FROM ${GO_IMAGE} AS builder
WORKDIR /src

COPY nodri.c nodmaheap.c fakecompat.c ./
COPY apps/rpcbroker/ ./apps/rpcbroker/
COPY apps/mediasrv/  ./apps/mediasrv/
COPY apps/fntv/      ./apps/fntv/
COPY apps/fnmusic/   ./apps/fnmusic/

# 4 个 Go 启动器（纯标准库，无需联网拉依赖；离线性由 go.mod 无 require 保证）
# 3 个打桩库（mediasrv 运行期由启动器自动 LD_PRELOAD）
RUN set -eux; \
    mkdir -p /out/bin /out/stubs; \
    for app in rpcbroker mediasrv fntv fnmusic; do \
        ( cd "/src/apps/$app" && \
          CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GO111MODULE=on \
          go build -trimpath -ldflags "-s -w" -o "/out/bin/$app.arm64" . ); \
    done; \
    gcc -shared -fPIC -O2 -o /out/stubs/nodri.so     /src/nodri.c; \
    gcc -shared -fPIC -O2 -o /out/stubs/nodmaheap.so /src/nodmaheap.c; \
    gcc -shared -fPIC -O2 -o /out/stubs/fakecompat.so /src/fakecompat.c; \
    ls -l /out/bin /out/stubs

# -----------------------------------------------------------------------------
# Stage 2: 下载 + 校验 + 解压运行时资源（固定 release v1）
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS assets
ARG PROXY_PREFIX=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /assets

# 下载（支持 PROXY_PREFIX 加速前缀，例如 https://ghproxy.net/）
RUN set -eux; \
    base="https://github.com/kesry/trimmedia-linux-arm/releases/download/v1"; \
    p="${PROXY_PREFIX}"; \
    wget -4 -O trim-media-lib.zip "${p}${base}/trim-media-lib.zip"; \
    wget -4 -O lib.extends.zip   "${p}${base}/lib.extends.zip"; \
    wget -4 -O trim.media.tar.gz "${p}${base}/trim.media.tar.gz"; \
    wget -4 -O trim.music.tar.gz "${p}${base}/trim.music.tar.gz"

# sha256 校验（固定自 release v1 的官方 digest，防止下载损坏/被篡改）
RUN set -eux; \
    echo "85a5cf311691ec5e4548c2be7e9b39e456518e00b37c5e8a2e92df953568dc8f  trim-media-lib.zip" | sha256sum -c -; \
    echo "c1bc3cdf4c3b466829306c04cc442138156c95e04f97d0147fb1728cb647e54c  lib.extends.zip"   | sha256sum -c -; \
    echo "b8c4bdf703e0d88d233eff988386b8f0b05427d5573decbae5f76c00f2f5ebf8  trim.media.tar.gz" | sha256sum -c -; \
    echo "7705b923d9a346e97117e54083a00378d9e1f82858cfc95f2ee9b724f289f276  trim.music.tar.gz" | sha256sum -c -

# 解压为最终目录布局
#   /out/mediasrv/{lib,bin,extends}     ← trim-media-lib.zip + lib.extends.zip
#   /out/fntv/trim.media                ← trim.media.tar.gz
#   /out/fnmusic/trim.music             ← trim.music.tar.gz
RUN set -eux; \
    mkdir -p /out/mediasrv /out/fntv /out/fnmusic; \
    unzip -q trim-media-lib.zip -d /out/mediasrv; \
    unzip -q lib.extends.zip   -d /out/mediasrv; \
    tar -xzf trim.media.tar.gz -C /out/fntv; \
    tar -xzf trim.music.tar.gz -C /out/fnmusic; \
    test -d /out/mediasrv/lib; \
    test -d /out/mediasrv/bin; \
    test -d /out/mediasrv/extends; \
    test -d /out/fntv/trim.media; \
    test -d /out/fnmusic/trim.music; \
    echo "=== assets ready ==="; \
    du -sh /out/mediasrv /out/fntv /out/fnmusic

# -----------------------------------------------------------------------------
# Stage 3: 运行时镜像
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# 运行时系统依赖:
#   sqlite3    —— fntv / fnmusic 启动器初始化数据库时调用
#   tzdata     —— 时区（TZ 环境变量生效）
#   ca-certificates —— 若后续需要对外 HTTPS（如元数据刮削）
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 tzdata ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# ---- rpcbroker（必须最先启动的系统服务伪造层） ----
COPY --from=builder /out/bin/rpcbroker.arm64 /opt/trim/rpcbroker/rpcbroker.arm64

# ---- mediasrv（转码服务 + 打桩库） ----
COPY --from=builder /out/bin/mediasrv.arm64 /opt/trim/mediasrv/mediasrv.arm64
COPY --from=builder /out/stubs /opt/trim/mediasrv/stubs
COPY --from=assets  /out/mediasrv /opt/trim/mediasrv

# ---- fntv（飞牛影视） ----
COPY --from=builder /out/bin/fntv.arm64 /opt/trim/fntv/fntv.arm64
COPY apps/fntv/init.sql        /opt/trim/fntv/init.sql
COPY apps/fntv/lib/            /opt/trim/fntv/lib/
COPY --from=assets  /out/fntv/trim.media /opt/trim/fntv/trim.media

# ---- fnmusic（飞牛音乐） ----
COPY --from=builder /out/bin/fnmusic.arm64 /opt/trim/fnmusic/fnmusic.arm64
COPY apps/fnmusic/init_data.sql /opt/trim/fnmusic/init_data.sql
COPY apps/fnmusic/lib/          /opt/trim/fnmusic/lib/
COPY --from=assets  /out/fnmusic/trim.music /opt/trim/fnmusic/trim.music

# ---- 入口脚本与权限 ----
COPY docker/entrypoint.sh /opt/trim/entrypoint.sh

RUN set -eux; \
    chmod +x /opt/trim/entrypoint.sh \
             /opt/trim/rpcbroker/rpcbroker.arm64 \
             /opt/trim/mediasrv/mediasrv.arm64 \
             /opt/trim/fntv/fntv.arm64 \
             /opt/trim/fnmusic/fnmusic.arm64 \
             /opt/trim/fntv/trim.media/trim-media \
             /opt/trim/fnmusic/trim.music/trim-music \
             /opt/trim/mediasrv/bin/mediasrv 2>/dev/null || true; \
    mkdir -p /opt/trim/fntv/data /vol1/1000

EXPOSE 8005 8007

HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
    CMD test -S /run/trim_app_cgi/rpcbroker || exit 1

ENTRYPOINT ["/opt/trim/entrypoint.sh"]
CMD ["start"]
