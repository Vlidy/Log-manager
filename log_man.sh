#!/bin/bash

set -u

LOG_DIR="${LOG_DIR:-/LOGS}"
FILL_THRESHOLD="${FILL_THRESHOLD:-90}"
SERVICES=(
    auth_service
    data_process_service
    system_event_handler_service
)

if [ ! -d "$LOG_DIR" ]; then
    echo "ОШИБКА: каталог $LOG_DIR не существует"
    exit 1
fi

if [[ "${TEST_MODE:-0}" != "1" ]]; then
    if ! mountpoint -q "$LOG_DIR"; then
        echo "ОШИБКА: $LOG_DIR не является точкой монтирования"
        echo "Проверьте подключение диска и /etc/fstab"
        exit 1
    fi

    expected_uuid="6def0fe4-8f35-4067-8932-e10beac4cf45"
    actual_uuid=$(findmnt -n -o UUID --target "$LOG_DIR")

    if [ "$actual_uuid" != "$expected_uuid" ]; then
        echo "ОШИБКА: в $LOG_DIR смонтирован неожиданный раздел"
        exit 1
    fi
fi

if [[ "${TEST_MODE:-0}" == "1" ]]; then
    total_bytes="${TEST_TOTAL_BYTES:-1000000}"
    used_percent="${TEST_USED_PERCENT:-95}"
else
    total_bytes=$(df -B1 --output=size "$LOG_DIR" | awk 'NR==2 {print $1}')
    used_percent=$(df -P "$LOG_DIR" | awk 'END {
        gsub(/%/, "", $5)
        print $5
    }')
fi

if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] ||
   ! [[ "$used_percent" =~ ^[0-9]+$ ]] ||
   [ "$total_bytes" -le 0 ] ||
   [ "$used_percent" -gt 100 ]; then
    echo "ОШИБКА: не удалось определить заполнение раздела"
    exit 1
fi

service_limit=$((total_bytes / 3))

echo "Заполнение: ${used_percent}%"

if [ "$used_percent" -le "$FILL_THRESHOLD" ]; then
    echo "Архивация не требуется"
    exit 0
fi

ARCHIVE_DIR="$LOG_DIR/.archives"

if ! mkdir -p "$ARCHIVE_DIR"; then
    echo "ОШИБКА: не удалось создать каталог архивов"
    exit 1
fi

for service in "${SERVICES[@]}"; do
    service_dir="$LOG_DIR/$service"

    if [ ! -d "$service_dir" ]; then
        continue
    fi

    service_size=$(du -sb "$service_dir" | cut -f1)

    if [ "$service_size" -le "$service_limit" ]; then
        continue
    fi

    mapfile -t log_names < <(
        find "$service_dir" -maxdepth 1 -type f \
            -name "${service}_????_??_??_*.log" \
            -printf '%f\n' | sort
    )

    selected=()
    selected_bytes=0

    for log_name in "${log_names[@]}"; do
        if [[ ! "$log_name" =~ ^${service}_([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]+)\.log$ ]]; then
            continue
        fi

        year="${BASH_REMATCH[1]}"
        month="${BASH_REMATCH[2]}"
        day="${BASH_REMATCH[3]}"

        if ! date -d "$year-$month-$day" >/dev/null 2>&1; then
            continue
        fi

        log_path="$service_dir/$log_name"
        file_size=$(stat -c '%s' -- "$log_path") || continue

        selected+=("$log_name")
        selected_bytes=$((selected_bytes + file_size))

        if [ $((service_size - selected_bytes)) -le "$service_limit" ]; then
            break
        fi
    done

    if [ "${#selected[@]}" -eq 0 ]; then
        continue
    fi

    archive="$ARCHIVE_DIR/${service}_$(date +%Y%m%d_%H%M%S)_$$.tar.gz"

    if ! tar -czf "$archive" -C "$service_dir" -- "${selected[@]}"; then
        rm -f -- "$archive"
        continue
    fi

    if ! gzip -t "$archive" ||
       ! tar -tzf "$archive" >/dev/null; then
        rm -f -- "$archive"
        continue
    fi

    archive_count=$(tar -tzf "$archive" | wc -l)

    if [ "$archive_count" -ne "${#selected[@]}" ]; then
        rm -f -- "$archive"
        continue
    fi

    paths=()
    for log_name in "${selected[@]}"; do
        paths+=("$service_dir/$log_name")
    done

    if rm -- "${paths[@]}"; then
        echo "Создан архив: $archive"
    else
        echo "ОШИБКА: не удалось удалить все исходные логи"
    fi
done

echo "Обработка завершена"
df -h "$LOG_DIR"