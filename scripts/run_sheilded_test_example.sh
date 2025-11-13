#!/bin/bash

# ==================================
# 通用型 Cgroup v2 CPU Shield 測試載具 (v1.0)
#
# 目的: 建立一個 "CPU Shield"，隔離指定的核心，
#       並將系統上所有其他任務驅逐到其他核心，
#       以達成真正的低干擾測試環境。
#
# 用法:
# sudo ./scripts/run_with_cpu_shield.sh <quiet_cores> <script_to_run> [script_args...]
#
# 範例 (執行 validate.sh 於核心 6, 7):
# sudo ./scripts/run_with_cpu_shield.sh "6,7" ./validate.sh rt-cross-core 6 7
#
# 範例 (執行 external_example.sh 於核心 6):
# sudo ./scripts/run_with_cpu_shield.sh "6" ./scripts/performance_test_external_example.sh rt-single-core 6
# ==================================


# --- 1. 參數驗證 ---
if [ "$EUID" -ne 0 ]; then
    echo "錯誤: 此腳本需要 root 權限來設定 cpupower 和 cgroups。"
    echo "請使用: sudo $0"
    exit 1
fi

QUIET_CORES="$1"
TEST_SCRIPT_TO_RUN="$2"

if [ -z "$QUIET_CORES" ] || [ -z "$TEST_SCRIPT_TO_RUN" ]; then
    echo "錯誤: 參數不足。"
    echo "用法: $0 <quiet_cores_list> <script_to_run> [script_args...]"
    echo "範例: $0 \"6,7\" ./validate.sh rt-cross-core 6 7"
    exit 1
fi

if [ ! -f "$TEST_SCRIPT_TO_RUN" ]; then
    echo "錯誤: 找不到測試腳本: $TEST_SCRIPT_TO_RUN"
    exit 1
fi

# 取得要傳遞給子腳本的參數 (第 3 個以後的所有參數)
shift 2
SCRIPT_ARGS=("$@")

# --- 2. Cgroup 與核心計算 ---
CGROUP_ROOT="/sys/fs/cgroup"
SYSTEM_PARTITION="system_tasks"
SHIELD_PARTITION="shielded_tasks"

if [ ! -d "${CGROUP_ROOT}" ] || [ ! -f "${CGROUP_ROOT}/cgroup.procs" ]; then
    echo "錯誤: Cgroup v2 掛載點 '${CGROUP_ROOT}' 似乎不正確。"
    exit 1
fi

echo ">> 權限與 Cgroup v2 檢查通過。"

# lscpu -p=cpu: 取得所有 CPU 核心的乾淨列表 (e.g., 0\n1\n...\n7)
ALL_CPUS_LIST=$(lscpu -p=cpu | grep -v "^#" | sort -n)

# 將 QUIET_CORES (e.g., "6,7") 轉換為 grep 模式 (e.g., "^(6|7)$")
QUIET_GREP_PATTERN=$(echo "${QUIET_CORES}" | tr ',' '|')
QUIET_GREP_PATTERN="^(${QUIET_GREP_PATTERN})$"

# 使用 comm -23 從「所有核心」中「減去」安靜核心
SYSTEM_CPUS_LIST=$(comm -23 \
    <(echo "${ALL_CPUS_LIST}") \
    <(echo "${ALL_CPUS_LIST}" | grep -E "${QUIET_GREP_PATTERN}"))

# 將列表轉換為逗號分隔的字串 (e.g., "0,1,2,3,4,5")
SYSTEM_CORES_STR=$(echo "${SYSTEM_CPUS_LIST}" | tr '\n' ',' | sed 's/,$//')

if [ -z "${SYSTEM_CORES_STR}" ]; then
    echo "錯誤: 無法計算出「系統核心」列表。"
    exit 1
fi

echo ">> 核心計算完成:"
echo "   - 隔離核心 (Shielded): ${QUIET_CORES}"
echo "   - 系統核心 (System):   ${SYSTEM_CORES_STR}"
echo ">> 即將執行:"
echo "   - 腳本: ${TEST_SCRIPT_TO_RUN}"
echo "   - 參數: ${SCRIPT_ARGS[*]}"

# --- 3. 設定清理函數 (trap) ---
function cleanup {
    echo ""
    echo "===================================================="
    echo ">> 正在執行清理..."

    echo ">> 1. 正在將所有任務移回 'root' cgroup..."
    if [ -d "${CGROUP_ROOT}/${SYSTEM_PARTITION}" ]; then
        # 將 system 分區中的所有 PID 移回 root
        cat "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cgroup.procs" | while read pid; do
            echo $pid > "${CGROUP_ROOT}/cgroup.procs" 2>/dev/null
        done
    fi
    
    echo ">> 2. 正在移除 cgroup 分區..."
    rmdir "${CGROUP_ROOT}/${SHIELD_PARTITION}" 2>/dev/null
    rmdir "${CGROUP_ROOT}/${SYSTEM_PARTITION}" 2>/dev/null

    echo ">> 3. 正在恢復 CPU 頻率 (governor)..."
    if command -v cpupower &> /dev/null; then
        # 嘗試恢復為 ondemand，如果失敗 (例如在 VM 中)，嘗試 powersave
        cpupower frequency-set -g ondemand 2>/dev/null || cpupower frequency-set -g powersave 2>/dev/null
    fi
    
    echo ">> 清理完成。"
    echo "===================================================="
}
# 確保在任何情況下 (正常退出、Ctrl+C、錯誤) 都能執行清理
trap cleanup EXIT SIGINT SIGTERM

# --- 4. 執行環境設定 ---
echo "===================================================="
echo ">> 正在設定 'Real-Time' (Cgroup v2) 測試環境..."

if ! command -v cpupower &> /dev/null; then
    echo "錯誤: 'cpupower' 未安裝。"
    exit 1
fi

echo ">> 1. 鎖定 CPU 頻率 (governor) 為 performance..."
cpupower frequency-set -g performance
if [ $? -ne 0 ]; then
    echo "錯誤: 設定 cpupower 失敗。"
    exit 1
fi

echo ">> 2. 正在建立 'shield' 和 'system' cgroup 分區..."
mkdir -p "${CGROUP_ROOT}/${SHIELD_PARTITION}"
mkdir -p "${CGROUP_ROOT}/${SYSTEM_PARTITION}"

# --- 3. 分配核心 ---
NODE_MEMS=$(cat /sys/devices/system/node/online_nodes 2>/dev/null || echo 0)
echo ">> 3. 分配核心與記憶體節點 (MEMs: ${NODE_MEMS})..."
echo "${QUIET_CORES}" > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cpuset.cpus"
echo "${NODE_MEMS}" > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cpuset.mems"

echo "${SYSTEM_CORES_STR}" > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cpuset.cpus"
echo "${NODE_MEMS}" > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cpuset.mems"

# --- 4. 遷移所有現有任務 ---
echo ">> 4. 正在遷移系統上所有任務到 'system' 分區 (可能短暫停頓)..."
cat "${CGROUP_ROOT}/cgroup.procs" | while read pid; do
    echo $pid > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cgroup.procs" 2>/dev/null
done
echo ">> 遷移完成。核心 ${QUIET_CORES} 現在是安靜的。"
echo "===================================================="

# --- 5. 執行您的測試腳本 ---
echo ">> 正在啟動測試 (將移入 'shield' cgroup)..."

# 將 *我們自己* (目前的 bash 腳本) 移入 'shield'
# 任何它呼叫的子進程 (即 ${TEST_SCRIPT_TO_RUN}) 都會繼承這個 cgroup
echo $$ > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cgroup.procs"
if [ $? -ne 0 ]; then
    echo "錯誤: 無法將此腳本 (PID: $$) 移入 shield cgroup！"
    exit 1
fi

# 【核心改動】
# 執行傳入的腳本，並傳遞所有後續參數
"${TEST_SCRIPT_TO_RUN}" "${SCRIPT_ARGS[@]}"


echo "----------------------------------------------------"
echo ">> 測試腳本執行完畢。"

# (腳本將在這裡結束，'trap' 會自動觸發 cleanup 函數)
exit 0