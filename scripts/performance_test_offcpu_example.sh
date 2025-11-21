#!/bin/bash

# ==============================================================================
# Off-CPU Flame Graph 生成腳本 (v5.2 - Full Affinity-Aware)
#
# 用法:
# ./scripts/performance_test_offcpu_example.sh [affinity_mode] [core_a] [core_b]
#
# 範例 (由 run_with_cpu_shield.sh 呼叫):
# (sudo ./scripts/run_with_cpu_shield.sh "6,7" ./scripts/performance_test_offcpu_example.sh rt-cross-core 6 7)
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
# IPC_RUN_SCRIPT="${IPC_APP_DIR}/run_ipc_test.sh" # 將不再使用
THREAD_EXE_NAME="thread_test_offcpu"
THREAD_EXE_PATH="${SCRIPT_DIR}/${THREAD_EXE_NAME}"

# --- 1. Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
THREAD_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS="" # [修改] 改名為通用編譯旗標

# 預設為 unlimited
if [ -z "$AFFINITY_MODE" ]; then
    AFFINITY_MODE="unlimited"
fi

RESULTS_DIR="${SCRIPT_DIR}/off_cpu_results_${AFFINITY_MODE}"
mkdir -p "$RESULTS_DIR"

echo "===================================================="
echo " Off-CPU Flame Graph 生成腳本 (v5.2)"
echo ">> 正在以模式運行: ${AFFINITY_MODE}"
echo "===================================================="

case "$AFFINITY_MODE" in
    "rt-single-core")
        echo "   - 綁定: Real-Time 單一核心 (Core ${CORE_A})"
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        # [修改] 設定 C 語言層級綁核巨集
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "rt-cross-core")
        echo "   - 綁定: Real-Time 跨核心 (P:${CORE_A}, C:${CORE_B})"
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A},${CORE_B}" 
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        # [修改] 設定 C 語言層級綁核巨集
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        echo "   - 綁定: 不限制 (unlimited)"
        AFFINITY_COMPILE_FLAGS=""
        ;;
    *)
        echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
        exit 1
        ;;
esac

echo "----------------------------------------------------"
echo "工作負載設定:"
echo " - Product Count: ${PRODUCT_COUNT}"
echo " - Buffer Size: ${BUFFER_SIZE}"
echo " - Message Len: ${MESSAGE_LEN}"
echo "結果將儲存於: ${RESULTS_DIR}"
if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
    echo " - C 語言綁核旗標: ${AFFINITY_COMPILE_FLAGS}"
fi
echo "----------------------------------------------------"

# --- 前置檢查 ---
if [[ $EUID -ne 0 ]]; then
echo "!! 錯誤：此腳本需要 root 權限 (sudo) 才能執行 perf。"
exit 1
fi
if [ ! -f "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" ]; then
echo "!! 錯誤：找不到 FlameGraph 的 stackcollapse-perf.pl。"
exit 1
fi

cleanup() {
echo ">> 清理暫存的執行檔與 perf 資料..."
rm -f "$THREAD_EXE_PATH" perf.data perf.data.old
# (我們不再使用 make，所以移除 make clean)
rm -f "${IPC_APP_DIR}/ipc_producer" "${IPC_APP_DIR}/ipc_consumer"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1️⃣ ITC (執行緒) 模型
# -----------------------------------------------------------------------------

echo ">> [1/2] 正在分析 ITC (執行緒) 模型..."
# [修改] 使用 AFFINITY_COMPILE_FLAGS
gcc -g "${THREAD_SRC}" -o "${THREAD_EXE_PATH}" \
${AFFINITY_COMPILE_FLAGS} \
-DNUM_PRODUCTS=${PRODUCT_COUNT} \
-DBUFFER_SIZE=${BUFFER_SIZE} \
-DMAX_MESSAGE_LEN=${MESSAGE_LEN} \
-lpthread -lrt

echo " - 使用 perf record 進行 Off-CPU 時間採樣..."
sudo perf record -e sched:sched_switch -a --call-graph dwarf -- ${THREAD_CMD_PREFIX} "${THREAD_EXE_PATH}" > /dev/null 2>&1

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
else
"${FLAMEGRAPH_DIR}/flamegraph.pl" --color=io --title="ITC Off-CPU Time Flame Graph (${AFFINITY_MODE})" \
--countname=ms "$ITC_FOLDED" > "$ITC_SVG"
echo " - ITC 火焰圖生成完成: $ITC_SVG"
fi
fi

echo "----------------------------------------------------"

# -----------------------------------------------------------------------------
# 2️⃣ IPC (行程) 模型
# -----------------------------------------------------------------------------

echo ">> [2/2] 正在分析 IPC (行程) 模型..."

# IPC (v4) 原始碼不使用 make, 必須直接使用 gcc 編譯
IPC_PRODUCER_EXE="${IPC_APP_DIR}/ipc_producer"
IPC_CONSUMER_EXE="${IPC_APP_DIR}/ipc_consumer"

# [修改] 加入 AFFINITY_COMPILE_FLAGS
gcc -g "${IPC_APP_DIR}/ipc_producer.c" -o "${IPC_PRODUCER_EXE}" \
    ${AFFINITY_COMPILE_FLAGS} \
    -DNUM_PRODUCTS=${PRODUCT_COUNT} \
    -DBUFFER_SIZE=${BUFFER_SIZE} \
    -DMAX_MESSAGE_LEN=${MESSAGE_LEN} \
    -lpthread -lrt

# [修改] 加入 AFFINITY_COMPILE_FLAGS
gcc -g "${IPC_APP_DIR}/ipc_consumer.c" -o "${IPC_CONSUMER_EXE}" \
    ${AFFINITY_COMPILE_FLAGS} \
    -DNUM_PRODUCTS=${PRODUCT_COUNT} \
    -DBUFFER_SIZE=${BUFFER_SIZE} \
    -DMAX_MESSAGE_LEN=${MESSAGE_LEN} \
    -lpthread -lrt

if [ $? -ne 0 ]; then
    echo "!! 錯誤: IPC 編譯失敗。"
    exit 1
fi


echo " - 使用 perf record 進行 Off-CPU 時間採樣 (IPC)..."
sudo perf record -e sched:sched_switch -a --call-graph dwarf -- \
    bash -c "${CONSUMER_CMD_PREFIX} ${IPC_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${IPC_PRODUCER_EXE}; wait" > /dev/null 2>&1

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
else
"${FLAMEGRAPH_DIR}/flamegraph.pl" --color=io --title="IPC Off-CPU Time Flame Graph (${AFFINITY_MODE})" \
--countname=ms "$IPC_FOLDED" > "$IPC_SVG"
echo " - IPC 火焰圖生成完成: $IPC_SVG"
fi
fi

echo "----------------------------------------------------"
echo ">> 所有分析完成！"
echo "===================================================="