#!/bin/bash

set -Eeuo pipefail

MAIN_SCRIPT="$HOME/linux-lab/log_man.sh"

if [[ ! -f "$MAIN_SCRIPT" ]]; then
    echo "FAIL: не найден основной скрипт $MAIN_SCRIPT"
    exit 1
fi

#врем среда для тестов.
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/log-man-tests.XXXXXX")

# удаление временной среды
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# меин
run_main() {
    local test_dir="$1"
    local fill_percent="$2"
    local output_file="$3"

    if ! TEST_MODE=1 \
         TEST_TOTAL_BYTES=1000000 \
         TEST_USED_PERCENT="$fill_percent" \
         LOG_DIR="$test_dir" \
         bash "$MAIN_SCRIPT" >"$output_file" 2>&1; then
        cat "$output_file" >&2
        fail "Основной скрипт завершился с ошибкой"
    fi
}

echo "=== Тест 1: заполнение 95%, разные размеры папок ==="

CASE1="$TEST_ROOT/high-fill"

mkdir -p \
    "$CASE1/auth_service" \
    "$CASE1/data_process_service" \
    "$CASE1/system_event_handler_service"

# В auth_service создаём два файла по 200кб
AUTH_OLD="auth_service_2026_01_01_1767225600.log"
AUTH_NEW="auth_service_2026_01_02_1767312000.log"

truncate -s 200000 "$CASE1/auth_service/$AUTH_OLD"
truncate -s 200000 "$CASE1/auth_service/$AUTH_NEW"

# В data_process_service создаём один файл размером 400кб
DATA_LOG="data_process_service_2026_01_01_1767225600.log"
truncate -s 400000 "$CASE1/data_process_service/$DATA_LOG"

# В system_event_handler_service создаём файл размером 100 КБ.
SYSTEM_LOG="system_event_handler_service_2026_01_01_1767225600.log"
truncate -s 100000 "$CASE1/system_event_handler_service/$SYSTEM_LOG"

#при заполнении 95%
run_main "$CASE1" 95 "$TEST_ROOT/scenario1.out"
cat "$TEST_ROOT/scenario1.out"

AUTH_ARCHIVE=$(find "$CASE1/.archives" -maxdepth 1 \
    -type f -name 'auth_service_*.tar.gz' -print -quit)

DATA_ARCHIVE=$(find "$CASE1/.archives" -maxdepth 1 \
    -type f -name 'data_process_service_*.tar.gz' -print -quit)

# Проверяем архив auth_service.
[[ -n "$AUTH_ARCHIVE" ]] || fail "Для auth_service архив не создан"
tar -tzf "$AUTH_ARCHIVE" >/dev/null || fail "Архив auth_service повреждён"

tar -tzf "$AUTH_ARCHIVE" | grep -Fxq "$AUTH_OLD" ||
    fail "В архиве auth_service нет ожидаемого старого лога"

[[ ! -e "$CASE1/auth_service/$AUTH_OLD" ]] ||
    fail "Исходный файл auth_service не удалён"

[[ -f "$CASE1/auth_service/$AUTH_NEW" ]] ||
    fail "Лог auth_service, который должен остаться, отсутствует"

pass "auth_service: старый лог архивирован, второй лог сохранён"

# Проверяем архив data_process_service.
[[ -n "$DATA_ARCHIVE" ]] ||
    fail "Для data_process_service архив не создан"

tar -tzf "$DATA_ARCHIVE" >/dev/null ||
    fail "Архив data_process_service повреждён"

tar -tzf "$DATA_ARCHIVE" | grep -Fxq "$DATA_LOG" ||
    fail "В архиве отсутствует ожидаемый лог data_process_service"

[[ ! -e "$CASE1/data_process_service/$DATA_LOG" ]] ||
    fail "Исходный лог data_process_service не удалён"

pass "data_process_service: лог архивирован и исходник удалён"

# проверем что не архивир system_event_handler_service
[[ -f "$CASE1/system_event_handler_service/$SYSTEM_LOG" ]] ||
    fail "Лог system_event_handler_service должен был сохраниться"

SYSTEM_ARCHIVE=$(find "$CASE1/.archives" -maxdepth 1 \
    -type f -name 'system_event_handler_service_*.tar.gz' -print -quit)

[[ -z "$SYSTEM_ARCHIVE" ]] ||
    fail "Неожиданно создан архив system_event_handler_service"

pass "system_event_handler_service: лог сохранён без архивации"

echo
echo "Тест 2: заполнение ниже порога 90%"

CASE2="$TEST_ROOT/low-fill"

mkdir -p \
    "$CASE2/auth_service" \
    "$CASE2/data_process_service" \
    "$CASE2/system_event_handler_service"

LOW_LOG="auth_service_2026_01_01_1767225600.log"
truncate -s 400000 "$CASE2/auth_service/$LOW_LOG"

# Даже большая папка не должна архивироваться при заполнении 50%
run_main "$CASE2" 50 "$TEST_ROOT/scenario2.out"
cat "$TEST_ROOT/scenario2.out"

[[ -f "$CASE2/auth_service/$LOW_LOG" ]] ||
    fail "При заполнении 50% исходный лог был потерян"

ARCHIVE_COUNT=$(find "$CASE2" -type f -name '*.tar.gz' | wc -l)

[[ "$ARCHIVE_COUNT" -eq 0 ]] ||
    fail "При заполнении 50% неожиданно созданы архивы"

pass "При заполнении 50% архивация не выполнялась"

echo
echo "Тест 3: папка не превышает лимит в одну треть"

CASE3="$TEST_ROOT/under-service-limit"

mkdir -p \
    "$CASE3/auth_service" \
    "$CASE3/data_process_service" \
    "$CASE3/system_event_handler_service"

SMALL_LOG="auth_service_2026_01_01_1767225600.log"
truncate -s 200000 "$CASE3/auth_service/$SMALL_LOG"

# Заполнение раздела 95% но папка auth_service меньше 1/3 от 1 МБ.
run_main "$CASE3" 95 "$TEST_ROOT/scenario3.out"
cat "$TEST_ROOT/scenario3.out"

[[ -f "$CASE3/auth_service/$SMALL_LOG" ]] ||
    fail "Лог ниже лимита был неожиданно удалён"

ARCHIVE_COUNT=$(find "$CASE3" -type f -name '*.tar.gz' | wc -l)

[[ "$ARCHIVE_COUNT" -eq 0 ]] ||
    fail "Для папки ниже лимита неожиданно создан архив"

pass "Папка ниже лимита: архивация не выполнялась"
echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"
