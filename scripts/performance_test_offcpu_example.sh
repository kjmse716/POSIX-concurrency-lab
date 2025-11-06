#!/bin/bash

# ==============================================================================
# Off-CPU Flame Graph 生成腳本 for POSIX Concurrency Lab (v5.0 穩定版)
# 主要修正:
# - 改用 stackcollapse-perf.pl（而非 stackcollapse-perf-sched.awk）
# - 參考已驗證成功的 minimal 指令序列
# - 強化錯誤與資料存在性檢查
# ==============================================================================

set -e

# --- 組態設定 ---

PRODUCT_COUNT=100000
BUFFER_SIZE=4
MESSAGE_LEN=64

# --- 路徑設定 ---

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FLAMEGRAPH_DIR="${PROJECT_ROOT_DIR}/library/FlameGraph"
THREAD_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc/itc_producer_consumer.c"
IPC_APP_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc"
IPC_RUN_SCRIPT="${IPC_APP_DIR}/run_ipc_test.sh"
THREAD_EXE_NAME="thread_test_offcpu"
THREAD_EXE_PATH="${SCRIPT_DIR}/${THREAD_EXE_NAME}"
RESULTS_DIR="${SCRIPT_DIR}/off_cpu_results"
mkdir -p "$RESULTS_DIR"

# --- 前置檢查 ---

if [[ $EUID -ne 0 ]]; then
echo "!! 錯誤：此腳本需要 root 權限 (sudo) 才能執行 perf。"
exit 1
fi

if [ ! -f "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" ]; then
echo "!! 錯誤：找不到 FlameGraph 的 stackcollapse-perf.pl。"
exit 1
fi

echo "===================================================="
echo " Off-CPU Flame Graph 生成腳本 (v5.0)"
echo "===================================================="
echo "工作負載設定:"
echo " - Product Count: ${PRODUCT_COUNT}"
echo " - Buffer Size: ${BUFFER_SIZE}"
echo " - Message Len: ${MESSAGE_LEN}"
echo "結果將儲存於: ${RESULTS_DIR}"
echo "----------------------------------------------------"

cleanup() {
echo ">> 清理暫存的執行檔與 perf 資料..."
rm -f "$THREAD_EXE_PATH" perf.data perf.data.old
if [ -f "${IPC_APP_DIR}/Makefile" ]; then
(cd "${IPC_APP_DIR}" && make clean) > /dev/null 2>&1
fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1️⃣ ITC (執行緒) 模型
# -----------------------------------------------------------------------------

echo ">> [1/2] 正在分析 ITC (執行緒) 模型..."
# 修正：為多行指令加上反斜線 \
gcc -g "${THREAD_SRC}" -o "${THREAD_EXE_PATH}" \
-DNUM_PRODUCTS=${PRODUCT_COUNT} \
-DBUFFER_SIZE=${BUFFER_SIZE} \
-DMAX_MESSAGE_LEN=${MESSAGE_LEN} \
-lpthread -lrt

echo " - 使用 perf record 進行 Off-CPU 時間採樣..."
sudo perf record -e sched:sched_switch -a --call-graph dwarf -- "${THREAD_EXE_PATH}" > /dev/null 2>&1

if [ ! -s perf.data ]; then
echo "!! 警告: perf record 未能採集到任何數據 (ITC)。"
else
echo " - 生成 flamegraph..."
ITC_TXT="${RESULTS_DIR}/perf.itc.txt"
ITC_FOLDED="${RESULTS_DIR}/perf.itc.folded"
ITC_SVG="${RESULTS_DIR}/itc_offcpu_flamegraph.svg"

sudo perf script > "$ITC_TXT" 2>/dev/null
"${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" "$ITC_TXT" > "$ITC_FOLDED" 2>/dev/null || true

if [ ! -s "$ITC_FOLDED" ]; then
echo "!! 錯誤: 無法生成 folded stacks (ITC)。"
echo "!! 以下為 perf script 前 30 行供除錯："
head -n 30 "$ITC_TXT"
else
# 修正：為多行指令加上反斜線 \
"${FLAMEGRAPH_DIR}/flamegraph.pl" --color=io --title="ITC Off-CPU Time Flame Graph" \
--countname=ms "$ITC_FOLDED" > "$ITC_SVG"
echo " - ITC 火焰圖生成完成: $ITC_SVG"
fi
fi

echo "----------------------------------------------------"

# -----------------------------------------------------------------------------
# 2️⃣ IPC (行程) 模型
# -----------------------------------------------------------------------------

echo ">> [2/2] 正在分析 IPC (行程) 模型..."
(cd "${IPC_APP_DIR}" && make CFLAGS+="-g -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${BUFFER_SIZE} -DMAX_MESSAGE_LEN=${MESSAGE_LEN}") > /dev/null 2>&1

echo " - 使用 perf record 進行 Off-CPU 時間採樣 (IPC)..."
sudo perf record -e sched:sched_switch -a --call-graph dwarf -- "${IPC_RUN_SCRIPT}" > /dev/null 2>&1

if [ ! -s perf.data ]; then
echo "!! 警告: perf record 未能採集到任何數據 (IPC)。"
else
echo " - 生成 flamegraph..."
IPC_TXT="${RESULTS_DIR}/perf.ipc.txt"
IPC_FOLDED="${RESULTS_DIR}/perf.ipc.folded"
IPC_SVG="${RESULTS_DIR}/ipc_offcpu_flamegraph.svg"

sudo perf script > "$IPC_TXT" 2>/dev/null
"${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" "$IPC_TXT" > "$IPC_FOLDED" 2>/dev/null || true

if [ ! -s "$IPC_FOLDED" ]; then
echo "!! 錯誤: 無法生成 folded stacks (IPC)。"
echo "!! 以下為 perf script 前 30 行供除錯："
head -n 30 "$IPC_TXT"
else
# 修正：為多行指令加上反斜線 \
"${FLAMEGRAPH_DIR}/flamegraph.pl" --color=io --title="IPC Off-CPU Time Flame Graph" \
--countname=ms "$IPC_FOLDED" > "$IPC_SVG"
echo " - IPC 火焰圖生成完成: $IPC_SVG"
fi
fi

echo "----------------------------------------------------"
echo ">> 所有分析完成！"
echo "===================================================="
