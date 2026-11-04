#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$SCRIPT_DIR/zig-out/bin/sushi"
OFFICIAL_BIN="$(which sushi 2>/dev/null || echo "/opt/homebrew/bin/sushi")"

# 支持命令行参数指定，如:
#   ./run_qwen_flash.sh 2.75 --local --cool
#   ./run_qwen_flash.sh 4 --official --perf --clean --public
CLEAR_CACHE=false
THERMAL_MODE=""
BIN_CHOICE=""
BIND_ALL=""
FILTERED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean|--clear-cache)
            CLEAR_CACHE=true
            ;;
        --cool|--eco)
            THERMAL_MODE="cool"
            ;;
        --perf|--performance)
            THERMAL_MODE="perf"
            ;;
        --local|--dev)
            BIN_CHOICE="local"
            ;;
        --official|--brew|--system)
            BIN_CHOICE="official"
            ;;
        --public|--lan|--0.0.0.0|--host-all)
            BIND_ALL=true
            ;;
        --localhost|--local-only|--127.0.0.1)
            BIND_ALL=false
            ;;
        *)
            FILTERED_ARGS+=("$arg")
            ;;
    esac
done
set -- "${FILTERED_ARGS[@]}"

QUANT_CHOICE="$1"
if [ -n "$QUANT_CHOICE" ]; then
    shift # 移除位置参数，把后续其他参数留给 sushi serve
fi

if [ -z "$QUANT_CHOICE" ]; then
    echo "=========================================="
    echo "请选择要启动的 Qwen3.8-Flash-Next 版本:"
    echo "  1) 4bpw                    (推荐用于 96GB+ 机器，wired_limit ~88GB)"
    echo "  2) 2.75bpw                 (STQ 版本，适用于 64GB 机器，wired_limit ~59GB)"
    echo "  3) 2.75bpw-uncensored      (STQ 版本 + 去除审查向量 china-v1)"
    echo "  4) 4bpw-uncensored         (4bpw 版本 + 去除审查向量 china-v1)"
    echo "=========================================="
    read -rp "输入选项 [1, 2, 3 或 4，默认 2]: " USER_INPUT
    case "$USER_INPUT" in
        2|2.75|2.75bpw|"")
            QUANT_CHOICE="2.75"
            ;;
        3|2.75-uncensored|uncensored)
            QUANT_CHOICE="2.75-uncensored"
            ;;
        4|4-uncensored)
            QUANT_CHOICE="4-uncensored"
            ;;
        1|4|4bpw|*)
            QUANT_CHOICE="4"
            ;;
    esac

    if [ "$CLEAR_CACHE" = false ]; then
        read -rp "是否清空 SSD 前缀缓存 (~/.sushi/kv-cache)？[y/N，默认 N]: " USER_CACHE_INPUT
        case "$USER_CACHE_INPUT" in
            [Yy]*) CLEAR_CACHE=true ;;
        esac
    fi

    if [ -z "$THERMAL_MODE" ]; then
        echo "------------------------------------------"
        echo "请选择温控运行模式:"
        echo "  1) 低温护机模式 (推荐日常: 降温省电, 限制MTP深度, Prefill保持2048满速)"
        echo "  2) 极致性能模式 (满血全开, 深度投机~50-58 tok/s, 发热与风扇较大)"
        echo "------------------------------------------"
        read -rp "输入模式选项 [1 或 2，默认 1]: " THERMAL_CHOICE
        case "$THERMAL_CHOICE" in
            2|perf|performance)
                THERMAL_MODE="perf"
                ;;
            1|cool|eco|*)
                THERMAL_MODE="cool"
                ;;
        esac
    fi

    if [ -z "$BIN_CHOICE" ]; then
        echo "------------------------------------------"
        echo "请选择运行的 Sushi 程序内核:"
        echo "  1) 本地自编译版 (推荐: ./zig-out/bin/sushi, 含最新WebUI、联网搜索与统计面板)"
        echo "  2) 官方正式版   (Homebrew: $OFFICIAL_BIN)"
        echo "------------------------------------------"
        read -rp "输入内核选项 [1 或 2，默认 1]: " BIN_INPUT
        case "$BIN_INPUT" in
            2|official|brew|system)
                BIN_CHOICE="official"
                ;;
            1|local|dev|*)
                BIN_CHOICE="local"
                ;;
        esac
    fi

    if [ -z "$BIND_ALL" ]; then
        echo "------------------------------------------"
        read -rp "是否绑定到 0.0.0.0 开放局域网访问？[y/N，默认 N (仅限本机 127.0.0.1)]: " USER_BIND_INPUT
        case "$USER_BIND_INPUT" in
            [Yy]*) BIND_ALL=true ;;
            *) BIND_ALL=false ;;
        esac
    fi
fi

THERMAL_MODE="${THERMAL_MODE:-cool}"

CVECTOR_FLAG=()
case "$QUANT_CHOICE" in
    2|2.75|2.75bpw)
        TARGET_LIMIT=69000
        MODEL_NAME="Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw"
        ;;
    3|2.75-uncensored|uncensored)
        TARGET_LIMIT=69000
        MODEL_NAME="Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw"
        CVECTOR_FLAG=(--control-vector "$HOME/.lmstudio/models/zjj1993/Qwen3.8-Flash-Next-uncensored-china/china-v1.safetensors")
        ;;
    4|4-uncensored)
        TARGET_LIMIT=88000
        MODEL_NAME="Qwen3.8-Flash-Next-Sushi-4bpw"
        CVECTOR_FLAG=(--control-vector "$HOME/.lmstudio/models/zjj1993/Qwen3.8-Flash-Next-uncensored-china/china-v1.safetensors")
        ;;
    1|4|4bpw|*)
        TARGET_LIMIT=88000
        MODEL_NAME="Qwen3.8-Flash-Next-Sushi-4bpw"
        ;;
esac

MODEL_PATH="$HOME/.sushi/models/beamster/$MODEL_NAME"

echo "📦 当前选择模型: $MODEL_NAME"

# 1. 检查并按需设置 macOS 显存上限 (wired_limit_mb)
CURRENT_LIMIT=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)

if [ "$CURRENT_LIMIT" -lt "$TARGET_LIMIT" ]; then
    echo "⚙️ 当前 iogpu.wired_limit_mb 为 ${CURRENT_LIMIT}MB，需要设置为 ${TARGET_LIMIT}MB..."
    sudo sysctl iogpu.wired_limit_mb=$TARGET_LIMIT
else
    echo "✅ iogpu.wired_limit_mb 已就绪 (${CURRENT_LIMIT}MB >= ${TARGET_LIMIT}MB)，无需重复设置"
fi

# 2. 检查模型目录是否存在
if [ ! -d "$MODEL_PATH" ]; then
    echo "❌ 错误: 未找到模型目录: $MODEL_PATH"
    echo "请确认是否已下载完成并放置在 ~/.sushi/models/beamster/$MODEL_NAME"
    exit 1
fi

# 3. 按需清理 SSD 前缀缓存
if [ "$CLEAR_CACHE" = true ]; then
    CACHE_DIR="$HOME/.sushi/kv-cache"
    if [ -d "$CACHE_DIR" ]; then
        echo "🧹 正在清理 SSD 前缀缓存 ($CACHE_DIR/*)..."
        rm -rf "$CACHE_DIR"/*
        echo "✨ 缓存已清空"
    fi
fi

# 4. 解析选择的 Sushi 二进制程序
BIN_CHOICE="${BIN_CHOICE:-local}"
if [ "$BIN_CHOICE" = "official" ]; then
    SUSHI_BIN="$OFFICIAL_BIN"
    BIN_DESC="官方正式版 ($OFFICIAL_BIN)"
else
    if [ -x "$LOCAL_BIN" ]; then
        SUSHI_BIN="$LOCAL_BIN"
        BIN_DESC="本地自编译版 ($LOCAL_BIN)"
    else
        echo "⚠️ 未在本地检测到编译好的程序 ($LOCAL_BIN)，回退至官方正式版 ($OFFICIAL_BIN)"
        SUSHI_BIN="$OFFICIAL_BIN"
        BIN_DESC="官方正式版 (自动回退)"
    fi
fi

echo "🚀 启动 sushi 服务 ($MODEL_NAME | 内核: $BIN_DESC)..."

# 5. 组装网络绑定参数
BIND_ALL="${BIND_ALL:-false}"
HOST_FLAGS=()
if [ "$BIND_ALL" = true ]; then
    HOST_FLAGS=(--host 0.0.0.0)
    echo "🌐 网络绑定: 0.0.0.0 (局域网设备可访问)"
else
    echo "🔒 网络绑定: 127.0.0.1 (仅限本机访问)"
fi

# 6. 组装温控与启动参数
THERMAL_FLAGS=()
RUN_CMD=("$SUSHI_BIN" serve)

if [ "$THERMAL_MODE" = "cool" ]; then
    echo "❄️ 温控模式: 低温护机已激活 (MTP深度限3, 保持Prefill 2048, 关闭GPU空闲保温)"
    THERMAL_FLAGS+=(
        --mtp-max-depth 3
        --prefill-chunk 2048
        --gpu-warm-secs 0
    )
else
    echo "🔥 运行模式: 极致性能已激活 (全频调度, 深度投机)"
    RUN_CMD=(taskpolicy -a "$SUSHI_BIN" serve)
    THERMAL_FLAGS+=(
        --prefill-chunk 2048
    )
fi

exec "${RUN_CMD[@]}" \
  --model "$MODEL_PATH" \
  ${HOST_FLAGS[@]+"${HOST_FLAGS[@]}"} \
  --qwen-gdn 16 \
  ${CVECTOR_FLAG[@]+"${CVECTOR_FLAG[@]}"} \
  --mtp \
  --kv-quant 8 \
  --mtp-head-kv-quant \
  --ctx-size 500000 \
  "${THERMAL_FLAGS[@]}" \
  --max-tokens 64000 \
  --prefix-cache-disk 20GB \
  --prefix-cache-entries 1 \
  --temp 1 "$@"

