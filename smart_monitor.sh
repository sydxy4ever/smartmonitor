#!/bin/bash

# --- 配置区 ---
DATE_SUFFIX=$(date +%Y-%m-%d)
DISKS=("/dev/sda")
LOG_DIR="/volume1/docker/logs"
STATE_FILE="${LOG_DIR}/last_smart_values.db"
REPORT_FILE="${LOG_DIR}/smart_report_${DATE_SUFFIX}.log"

mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

echo "=== 硬盘深度巡检预警报告 ${DATE_SUFFIX} ===" > "$REPORT_FILE"

# --- 执行区 ---
for DISK in "${DISKS[@]}"; do
    echo -e "\n[检查设备]: $DISK" >> "$REPORT_FILE"
    
    SMART_DATA=$(/usr/bin/smartctl -d sat -A "$DISK" 2>/dev/null)
    if [ -z "$SMART_DATA" ]; then
        echo "错误: 无法获取 $DISK 的数据。" >> "$REPORT_FILE"
        continue
    fi

    # 提取监控指标
    ID5=$(echo "$SMART_DATA" | grep "Reallocated_Sector_Ct" | awk '{print $10}')
    ID197=$(echo "$SMART_DATA" | grep "Current_Pending_Sector" | awk '{print $10}')
    ID199=$(echo "$SMART_DATA" | grep "UDMA_CRC_Error_Count" | awk '{print $10}')
    ID188_RAW=$(echo "$SMART_DATA" | grep "Command_Timeout" | awk '{print $10}')
    ID04=$(echo "$SMART_DATA" | grep "Start_Stop_Count" | awk '{print $10}')
    ID09=$(echo "$SMART_DATA" | grep "Power_On_Hours" | awk '{print $10}')
    ID07=$(echo "$SMART_DATA" | grep "Seek_Error_Rate" | awk '{print $10}')
    IDC6=$(echo "$SMART_DATA" | grep "Offline_Uncorrectable" | awk '{print $10}')
    TEMP=$(echo "$SMART_DATA" | grep "Temperature_Celsius" | awk '{print $10}')

    # --- ID 188 详细拆解 ---
    ID188_INFO="0"
    if [ -n "$ID188_RAW" ] && [ "$ID188_RAW" -gt 0 ]; then
        HEX188=$(printf "%012X" "$ID188_RAW")
        SERIOUS=$((16#${HEX188:0:4}))
        NORMAL=$((16#${HEX188:4:4}))
        ATTEMPTS=$((16#${HEX188:8:4}))
        ID188_INFO="[严重:$SERIOUS | 普通:$NORMAL | 尝试:$ATTEMPTS]"
    fi

    # --- 增量对比与报警逻辑 ---
    LAST_LINE=$(grep "^${DISK}:" "$STATE_FILE")
    DIFF_INFO=""
    if [ -n "$LAST_LINE" ]; then
        # 对应数据库字段: DISK:ID5:ID197:ID199:ID188:ID04:ID09:ID07:IDC6
        IFS=':' read -r DUMMY L5 L197 L199 L188 L04 L09 L07 LC6 <<< "$LAST_LINE"
        
        # 1. 危险报警 (数值增加即报警)
        ALERT=""
        [[ "$ID5" -gt "${L5:-0}" ]] && ALERT+="[坏道ID5增加] "
        [[ "$ID197" -gt "${L197:-0}" ]] && ALERT+="[待处理ID197增加] "
        [[ "$ID199" -gt "${L199:-0}" ]] && ALERT+="[CRC错误ID199增加] "
        [[ "$ID188_RAW" -gt "${L188:-0}" ]] && ALERT+="[超时ID188增加] "
        [[ "$IDC6" -gt "${LC6:-0}" ]] && ALERT+="[不治之症C6增加] "
        [[ "$ID07" -gt "${L07:-0}" ]] && ALERT+="[寻道错误ID07增加] "

        if [ -n "$ALERT" ]; then
            echo -e "![!!! 危险预警 !!!]: $ALERT" >> "$REPORT_FILE"
        fi

        # 2. 状态增量 (记录变化量)
        D04=$((ID04 - L04))
        D09=$((ID09 - L09))
        DIFF_INFO="(较上次检查: 启动停止+$D04次, 通电时间+$D09小时)"
    fi

    # 更新数据库文件
    grep -v "^${DISK}:" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null
    echo "$DISK:${ID5:-0}:${ID197:-0}:${ID199:-0}:${ID188_RAW:-0}:${ID04:-0}:${ID09:-0}:${ID07:-0}:${IDC6:-0}" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"

    # --- 格式化输出报告 ---
    echo "通电时长: 累计 ${ID09:-0} 小时 | 累计启动 ${ID04:-0} 次" >> "$REPORT_FILE"
    echo "增量记录: $DIFF_INFO" >> "$REPORT_FILE"
    echo "物理指标: ID5(坏道)=${ID5:-0} | C6(无法校正)=${IDC6:-0} | ID197(待处理)=${ID197:-0} | Temp=${TEMP:-0}°C" >> "$REPORT_FILE"
    echo "通讯性能: ID199(CRC)=${ID199:-0} | ID07(寻道错误)=${ID07:-0}" >> "$REPORT_FILE"
    echo "超时详情: ID188=$ID188_INFO" >> "$REPORT_FILE"
    echo "--------------------------------" >> "$REPORT_FILE"
done

cat "$REPORT_FILE"