#!/bin/bash
# =============================================================================
# trimmedia-linux-arm 容器入口脚本
#
# 用法（容器内）:
#   entrypoint.sh start    启动全部服务（默认）
#   entrypoint.sh check    环境自检（不启动任何服务）
#   entrypoint.sh shell    进入交互式 bash
#
# 环境变量:
#   MEDIA_DIR         媒体库根目录（默认 /vol1/1000，即挂载点）
#   FNTV_WEB_PORT     飞牛影视 Web 端口（默认 8005）
#   FNMUSIC_WEB_PORT  飞牛音乐 Web 端口（默认 8007）
#   ENABLE_MEDIASRV   是否启动转码服务（默认 1）
#   ENABLE_FNTV       是否启动影视（默认 1）
#   ENABLE_FNMUSIC    是否启动音乐（默认 1）
#   LOG_LEVEL         info / debug（默认 info）
# =============================================================================
set -uo pipefail
# 注意：不使用 set -e，因为启动多个后台服务需要容忍单个失败以打印诊断日志

TRIM_ROOT=/opt/trim
MEDIA_DIR="${MEDIA_DIR:-/vol1/1000}"
FNTV_WEB_PORT="${FNTV_WEB_PORT:-8005}"
FNMUSIC_WEB_PORT="${FNMUSIC_WEB_PORT:-8007}"
ENABLE_MEDIASRV="${ENABLE_MEDIASRV:-1}"
ENABLE_FNTV="${ENABLE_FNTV:-1}"
ENABLE_FNMUSIC="${ENABLE_FNMUSIC:-1}"
LOG_LEVEL="${LOG_LEVEL:-info}"
export LOG_LEVEL MEDIA_DIR

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint][WARN] $*" >&2; }
die()  { echo "[entrypoint][ERROR] $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 通用目录准备
# -----------------------------------------------------------------------------
prepare_dirs() {
    mkdir -p /run/trim_app_cgi /usr/trim/etc /var/run /var/apps
    mkdir -p "$MEDIA_DIR"
    mkdir -p "$MEDIA_DIR/default"
}

# -----------------------------------------------------------------------------
# mediasrv 的 LD_PRELOAD 打桩库分发
# 复刻原项目 install.sh 的规则：
#   - nodri.so      : 隐藏 /dev/dri，使 mediasrv 跳过 PCI/GPU 分支（始终启用）
#   - fakecompat.so : 仅当 /proc/device-tree/compatible 不存在时启用
#   - nodmaheap.so  : 仅当 /dev/dma_heap 存在时启用（隐藏它）
# 启动器 mediasrv.arm64 会自动对 lib/ 下"存在"的 .so 做 LD_PRELOAD。
# -----------------------------------------------------------------------------
prepare_stubs() {
    local lib=$TRIM_ROOT/mediasrv/lib
    local avail=$TRIM_ROOT/mediasrv/stubs
    mkdir -p "$lib"

    if [ -f "$avail/nodri.so" ]; then
        cp -f "$avail/nodri.so" "$lib/nodri.so"
        log "stub: nodri.so -> enabled"
    fi
    if [ ! -e /proc/device-tree/compatible ] && [ -f "$avail/fakecompat.so" ]; then
        cp -f "$avail/fakecompat.so" "$lib/fakecompat.so"
        log "stub: fakecompat.so -> enabled (no /proc/device-tree/compatible)"
    else
        rm -f "$lib/fakecompat.so"
    fi
    if [ -e /dev/dma_heap ] && [ -f "$avail/nodmaheap.so" ]; then
        cp -f "$avail/nodmaheap.so" "$lib/nodmaheap.so"
        log "stub: nodmaheap.so -> enabled (/dev/dma_heap present)"
    else
        rm -f "$lib/nodmaheap.so"
    fi
}

# -----------------------------------------------------------------------------
# 等待 unix socket 文件出现（就绪探测）
# -----------------------------------------------------------------------------
wait_for_socket() {
    local path="$1" name="$2" timeout="${3:-30}" i=0
    while [ $i -lt $((timeout * 10)) ]; do
        [ -S "$path" ] && { log "$name ready: $path"; return 0; }
        sleep 0.1
        i=$((i + 1))
    done
    warn "$name socket not ready after ${timeout}s: $path"
    return 1
}

# -----------------------------------------------------------------------------
# 服务进程管理
# -----------------------------------------------------------------------------
PIDS=()
NAMES=()

start_service() {
    # $1 = 服务名; 其余 = 命令行
    local name="$1"; shift
    log "starting $name ..."
    "$@" &
    local pid=$!
    PIDS+=("$pid")
    NAMES+=("$name")
    log "$name started (pid=$pid)"
}

shutdown() {
    local reason="${1:-TERM}"
    log "shutdown (${reason}), stopping all services ..."
    # 先 TERM（各启动器会级联终止自己的子进程组）
    local pid
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    # 最多等 10s
    for _ in $(seq 1 50); do
        local alive=0
        for pid in ${PIDS[@]+"${PIDS[@]}"}; do
            kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.2
    done
    # 兜底 KILL
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    log "all services stopped"
    exit 0
}

trap 'shutdown TERM' TERM
trap 'shutdown INT' INT

# -----------------------------------------------------------------------------
# 环境自检
# -----------------------------------------------------------------------------
do_check() {
    echo "==================== trimmedia 容器自检 ===================="
    echo "架构         : $(uname -m)  ($(uname -sr))"
    echo "媒体目录     : $MEDIA_DIR  可写=$([ -w "$MEDIA_DIR" ] && echo yes || echo no)"
    echo "device-tree  : $([ -e /proc/device-tree/compatible ] && echo present || echo absent)"
    echo "dev/dri      : $([ -e /dev/dri ] && echo present || echo absent)"
    echo "dev/dma_heap : $([ -e /dev/dma_heap ] && echo present || echo absent)"
    echo "sqlite3      : $(sqlite3 --version 2>/dev/null || echo MISSING)"
    echo ""

    echo "--- 关键二进制 ---"
    for f in \
        "$TRIM_ROOT/rpcbroker/rpcbroker.arm64" \
        "$TRIM_ROOT/mediasrv/mediasrv.arm64" \
        "$TRIM_ROOT/mediasrv/bin/mediasrv" \
        "$TRIM_ROOT/fntv/fntv.arm64" \
        "$TRIM_ROOT/fntv/trim.media/trim-media" \
        "$TRIM_ROOT/fnmusic/fnmusic.arm64" \
        "$TRIM_ROOT/fnmusic/trim.music/trim-music"; do
        if [ -f "$f" ]; then
            echo "ok   $f"
        else
            echo "MISS $f"
        fi
    done
    echo ""

    echo "--- 动态库解析检查（重点看 not found） ---"
    check_ldd() {
        local bin="$1" ldpath="$2"
        echo "### $bin"
        if [ -f "$bin" ]; then
            LD_LIBRARY_PATH="$ldpath" ldd "$bin" 2>&1 | grep -E "not found|=>" | head -20
        else
            echo "  (missing)"
        fi
    }
    check_ldd "$TRIM_ROOT/mediasrv/bin/mediasrv" \
        "$TRIM_ROOT/mediasrv/lib:$TRIM_ROOT/mediasrv/lib/mediasrv:$TRIM_ROOT/mediasrv/lib/mediasrv/lib:$TRIM_ROOT/mediasrv/extends"
    check_ldd "$TRIM_ROOT/fntv/trim.media/trim-media" "$TRIM_ROOT/fntv/lib"
    check_ldd "$TRIM_ROOT/fnmusic/trim.music/trim-music" "$TRIM_ROOT/fnmusic/lib"
    echo ""

    echo "--- 数据卷 ---"
    echo "fntv data    : $TRIM_ROOT/fntv/data      $([ -d "$TRIM_ROOT/fntv/data" ] && echo ok || echo missing)"
    echo "music home   : /var/apps/trim.music      $([ -d /var/apps/trim.music ] && echo ok || echo missing)"
    echo "============================================================"
}

# -----------------------------------------------------------------------------
# 启动流程
# -----------------------------------------------------------------------------
do_start() {
    prepare_dirs

    local any=0
    [ "$ENABLE_MEDIASRV" = "1" ] && any=1
    [ "$ENABLE_FNTV" = "1" ] && any=1
    [ "$ENABLE_FNMUSIC" = "1" ] && any=1
    [ "$any" = "0" ] && die "所有服务都被禁用（ENABLE_MEDIASRV/ENABLE_FNTV/ENABLE_FNMUSIC 全为 0）"

    # ---------- 1. rpcbroker（一切的前提，必须最先启动） ----------
    # fntv / fnmusic / mediasrv 都通过它的 unix socket 拿系统信息服务
    if [ "$ENABLE_FNTV" = "1" ] || [ "$ENABLE_FNMUSIC" = "1" ]; then
        start_service "rpcbroker" "$TRIM_ROOT/rpcbroker/rpcbroker.arm64"
        wait_for_socket "/run/trim_app_cgi/rpcbroker" "rpcbroker" 30 \
            || warn "rpcbroker 未就绪，fntv/fnmusic 可能拿不到授权目录"
    fi

    # ---------- 2. mediasrv（转码服务，fntv 依赖） ----------
    if [ "$ENABLE_MEDIASRV" = "1" ] && [ "$ENABLE_FNTV" = "1" ]; then
        prepare_stubs
        (cd "$TRIM_ROOT/mediasrv" && exec ./mediasrv.arm64) &
        PIDS+=($!)
        NAMES+=("mediasrv")
        log "mediasrv started (pid=${PIDS[-1]})"
        wait_for_socket "/var/run/mediasrv.socket" "mediasrv" 30 || true
    fi

    # ---------- 3. fntv（飞牛影视 :8005） ----------
    if [ "$ENABLE_FNTV" = "1" ]; then
        (cd "$TRIM_ROOT/fntv" && WEB_PORT="$FNTV_WEB_PORT" exec ./fntv.arm64) &
        PIDS+=($!)
        NAMES+=("fntv")
        log "fntv started (pid=${PIDS[-1]}, port=$FNTV_WEB_PORT)"
    fi

    # ---------- 4. fnmusic（飞牛音乐 :8007） ----------
    if [ "$ENABLE_FNMUSIC" = "1" ]; then
        (cd "$TRIM_ROOT/fnmusic" && WEB_PORT="$FNMUSIC_WEB_PORT" exec ./fnmusic.arm64) &
        PIDS+=($!)
        NAMES+=("fnmusic")
        log "fnmusic started (pid=${PIDS[-1]}, port=$FNMUSIC_WEB_PORT)"
    fi

    log "all services launched. fntv=http://<host>:$FNTV_WEB_PORT  fnmusic=http://<host>:$FNMUSIC_WEB_PORT"

    # ---------- 监控：任一服务退出则全部退出（交给 docker restart 策略） ----------
    while true; do
        local exited_pid
        wait -n -p exited_pid
        local code=$?
        local name="unknown"
        for i in "${!PIDS[@]}"; do
            if [ "${PIDS[$i]}" = "$exited_pid" ]; then
                name="${NAMES[$i]}"
                break
            fi
        done
        warn "service [$name] (pid=$exited_pid) exited with code $code"
        shutdown "service $name exited unexpectedly"
    done
}

# -----------------------------------------------------------------------------
case "${1:-start}" in
    start) do_start ;;
    check) do_check ;;
    shell) exec /bin/bash ;;
    *) echo "用法: entrypoint.sh [start|check|shell]"; exit 1 ;;
esac
