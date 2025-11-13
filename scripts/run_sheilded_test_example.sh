#!/bin/bash

# ==================================
# Real-Time 效能測試 (使用 Cgroup v2 CPU Shielding)
# 
# 目的: 建立一個 "CPU Shield"，將核心 6, 7 完全隔離出來，
#       並將系統上所有其他任務 (包括核心執行緒) 驅逐到
#       其他核心 (例如 0-5)，以達成真正的低干擾測試環境。
# ==================================


# --- 設定 ---
# 選擇您要隔離的、安靜的核心 (例如: 6, 7)
QUIET_CORE_A=6
QUIET_CORE_B=7
QUIET_CORES="${QUIET_CORE_A},${QUIET_CORE_B}" # "6,7"

# 您主要的測試腳本名稱
TEST_SCRIPT_NAME="scripts/performance_test_internal.sh"

# Cgroup v2 的掛載點
CGROUP_ROOT="/sys/fs/cgroup"

# 存放我們建立的 cgroup (方便清理)
SYSTEM_PARTITION="system_tasks"
SHIELD_PARTITION="shielded_tasks"

# --- 1. 權限與 Cgroup 檢查 ---
if [ "$EUID" -ne 0 ]; then
    echo "錯誤: 此腳本需要 root 權限來設定 cpupower 和 cgroups。"
    echo "請使用: sudo $0"
    exit 1
fi
if [ ! -d "${CGROUP_ROOT}" ]; then
    echo "錯誤: Cgroup v2 掛載點 '${CGROUP_ROOT}' 不存在。"
    echo "       您的核心可能不支援 Cgroup v2 或未正確掛載。"
    exit 1
fi
if [ ! -f "${CGROUP_ROOT}/cgroup.procs" ]; then
    echo "錯誤: '${CGROUP_ROOT}/cgroup.procs' 不存在。"
    echo "       這似乎不是 Cgroup v2 的掛載點 (缺少 'cpuset' 控制器？)"
    exit 1
fi

echo ">> 權限與 Cgroup v2 檢查通過。"

# --- 2. 計算核心 ---
# lscpu -p=cpu: 取得所有 CPU 核心的乾淨列表 (e.g., 0\n1\n...\n7)
# grep -v "^#": 過濾掉註解
# sort -n: 排序
ALL_CPUS_LIST=$(lscpu -p=cpu | grep -v "^#" | sort -n)

# 將 QUIET_CORES (e.g., "6,7") 轉換為 grep 模式 (e.g., "^(6|7)$")
QUIET_GREP_PATTERN=$(echo "${QUIET_CORES}" | tr ',' '|')
QUIET_GREP_PATTERN="^(${QUIET_GREP_PATTERN})$"

# 使用 comm -23 從「所有核心」中「減去」安靜核心
# <(...) 是一種 bash 語法，稱為 "Process Substitution"
SYSTEM_CPUS_LIST=$(comm -23 \
    <(echo "${ALL_CPUS_LIST}") \
    <(echo "${ALL_CPUS_LIST}" | grep -E "${QUIET_GREP_PATTERN}"))

# 將列表轉換為逗號分隔的字串 (e.g., "0,1,2,3,4,5")
SYSTEM_CORES_STR=$(echo "${SYSTEM_CPUS_LIST}" | tr '\n' ',' | sed 's/,$//')

if [ -z "${SYSTEM_CORES_STR}" ]; then
    echo "錯誤: 無法計算出「系統核心」列表。"
    echo "       請檢查 QUIET_CORES (${QUIET_CORES}) 是否正確。"
    exit 1
fi
if [ -z "${QUIET_CORES}" ]; then
    echo "錯誤: QUIET_CORES 未設定。"
    exit 1
fi


echo ">> 核心計算完成:"
echo "   - 安靜核心 (Shielded): ${QUIET_CORES}"
echo "   - 系統核心 (System):   ${SYSTEM_CORES_STR}"

# --- 3. 設定清理函數 (trap) ---
function cleanup {
    echo ""
    echo "===================================================="
    echo ">> 正在執行清理..."

    echo ">> 1. 正在將所有任務移回 'root' cgroup..."
    # 這是最安全的作法：將 system 分區中的所有 PID 移回 root
    # 2>/dev/null 忽略 "no such process" 或 "permission denied" (針對核心執行緒)
    #
    # 警告: 如果 system_tasks 不存在 (例如腳本在 setup 中途失敗)，這會出錯
    if [ -d "${CGROUP_ROOT}/${SYSTEM_PARTITION}" ]; then
        cat "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cgroup.procs" | while read pid; do
            echo $pid > "${CGROUP_ROOT}/cgroup.procs" 2>/dev/null
        done
    fi
    
    echo ">> 2. 正在移除 cgroup 分區..."
    rmdir "${CGROUP_ROOT}/${SHIELD_PARTITION}" 2>/dev/null
    rmdir "${CGROUP_ROOT}/${SYSTEM_PARTITION}" 2>/dev/null

    # echo ">> 3. 正在恢復 CPU 頻率 (governor)..."
    # if command -v cpupower &> /dev/null; then
    #     # 嘗試恢復為 ondemand，如果失敗 (例如在 VM 中)，嘗試 powersave
    #     cpupower frequency-set -g ondemand 2>/dev/null || cpupower frequency-set -g powersave 2>/dev/null
    # fi
    
    echo ">> 清理完成。"
    echo "===================================================="
}
# 確保在任何情況下 (正常退出、Ctrl+C、錯誤) 都能執行清理
trap cleanup EXIT SIGINT SIGTERM

# --- 4. 執行環境設定 ---
echo "===================================================="
echo ">> 正在設定 'Real-Time' (Cgroup v2) 測試環境..."

# 檢查 cpupower
if ! command -v cpupower &> /dev/null; then
    echo "錯誤: 'cpupower' 未安裝。請先安裝 'cpupowerutils' (Debian/Ubuntu) 或 'kernel-tools' (RHEL/CentOS)。"
    exit 1
fi

echo ">> 1. 鎖定 CPU 頻率 (governor) 為 performance..."
cpupower frequency-set -g performance
if [ $? -ne 0 ]; then
    echo "錯誤: 設定 cpupower 失敗。請檢查權限或硬體支援。"
    exit 1
fi

# --- 2. 建立 CPU 分區 (Partitions) ---
echo ">> 2. 正在建立 'shield' 和 'system' cgroup 分區..."
mkdir -p "${CGROUP_ROOT}/${SHIELD_PARTITION}"
mkdir -p "${CGROUP_ROOT}/${SYSTEM_PARTITION}"

# --- 3. 分配核心 ---
# 為了避免 NUMA 節點問題，我們也設定記憶體節點 (mems)
# (我們允許所有節點，讓核心自行處理 NUMA)
NODE_MEMS=$(cat /sys/devices/system/node/online_nodes 2>/dev/null || echo 0)

echo ">> 3. 分配核心與記憶體節點 (MEMs: ${NODE_MEMS})..."
echo "${QUIET_CORES}" > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cpuset.cpus"
echo "${NODE_MEMS}" > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cpuset.mems"

echo "${SYSTEM_CORES_STR}" > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cpuset.cpus"
echo "${NODE_MEMS}" > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cpuset.mems"

# --- 4. 遷移所有現有任務 (CPU Shielding 的關鍵) ---
echo ">> 4. 正在遷移系統上所有任務到 'system' 分區..."
# 警告: 這可能需要幾秒鐘，並且您 SSH 連線可能會短暫停頓
cat "${CGROUP_ROOT}/cgroup.procs" | while read pid; do
    echo $pid > "${CGROUP_ROOT}/${SYSTEM_PARTITION}/cgroup.procs" 2>/dev/null
done
echo ">> 遷移完成。核心 ${QUIET_CORES} 現在是安靜的。"
echo "===================================================="

# --- 5. 執行您的測試腳本 ---
echo ">> 正在啟動 'Real-Time' 測試 (模式: rt-cross-core)..."
echo ">> 測試將在 'shield' cgroup 中執行..."

# 將 *我們自己* (目前的 bash 腳本) 移入 'shield'
# 任何它呼叫的子進程 (即 ${TEST_SCRIPT_NAME}) 都會繼承這個 cgroup
echo $$ > "${CGROUP_ROOT}/${SHIELD_PARTITION}/cgroup.procs"
if [ $? -ne 0 ]; then
    echo "錯誤: 無法將此腳本 (PID: $$) 移入 shield cgroup！"
    exit 1
fi

# 執行您的測試 (它現在位於 'shield' 中)
#
# 提醒：您的 "performance_test_internal.sh" 內部腳本 *必須* #       仍然使用 "chrt -f 99 taskset -c ..." 
#       來確保即時優先權和核心綁定！
#
${TEST_SCRIPT_NAME} rt-cross-core ${QUIET_CORE_A} ${QUIET_CORE_B}

# (如果需要，您可以在這裡呼叫其他測試模式)
# echo ">> 正在啟動 'Real-Time' 測試 (模式: rt-single-core)..."
# ${TEST_SCRIPT_NAME} rt-single-core ${QUIET_CORE_A} ${QUIET_CORE_B}


echo "----------------------------------------------------"
echo ">> 測試腳本執行完畢。"

# (腳本將在這裡結束，'trap' 會自動觸發 cleanup 函數)
exit 0