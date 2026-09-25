#!/bin/bash

# Kit load engine — consumer root: harness/tools/load-changed-files/../../..
# Agent-slot CRLF wrapper — в корневом load-changed-files.sh потребителя.

# ==============================================================================
# Скрипт для загрузки измененных файлов конфигурации 1С из git
# ==============================================================================
#
# ОПИСАНИЕ:
#   Загружает в конфигурацию 1С файлы из git (предпочтительно) или из явного списка
#   (--list-file, фолбэк). По умолчанию — git: working-tree (staged/unstaged/untracked)
#   плюс committed-изменения с маркера последней загрузки (merge из других веток)
#   в conf/ и cfe.xml/, без удалённых.
#   --list-file — только если нужных файлов нет среди git-изменений (dirty worktree,
#   resync без diff, изоляция перечня). Полностью заменяет git-discovery, не union.
#
# ПЕРВИЧНАЯ НАСТРОЙКА:
#   1. cp .env.example .env
#   2. Настроить пути в .env файле
#   3. Запустить: ./load-changed-files.sh
#
# ИМЯ БАЗЫ В СТАРТЕРЕ 1С (IBName):
# Конфигуратор из стартера в командной строке даёт /IBName"слот", не /F"каталог".
# Скрипт матчит каталог ИБ и имена слотов из ibases.v8i (Connect=File= / Srvr=+Ref=).
# Переименование слота в стартере не ломает автозакрытие. Явный .v8i: IBASES_V8I.
#
# НАСТРОЙКИ ПРОЕКТА:
#   Все настройки скриптов проекта хранятся в .env файле.
#   Для получения шаблона: cp .env.example .env
#   Затем отредактируйте .env файл с своими путями.
#
# ИСПОЛЬЗОВАНИЕ:
#   ./load-changed-files.sh [ОПЦИИ]
#
# ПАРАМЕТРЫ:
#   -c, --config-path PATH      Путь к папке conf (по умолчанию: conf)
#   -e, --extensions-path PATH  Путь к папке расширений (по умолчанию: cfe.xml)
#   -g, --git-path PATH         Путь к git репозиторию (по умолчанию: .)
#   -i, --ib-connection CONN    Строка подключения к ИБ (по умолчанию: /F"C:/base/proj")
#   -d, --designer-path PATH    Путь к 1cv8.exe
#   -n, --no-close              Запретить автозакрытие конфигуратора
#       --allow-close-designer  Явно разрешить автозакрытие конфигуратора
#       --reopen-designer       Открыть конфигуратор после загрузки
#   -H, --human-mode            Старый режим: закрыть и переоткрыть конфигуратор
#   -C, --open-client           Быстрый тест: закрыть конфигуратор/клиент, загрузить,
#                               обновить БД (-U) и открыть тонкий клиент 1С (1cv8c.exe)
#       --client-keys KEYS      Дополнительные ключи запуска тонкого клиента (строка целиком),
#                               напр. --client-keys '/C"ЗапуститьОбновлениеИнформационнойБазы"'
#       --refresh-variants      После загрузки актуализировать варианты отчётов: клиент с ключом
#                               БСП ЗапуститьОбновлениеИнформационнойБазы (нужен, если добавлен
#                               или изменён settingsVariant — иначе варианта нет в списке на форме)
#   -u, --auto-unsupport        Автоматически снимать с поддержки загружаемые объекты
#   -U, --update-db             Обновить конфигурацию базы данных после загрузки
#       --list-file PATH        Фолбэк: явный список (заменяет git); PATH=- для stdin
#       --no-extensions         Только conf, без cfe.xml (если агент не менял расширения —
#                               иначе git подтянет чужие правки cfe.xml и загрузка упадёт)
#       --reset-marker          Сбросить маркер HEAD последней загрузки (rebase/force-push/resync)
#                               При чистом дереве + merge НЕ заливает файлы (см. infer merge-marker).
#   -F, --full-resync           Полная загрузка conf/ целиком (без partial) + reset-marker
#                               + авто-UpdateDBCfg; лечит «Неверный путь к данным»/
#                               «Неизвестный объект» после merge/rebase, когда ИБ отстала
#                               от диска. Без --list-file.
#       --force-partial         Не отменять partial, даже если в списке Configuration.xml
#                               после merge (иначе скрипт шлёт на -F).
#       --force-sessions        При ошибке /UpdateDBCfg из-за HTTP-клиентов повторить его
#                               с -Dynamic- -SessionTerminate force (сеансы завершаются
#                               принудительно). Экв. UPDATE_DB_FORCE_SESSIONS=true.
#       --no-force-sessions     Запретить принудительное завершение сеансов (экв. env=false)
#       --verbose               Подробный вывод (по умолчанию — краткий для агентов)
#   -h, --help                  Показать эту справку
#
# ФАЙЛЫ НАСТРОЕК:
#   README.md                 Общая документация проекта
#   .env.example              Пример файла настроек (скопируйте в .env)
#   .env                      Файл с настройками (читается автоматически, игнорируется git)
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
#   CONFIG_PATH               Путь к папке conf
#   EXTENSIONS_PATH           Путь к папке расширений (по умолчанию: cfe.xml)
#   GIT_PATH                  Путь к git репозиторию
#   IB_CONNECTION             Строка подключения к ИБ
#   DESIGNER_PATH             Путь к 1cv8.exe
#   AUTO_CLOSE_DESIGNER       Автоматически закрывать конфигуратор (true/false, по умолчанию: false)
#   REOPEN_DESIGNER_AFTER_LOAD Открывать конфигуратор после загрузки (true/false, по умолчанию: false)
#   AUTO_UNSUPPORT_OBJECTS    Автоматически снимать с поддержки загружаемые объекты (true/false, по умолчанию: false)
#   PARENT_CONFIG_PY          Путь к parent_config.py для preflight поддержки
#                             (по умолчанию: scripts/parent_config.py потребителя, иначе канон в kit)
#   UPDATE_DB                 Обновить конфигурацию базы данных после загрузки (true/false, по умолчанию: false)
#   UPDATE_DB_FORCE_SESSIONS  true (по умолчанию) — если /UpdateDBCfg упал из-за HTTP-клиентов
#                             (вторую публикацию ИБ держит другая служба Apache), повторить
#                             обновление с -Dynamic- -SessionTerminate force. Пользователи
#                             отключаются принудительно, в лог пишется WARN. На prod — false.
#   APACHE_SERVICE_NAME       Имя службы Apache (например, Apache2.4). Если задано и UPDATE_DB=true —
#                             служба останавливается перед /UpdateDBCfg и запускается после.
#                             Освобождает lock файловой ИБ и пересоздаёт worker httpd.exe с wsap24.dll
#                             (см. docs/ai/load-config-to-dev.md). Пусто = Apache не трогаем.
#   SKIP_EXTENSIONS           true — только conf, без расширений (то же, что --no-extensions)
#   RESET_LOAD_MARKER         true — то же, что --reset-marker
#   FULL_RESYNC               true — то же, что --full-resync
#   FORCE_PARTIAL             true — то же, что --force-partial
#   LOAD_HIDE_FILES           «;»-список путей относительно корня репо: на время
#                             LoadConfigFromFiles переименовать в *.hidden-for-load
#                             (типовая битая форма УНФ при -F / Configuration.xml)
#   LOAD_VERBOSE              true — то же, что --verbose
#   LOG_FILE_LIST_THRESHOLD   Порог поименного вывода файлов в -H/-C/--verbose (по умолчанию: 100)
#
# ПРИМЕРЫ:
#   ./load-changed-files.sh                           # Использует настройки из .env
#   ./load-changed-files.sh -c "conf" -g "."          # Переопределение через параметры
#   export IB_CONNECTION="/S server/base" && ./load-changed-files.sh  # Через переменные окружения
#   DESIGNER_PATH="/path/to/1cv8.exe" ./load-changed-files.sh         # Переопределение пути
#   ./load-changed-files.sh -n                        # Запретить автозакрытие конфигуратора
#   ./load-changed-files.sh --allow-close-designer    # Явно разрешить автозакрытие
#   ./load-changed-files.sh --reopen-designer         # Открыть конфигуратор после загрузки
#   ./load-changed-files.sh -H                        # Старый режим (закрыть + переоткрыть)
#   ./load-changed-files.sh -C                        # Загрузить, обновить БД, открыть клиент
#   ./load-changed-files.sh -u                        # Снять с поддержки и загрузить автоматически
#   ./load-changed-files.sh -U                        # Загрузить и обновить базу данных
#   ./load-changed-files.sh -U --list-file .tmp/agent-load.txt  # Фолбэк, если нет в git
#   ./load-changed-files.sh -U --no-extensions                  # Только conf, без расширений
#
# АЛГОРИТМ РАБОТЫ:
#   1. Список файлов: git (working-tree + committed с маркера) ИЛИ --list-file (фолбэк)
#   2. Создание списка измененных файлов основной конфигурации в UTF-8 файле
#   3. Запуск 1С:Предприятие с командой 1cv8.exe CONFIG /LoadConfigFromFiles -listfile
#      для основной конфигурации (partial) и отдельные вызовы /LoadConfigFromFiles
#      -Extension для каждого изменённого расширения (целиком)
#
# ==============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[94m'
NC='\033[0m' # No Color

# Краткий вывод по умолчанию (агенты); --verbose или -H/-C — полный лог
VERBOSE="${LOAD_VERBOSE:-false}"
for _preload_arg in "$@"; do
    case "$_preload_arg" in
        --verbose) VERBOSE=true ;;
        -H|--human-mode|-C|--open-client) VERBOSE=true ;;
    esac
done

# Функция для логирования
log() {
    local level="$1"
    local message="$2"
    if [[ "$level" == "INFO" && "$VERBOSE" != "true" ]]; then
        return 0
    fi
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "ERROR")
            echo -e "${RED}[$timestamp] ОШИБКА: $message${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] ПРЕДУПРЕЖДЕНИЕ: $message${NC}"
            ;;
        "INFO")
            echo "[$timestamp] ИНФО: $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] УСПЕХ: $message${NC}"
            ;;
        *)
            echo "[$timestamp] $message"
            ;;
    esac
}

# Краткая строка в тихом режиме (без списка файлов и таймингов этапов)
log_quiet() {
    [[ "$VERBOSE" == "true" ]] && return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ponytail: при большом partial-списке поименный log в -H/-C/--verbose тормозит терминал
LOG_FILE_LIST_THRESHOLD="${LOG_FILE_LIST_THRESHOLD:-100}"

log_file_list() {
    local header="$1"
    local list_file="$2"
    local detail_hint="${3:-}"
    local count line

    [[ -f "$list_file" && -s "$list_file" ]] || return 0
    count=$(wc -l < "$list_file" | tr -d ' ')
    log "INFO" "$header"
    if [[ "$count" -gt "$LOG_FILE_LIST_THRESHOLD" ]]; then
        log "INFO" "  $count элементов (порог $LOG_FILE_LIST_THRESHOLD, без поименного вывода${detail_hint:+; $detail_hint})"
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        log "INFO" "  $line"
    done < "$list_file"
}

# Тайминг этапов: wall-clock через date +%s (не $SECONDS — в Git Bash/MSYS не тикает во время долгих git).
TIMING_SCRIPT_START=""
TIMING_LAST_MARK=""
TIMING_ACTIVE=false

timing_now() {
    date +%s
}

timing_format_duration() {
    local total_sec="$1"
    if [[ "$total_sec" -ge 3600 ]]; then
        printf '%dh %02dm %02ds' $((total_sec / 3600)) $(((total_sec % 3600) / 60)) $((total_sec % 60))
    elif [[ "$total_sec" -ge 60 ]]; then
        printf '%dm %02ds' $((total_sec / 60)) $((total_sec % 60))
    else
        printf '%ds' "$total_sec"
    fi
}

timing_reset() {
    TIMING_SCRIPT_START=$(timing_now)
    TIMING_LAST_MARK=$TIMING_SCRIPT_START
    TIMING_ACTIVE=true
}

timing_mark() {
    local label="$1"
    [[ "$VERBOSE" != "true" ]] && return 0
    if [[ "$TIMING_ACTIVE" != "true" ]]; then
        timing_reset
    fi
    local now delta_sec total_sec
    now=$(timing_now)
    delta_sec=$((now - TIMING_LAST_MARK))
    total_sec=$((now - TIMING_SCRIPT_START))
    [[ "$delta_sec" -lt 0 ]] && delta_sec=0
    [[ "$total_sec" -lt 0 ]] && total_sec=0
    log "INFO" "[время] ${label}: +$(timing_format_duration "$delta_sec") (с начала: $(timing_format_duration "$total_sec"))"
    TIMING_LAST_MARK=$now
}

timing_summary() {
    local extra="${1:-}"
    if [[ "$TIMING_ACTIVE" != "true" ]]; then
        return 0
    fi
    local now total_sec
    now=$(timing_now)
    total_sec=$((now - TIMING_SCRIPT_START))
    [[ "$total_sec" -lt 0 ]] && total_sec=0
    local duration
    duration=$(timing_format_duration "$total_sec")
    if [[ "$VERBOSE" != "true" ]]; then
        if [[ -n "$extra" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Итого: ${duration} | $extra"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Итого: ${duration}"
        fi
        return 0
    fi
    if [[ -n "$extra" ]]; then
        log "INFO" "[время] Итого: ${duration} | $extra"
    else
        log "INFO" "[время] Итого: ${duration}"
    fi
}


# OS-абстракция (generic: tools/os/ у потребителя)
_KIT_LOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONSUMER_ROOT="$(cd "${_KIT_LOAD_DIR}/../../.." && pwd)"
# shellcheck source=tools/load-project-env.sh
source "${_CONSUMER_ROOT}/tools/load-project-env.sh"
load_project_env "${_CONSUMER_ROOT}"
# Слот: .env в worktree (/work), не в каталоге kit
for _env_root in "${WORKTREE:-}" "/work" "$(pwd)"; do
    [[ -z "${_env_root}" || ! -f "${_env_root}/.env" ]] && continue
    _env_root="$(cd "${_env_root}" && pwd)"
    [[ "${_env_root}" == "${_CONSUMER_ROOT}" ]] && break
    load_project_env "${_env_root}"
    break
done
# shellcheck source=tools/os/detect.sh
source "${_CONSUMER_ROOT}/tools/os/detect.sh"
source "${_CONSUMER_ROOT}/tools/os/paths.sh"
source "${_CONSUMER_ROOT}/tools/os/apache.sh"
source "${_CONSUMER_ROOT}/tools/os/process-1c.sh"

run_1c_command() {
    if [[ "${PROJECT_OS}" == "linux" ]]; then
        local cmd="$1"
        # SSH-сессии не наследуют Docker ENV → при POSIX locale конфигуратор
        # не находит XML-файлы с кириллическими путями (fopen falls back to ASCII).
        # BSL загружается через lookup по имени объекта — ему locale не важен.
        export LANG="${LANG:-ru_RU.UTF-8}"
        export LC_ALL="${LC_ALL:-ru_RU.UTF-8}"
        if [[ "${USE_XVFB:-}" != "false" ]] && command -v xvfb-run >/dev/null 2>&1; then
            xvfb-run -a bash -c "$cmd"
        else
            eval "$cmd"
        fi
    else
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" eval "$@"
    fi
}

# ==============================================================================
# Движок ibcmd (альтернатива конфигуратору 1cv8.exe CONFIG)
# ==============================================================================
# ibcmd работает с ИБ напрямую (без конфигуратора). Соответствия:
#   /LoadConfigFromFiles -partial -listFile  → infobase config import files --base-dir --partial <файлы>
#   /LoadConfigFromFiles -Extension          → infobase config import --extension <дир>
#   /UpdateDBCfg                             → infobase config apply [--extension] --force
# Подключение к файловой ИБ: --db-path (из /F"..."); серверной — IBCMD_DBMS/IBCMD_DB_*.

# Путь к ibcmd.exe по умолчанию — рядом с DESIGNER_PATH (bin платформы)
resolve_ibcmd_default() {
    local dir
    dir=$(dirname "$(win_to_unix_path "$DESIGNER_PATH")")
    if [[ "${PROJECT_OS}" == "linux" ]]; then
        echo "$dir/ibcmd"
    else
        echo "$dir/ibcmd.exe"
    fi
}

# Аргументы подключения к ИБ для ibcmd (--db-path для файловой, --dbms/... для серверной)
build_ibcmd_db_args() {
    IBCMD_DB_ARGS=""
    local conn="$IB_CONNECTION" p
    if [[ "$conn" =~ ^[[:space:]]*/[Ff] ]]; then
        p=$(echo "$conn" | sed -E 's|^[[:space:]]*/[Ff][[:space:]]*||' | tr -d '"')
        if [[ "${PROJECT_OS}" == "linux" ]]; then
            p=$(win_to_unix_path "$p")
        else
            p=$(unix_to_win_path "$(win_to_unix_path "$p")")
        fi
        IBCMD_DB_ARGS="--db-path=\"$p\""
    elif [[ "$conn" =~ ^[[:space:]]*/[Ss] ]]; then
        if [[ -z "${IBCMD_DBMS:-}" || -z "${IBCMD_DB_SERVER:-}" || -z "${IBCMD_DB_NAME:-}" ]]; then
            log "ERROR" "Движок ibcmd с серверной ИБ ($conn) требует IBCMD_DBMS, IBCMD_DB_SERVER, IBCMD_DB_NAME в .env"
            return 1
        fi
        IBCMD_DB_ARGS="--dbms=$IBCMD_DBMS --db-server=\"$IBCMD_DB_SERVER\" --db-name=\"$IBCMD_DB_NAME\""
        [[ -n "${IBCMD_DB_USER:-}" ]] && IBCMD_DB_ARGS+=" --db-user=\"$IBCMD_DB_USER\""
        [[ -n "${IBCMD_DB_PWD:-}" ]] && IBCMD_DB_ARGS+=" --db-pwd=\"$IBCMD_DB_PWD\""
    else
        log "ERROR" "Не удалось разобрать IB_CONNECTION для ibcmd: $conn"
        return 1
    fi
    return 0
}

# Аутентификация пользователя ИБ для ibcmd (-u/-P), источники как у ib_config_auth_suffix
build_ibcmd_auth() {
    local u p
    u="${AGENT_IB_USER:-${IB_USER:-${WEB_TEST_USER:-}}}"
    p="${AGENT_IB_PASSWORD:-${IB_PASSWORD:-${WEB_TEST_PASSWORD:-}}}"
    IBCMD_AUTH=""
    if [[ -n "$u" ]]; then
        IBCMD_AUTH="-u \"$u\""
        [[ -n "$p" ]] && IBCMD_AUTH+=" -P \"$p\""
    fi
}

# Запуск ibcmd с перенаправлением вывода в LOAD_LOG_FILE (у ibcmd нет /Out)
ibcmd_run() {
    local label="$1"; shift
    local cmd="\"$IBCMD_CMD\" $* > \"$LOAD_LOG_FILE\" 2>&1"
    log "INFO" "Выполнение команды (ibcmd, $label): $cmd"
    : > "$LOAD_LOG_FILE"
    run_1c_command "$cmd"
}

# Частичный импорт conf: список полных путей файлов подаётся ibcmd через stdin
# (документированный способ: type fileList.lst | ibcmd infobase config import files --base-dir ...).
# Без лимита длины командной строки.
ibcmd_import_conf() {
    local base_dir_cmd="$1"
    local base_dir_unix="$2"   # unix-путь base-dir для сборки полных путей в списке
    local no_check="" listfile rel full
    [[ "$IBCMD_NO_CHECK" == "true" ]] && no_check="--no-check"

    listfile="$repo_path/.tmp/ibcmd-filelist.lst"
    # ibcmd читает список путей из stdin как Windows ANSI (CP1251), не UTF-8 —
    # кириллицу в путях конвертируем UTF-8 → CP1251 (см. docs/ai/load-config-to-dev.md)
    local listfile_src="${listfile}.utf8"
    : > "$listfile_src"
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ -z "$rel" ]] && continue
        full="$base_dir_unix/$rel"
        if [[ "${PROJECT_OS}" == "linux" ]]; then
            printf '%s\n' "$full" >> "$listfile_src"
        else
            printf '%s\n' "$(unix_to_win_path "$full")" >> "$listfile_src"
        fi
    done < temp_changed_files.txt
    if [[ "${PROJECT_OS}" == "linux" ]]; then
        mv "$listfile_src" "$listfile"
    else
        iconv -f UTF-8 -t CP1251 "$listfile_src" > "$listfile" && rm -f "$listfile_src"
    fi

    local listfile_cmd
    if [[ "${PROJECT_OS}" == "linux" ]]; then
        listfile_cmd="$listfile"
    else
        listfile_cmd=$(unix_to_win_path "$listfile")
    fi

    local cmd="cat \"$listfile_cmd\" | \"$IBCMD_CMD\" infobase config import files $IBCMD_DB_ARGS $IBCMD_AUTH $no_check --base-dir=\"$base_dir_cmd\" --partial > \"$LOAD_LOG_FILE\" 2>&1"
    log "INFO" "Выполнение команды (ibcmd, импорт conf по списку через stdin): $cmd"
    : > "$LOAD_LOG_FILE"
    run_1c_command "$cmd"
    return $?
}

# /N и опционально /P для пакетного CONFIG в слоте (см. lib.sh agent-container).
ib_config_auth_suffix() {
    local u p
    u="${AGENT_IB_USER:-${IB_USER:-${WEB_TEST_USER:-}}}"
    p="${AGENT_IB_PASSWORD:-${IB_PASSWORD:-${WEB_TEST_PASSWORD:-}}}"
    IB_CONFIG_AUTH=""
    if [[ -n "$u" ]]; then
        IB_CONFIG_AUTH="/N${u}"
        [[ -n "$p" ]] && IB_CONFIG_AUTH+=" /P${p}"
    fi
}

# Linux agent-slot: /F без литеральных кавычек в argv.
normalize_ib_connection_linux() {
    if [[ "${PROJECT_OS}" != "linux" ]]; then
        return 0
    fi
    IB_CONNECTION="${IB_CONNECTION//\"/}"
    IB_CONNECTION="${IB_CONNECTION//\\}"
}

# Функция для проверки наличия команды
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR" "Команда '$cmd' не найдена. Установите $cmd и добавьте в PATH"
        exit 1
    fi
}

# Читает лог 1С (`/Out`) и печатает текст в UTF-8.
# designer пишет UTF-16 LE|BE с BOM (или UTF-8); ibcmd при перенаправлении — CP866/CP1251.
read_1c_log_text() {
    local log_file="$1" head_hex has_nul
    [[ -f "$log_file" && -s "$log_file" ]] || return 0
    head_hex=$(head -c 3 "$log_file" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$head_hex" in
        fffe*) iconv -f UTF-16LE -t UTF-8 "$log_file" 2>/dev/null; return 0 ;;
        feff*) iconv -f UTF-16BE -t UTF-8 "$log_file" 2>/dev/null; return 0 ;;
        efbbbf) tail -c +4 "$log_file"; return 0 ;;
    esac
    # BOM-less UTF-16 (реже): NUL-байты в начале файла
    has_nul=$(head -c 4096 "$log_file" 2>/dev/null | tr -cd '\000' | wc -c | tr -d ' ')
    if [[ "${has_nul:-0}" -gt 0 ]]; then
        iconv -f UTF-16LE -t UTF-8 "$log_file" 2>/dev/null \
            || iconv -f UTF-16BE -t UTF-8 "$log_file" 2>/dev/null
        return 0
    fi
    if iconv -f UTF-8 -t UTF-8 "$log_file" >/dev/null 2>&1; then
        cat "$log_file"
    elif iconv -f CP1251 -t UTF-8 "$log_file" >/dev/null 2>&1; then
        iconv -f CP1251 -t UTF-8 "$log_file"
    elif iconv -f CP866 -t UTF-8 "$log_file" >/dev/null 2>&1; then
        iconv -f CP866 -t UTF-8 "$log_file"
    else
        cat "$log_file"
    fi
}

# true, если лог UpdateDB содержит признак активных HTTP-клиентов.
# Пробуем все кодировки: UTF-16LE-декодирование произвольных байт «успешно»,
# но осмысленную фразу даст только верная кодировка.
log_has_http_clients() {
    local log_file="$1" enc text
    [[ -f "$log_file" && -s "$log_file" ]] || return 1
    for enc in UTF-8 UTF-16LE UTF-16BE CP1251 CP866; do
        text=$(iconv -f "$enc" -t UTF-8 "$log_file" 2>/dev/null | tr -d '\000') || continue
        [[ -n "$text" ]] || continue
        if grep -qiE 'работающие по HTTP|по HTTP|HTTP[ -]?клиент|HTTP clients' <<< "$text"; then
            return 0
        fi
    done
    return 1
}

# Вывод содержимого лога 1С (`/Out`) после ошибки.
dump_load_log() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        log "WARN" "Файл лога 1С не найден: $log_file"
        return 0
    fi

    if [[ ! -s "$log_file" ]]; then
        log "WARN" "Файл лога 1С пуст: $log_file"
        return 0
    fi

    local log_text
    log_text=$(read_1c_log_text "$log_file")

    if [[ -z "$log_text" ]]; then
        log "WARN" "Лог 1С не удалось прочитать: $log_file"
        return 0
    fi

    log "ERROR" "Содержимое лога 1С ($log_file):"
    echo "$log_text" | while IFS= read -r log_line; do
        # Пропускаем пустые строки в выводе
        [[ -z "${log_line//[[:space:]]/}" ]] && continue
        log "ERROR" "  $log_line"
    done
}

# Анализ лога 1С после неудачной partial-загрузки: классифицирует ошибки,
# отличает блокирующие (ИБ отстаёт от диска / нет метаданных владельца) от шума
# (предупреждения по справке типовой УНФ) и выдаёт диагноз с рекомендациями.
# ponytail: эвристика по строкам лога 1С; потолок — не различает «объект новый»
# vs «структура изменилась», для обоих даёт одинаковый совет. Апгрейд —
# сверка списка с метаданными в ИБ через MCP dev_dt.
diagnose_load_failure() {
    local log_file="$1"
    [[ -f "$log_file" && -s "$log_file" ]] || return 0

    local log_text=""
    if iconv -f UTF-8 -t UTF-8 "$log_file" >/dev/null 2>&1; then
        log_text=$(sed '1s/^\xEF\xBB\xBF//' "$log_file")
    elif iconv -f UTF-16LE -t UTF-8 "$log_file" >/dev/null 2>&1; then
        log_text=$(iconv -f UTF-16LE -t UTF-8 "$log_file" | sed '1s/^\xEF\xBB\xBF//')
    elif iconv -f UTF-16BE -t UTF-8 "$log_file" >/dev/null 2>&1; then
        log_text=$(iconv -f UTF-16BE -t UTF-8 "$log_file" | sed '1s/^\xEF\xBB\xBF//')
    elif iconv -f CP1251 -t UTF-8 "$log_file" >/dev/null 2>&1; then
        log_text=$(iconv -f CP1251 -t UTF-8 "$log_file")
    else
        log_text=$(cat "$log_file")
    fi
    [[ -z "$log_text" ]] && return 0

    local err_datalink=0 err_unknown=0 err_cmd=0 warn_help=0
    while IFS= read -r line; do
        case "$line" in
            *"Неверный путь к данным"*)                err_datalink=$((err_datalink+1)) ;;
            *"Неизвестный объект метаданных"*)         err_unknown=$((err_unknown+1)) ;;
            *"Неверное имя команды элемента формы"*)   err_cmd=$((err_cmd+1)) ;;
            *"Возможно неверная ссылка"*"внутри справки"*) warn_help=$((warn_help+1)) ;;
        esac
    done <<< "$log_text"

    local blocking=$((err_datalink + err_unknown + err_cmd))
    [[ $blocking -eq 0 && $warn_help -eq 0 ]] && return 0

    log "ERROR" "── Диагноз ──────────────────────────────────────────────────"
    [[ $err_unknown   -gt 0 ]] && log "ERROR" "  • Неизвестный объект метаданных: $err_unknown — объект есть в Configuration.xml, но отсутствует в ИБ и/или в partial-списке."
    [[ $err_datalink  -gt 0 ]] && log "ERROR" "  • Неверный путь к данным: $err_datalink — формы ссылаются на реквизиты/ТЧ, которых нет в ИБ."
    [[ $err_cmd       -gt 0 ]] && log "ERROR" "  • Неверное имя команды элемента формы: $err_cmd — команды ТЧ, которых нет в ИБ."
    [[ $warn_help     -gt 0 ]] && log "WARN"  "  • Предупреждения по справке (битые ссылки в ru.html): $warn_help — шум типовой УНФ, не блокирующие."

    if [[ $blocking -gt 0 ]]; then
        log "ERROR" "Причина: partial load не смог разрешить ссылки — ИБ отстаёт от диска,"
        log "ERROR" "либо в partial-сете нет метаданных объектов-владельцев форм."
        log "ERROR" "Часто возникает после merge/rebase/force-push или ручной правки в конфигураторе."
        log "ERROR" "Рекомендации:"
        log "ERROR" "  1. Полная загрузка (не --reset-marker при чистом дереве — это только UpdateDB):"
        log "ERROR" "       ./load-changed-files.sh -F -U"
        log "ERROR" "     Битую типовую форму прячет LOAD_HIDE_FILES (см. .env.example)."
        log "ERROR" "  2. Если объект новый и ИБ почти синхронна — корневой XML в --list-file"
        log "ERROR" "       (напр. CommonForms/Имя.xml), не только форму; без Configuration.xml,"
        log "ERROR" "       если можно обойтись."
        log "ERROR" "  3. После merge marker..HEAD с новыми объектами partial+Configuration.xml"
        log "ERROR" "       почти всегда проигрывает -F (десятки минут, затем те же ошибки)."
    elif [[ $warn_help -gt 0 ]]; then
        log "WARN" "Блокирующих ошибок нет — только предупреждения по справке типовой УНФ."
        log "WARN" "Если 1С всё равно вернула ненулевой код, проверьте полный лог выше."
    fi
    log "ERROR" "──────────────────────────────────────────────────────────────"
}

# Управление Apache и процессами 1С — tools/os/apache.sh, tools/os/process-1c.sh

# Windows: помимо APACHE_SERVICE_NAME ИБ могут публиковать другие службы Apache/httpd
# (вторая публикация держит HTTP-сеансы и мешает эксклюзивному /UpdateDBCfg).
# apache.sh потребителя управляет только одной службой — предупреждаем заранее.
warn_other_apache_services() {
    [[ "${PROJECT_OS}" == "windows" ]] || return 0
    [[ -n "${APACHE_SERVICE_NAME:-}" ]] || return 0
    command -v powershell.exe >/dev/null 2>&1 || return 0
    local ps names
    ps="Get-Service -ErrorAction SilentlyContinue | Where-Object { \$_.Name -ne '$APACHE_SERVICE_NAME' -and \$_.Status -eq 'Running' -and (\$_.Name -like 'Apache24*' -or \$_.Name -like '*httpd*') } | Select-Object -ExpandProperty Name"
    names=$(powershell.exe -NoProfile -Command "$ps" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d')
    [[ -n "$names" ]] || return 0
    log "WARN" "Кроме $APACHE_SERVICE_NAME запущены другие службы Apache/httpd:"
    while IFS= read -r n; do
        [[ -n "$n" ]] && log "WARN" "  • $n"
    done <<< "$names"
    log "WARN" "Они тоже публикуют ИБ и держат HTTP-сеансы — /UpdateDBCfg может упасть"
    log "WARN" "на «обнаружены клиенты, работающие по HTTP» (см. UPDATE_DB_FORCE_SESSIONS)."
}

# Запуск Python с fallback на py -3
run_python() {
    if command -v python >/dev/null 2>&1; then
        python "$@"
    elif command -v python3 >/dev/null 2>&1; then
        python3 "$@"
    elif command -v py >/dev/null 2>&1; then
        py -3 "$@"
    else
        log "ERROR" "Не найден Python (python, python3 или py -3). Установите Python и повторите попытку"
        exit 1
    fi
}

# Список изменённых файлов для -listFile: пишется в .tmp/ потребителя и снимается
# на любом выходе (успех/ошибка/Ctrl+C), чтобы не оставлять незаигноренный
# артефакт в корне репозитория.
_LIST_OUTPUT_FILE=""
cleanup_changed_files_list() {
    if [[ -n "${_LIST_OUTPUT_FILE:-}" ]]; then
        rm -f -- "$_LIST_OUTPUT_FILE"
        _LIST_OUTPUT_FILE=""
    fi
}

# Рабочие temp-файлы движка в корне рабочего дерева (temp_changed_files.txt и др.)
# снимаются на любом выходе, чтобы не оставлять untracked-мусор в git status
# потребителя при ошибке/Ctrl+C (раньше чистились только на успешном пути).
cleanup_temp_files() {
    local d
    for d in "$PWD" "${repo_path:-$PWD}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        rm -f -- \
            "$d"/temp_changed_files.txt "$d"/temp_changed_files.txt.* \
            "$d"/temp_changed_extensions.txt "$d"/temp_changed_extensions.txt.* \
            "$d"/temp_forced_form_metas.txt "$d"/temp_forced_form_metas.txt.* \
            "$d"/temp_rewritten_form_modules.txt \
            "$d"/temp_cache_update_list.txt "$d"/temp_cache_update_list.txt.* \
            "$d"/temp_full_resync_cache_seed.txt "$d"/temp_full_resync_cache_seed.txt.* \
            2>/dev/null || true
    done
}

# Функция для извлечения имени конечного каталога базы из строки IB_CONNECTION.
# Работает для файловых баз (/F"путь") и серверных (/S сервер\база).
# Пример: /F"C:\bases\org_proj.dev.dt" → org_proj.dev.dt
extract_base_dirname() {
    local ib_conn="$1"
    # Убираем кавычки и ключевое слово /F или /S
    local path
    path=$(echo "$ib_conn" | tr -d '"' | sed -E 's|^[[:space:]]*/[FfSs][[:space:]]*||')
    # Берём последний компонент пути (работает с \ и /)
    echo "$path" | sed -E 's|.*[/\\]([^/\\]+)[/\\]?$|\1|' | xargs
}

# close_1c_* / find_1c_* — tools/os/process-1c.sh

# Функция для преобразования Windows пути в Unix путь
win_to_unix_path() {
    local path="$1"
    echo "$path" | sed 's|\\|/|g' | sed 's/^"\(.*\)"$/\1/'
}

# Функция для преобразования Unix пути в Windows путь
unix_to_win_path() {
    local path="$1"
    echo "$path" | sed 's|/|\\|g'
}

# win_to_unix_path / unix_to_win_path — дубли tools/os/paths.sh для обратной совместимости

# Безопасный фрагмент имени файла кэша (кириллица в base_id → _)
sanitize_cache_token() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

# SHA-256 содержимого файла (hex, одна строка)
file_content_hash() {
    sha256sum "$1" | awk '{print $1}'
}

# Разбор строки sha256sum: «hash  path» или «hash *path» (не-ASCII и спецсимволы)
_parse_sha256sum_line() {
    local line="$1"
    _PARSE_SHA256_HASH="${line%%[[:space:]]*}"
    local rest="${line#"${_PARSE_SHA256_HASH}"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    if [[ "$rest" == \** ]]; then
        _PARSE_SHA256_PATH="${rest:1}"
    else
        _PARSE_SHA256_PATH="$rest"
    fi
}

# Пакетный SHA-256: paths_file (abs, по строке) → out_file (rel<TAB>hash)
# ponytail: чанки из-за ARG_MAX; один sha256sum на чанк вместо fork на каждый файл
batch_sha256_conf_files() {
    local paths_file="$1"
    local config_dir_abs="$2"
    local out_file="$3"
    local batch_size="${BATCH_HASH_SIZE:-48}"
    local -a batch=()
    local file_path hash_line

    config_dir_abs="${config_dir_abs%/}"

    _flush_sha256_batch() {
        [[ ${#batch[@]} -eq 0 ]] && return 0
        while IFS= read -r hash_line; do
            [[ -z "$hash_line" ]] && continue
            _parse_sha256sum_line "$hash_line"
            printf '%s\t%s\n' "${_PARSE_SHA256_PATH#"$config_dir_abs"/}" "$_PARSE_SHA256_HASH"
        done < <(sha256sum "${batch[@]}" 2>/dev/null) >> "$out_file"
        batch=()
    }

    : > "$out_file"
    while IFS= read -r file_path || [[ -n "$file_path" ]]; do
        [[ -z "$file_path" ]] && continue
        batch+=("$file_path")
        if [[ ${#batch[@]} -ge $batch_size ]]; then
            _flush_sha256_batch
        fi
    done < "$paths_file"
    _flush_sha256_batch
}

# Манифест кэша хешей файлов conf (относительный_путь<TAB>sha256)
conf_files_cache_manifest_path() {
    local repo_root="$1"
    local config_dir_abs="$2"
    local base_id config_slug
    base_id=$(sanitize_cache_token "$(extract_base_dirname "$IB_CONNECTION")")
    config_slug=$(sanitize_cache_token "$(basename "$config_dir_abs")")
    echo "$repo_root/.tmp/load-cache/files-${base_id}-${config_slug}.manifest"
}

# Маркер HEAD последней успешной загрузки committed-изменений (per ИБ)
loaded_marker_path() {
    local repo_root="$1"
    local base_id
    base_id=$(sanitize_cache_token "$(extract_base_dirname "$IB_CONNECTION")")
    echo "$repo_root/.tmp/load-cache/loaded-head-${base_id}.sha"
}

read_loaded_marker() {
    local marker_file="$1"
    [[ -f "$marker_file" ]] || return 0
    local sha
    sha=$(tr -d '[:space:]' < "$marker_file")
    [[ -n "$sha" ]] || return 0
    if git rev-parse --verify "$sha^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$sha"
        return 0
    fi
    log "WARN" "Маркер $sha не найден в репо (rebase/reset?) — игнорирую"
    return 0
}

write_loaded_marker() {
    local marker_file="$1"
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null) || return 0
    [[ -n "$head_sha" ]] || return 0
    mkdir -p "$(dirname "$marker_file")"
    printf '%s\n' "$head_sha" > "$marker_file"
    log "INFO" "Маркер загрузки обновлён: $head_sha"
}

# HEAD — merge-коммит (есть второй родитель).
head_is_merge() {
    git rev-parse --verify --quiet HEAD^2 >/dev/null 2>&1
}

# Предупреждение, если в marker..HEAD есть merge-коммиты: после merge ИБ могла
# получить большой объём изменений, partial load рискован. ponytail: дёшево по
# rev-list --merges; потолок — не отличает «merge затронул conf» от «нет»,
# возможен ложный warn. Апгрейд — фильтр по pathspec conf/.
warn_if_merge_in_range() {
    local marker_sha="$1"
    [[ -n "$marker_sha" ]] || return 0
    local merge_count
    merge_count=$(git_nq rev-list --merges --count "$marker_sha..HEAD" 2>/dev/null)
    [[ -z "$merge_count" || "$merge_count" -eq 0 ]] && return 0
    log "WARN" "В диапазоне marker..HEAD найдено merge-коммитов: $merge_count."
    log "WARN" "После merge ИБ могла отстать от диска — partial с Configuration.xml"
    log "WARN" "часто идёт десятки минут и падает («Неизвестный объект» / «Неверный путь»)."
    log "WARN" "Канон при отставании ИБ: ./load-changed-files.sh -F -U"
    log "WARN" "Не используйте --reset-marker на чистом дереве: это 0 файлов + только UpdateDB."
}

# Нет маркера + HEAD merge → граница committed-diff = первый родитель (наша ветка до merge).
# Иначе git-discovery видит только working-tree и при чистом дереве делает ложный UpdateDB.
# Пишет RESOLVED_LOAD_MARKER (не echo: log WARN идёт в stdout).
resolve_loaded_marker() {
    local marker_file marker_sha parent
    marker_file=$(loaded_marker_path "$repo_path")
    marker_sha=$(read_loaded_marker "$marker_file")
    if [[ -n "$marker_sha" ]]; then
        RESOLVED_LOAD_MARKER="$marker_sha"
        return 0
    fi
    if head_is_merge; then
        parent=$(git rev-parse HEAD^1)
        log "WARN" "Маркер загрузки отсутствует, HEAD — merge."
        log "WARN" "Беру первый родитель ${parent:0:8} как границу committed-diff (дельта merge)."
        log "WARN" "Не пишите в маркер текущий HEAD до успешной загрузки файлов."
        RESOLVED_LOAD_MARKER="$parent"
        return 0
    fi
    RESOLVED_LOAD_MARKER=""
    return 0
}

# Индекс знает файл, на диске его нет (NTFS: delete lowercase-дубля стирает канонический путь).
# Без restore discover пропускает путь (-f) → пустой список → ложный UpdateDB.
restore_missing_worktree_from_index() {
    local prefix="$1"
    local tmp n
    [[ -n "$prefix" ]] || return 0
    tmp=$(mktemp) || return 1
    git_nq ls-files -d -- "$prefix" > "$tmp" 2>/dev/null || true
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 0
    fi
    n=$(wc -l < "$tmp" | tr -d ' ')
    log "WARN" "Worktree: $n путей под $prefix есть в индексе и отсутствуют на диске"
    log "WARN" "(часто NTFS case-fold после merge). Восстанавливаю из индекса."
    if ! git_nq restore --worktree --pathspec-from-file="$tmp"; then
        log "ERROR" "git restore --worktree не удался для $prefix — загрузка отменена."
        log "ERROR" "Иначе эти файлы не попадут в listFile, а -U сделает вид, что ИБ синхронна."
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

HIDDEN_LOAD_FILES=()

restore_load_hide_files() {
    local f
    for f in "${HIDDEN_LOAD_FILES[@]+"${HIDDEN_LOAD_FILES[@]}"}"; do
        if [[ -f "${f}.hidden-for-load" ]]; then
            mv -f "${f}.hidden-for-load" "$f"
            log "INFO" "LOAD_HIDE_FILES: возвращён $f"
        fi
    done
    HIDDEN_LOAD_FILES=()
}

# На время LoadConfigFromFiles спрятать файлы из LOAD_HIDE_FILES («;» / перевод строки).
apply_load_hide_files() {
    local spec item rel abs
    spec="${LOAD_HIDE_FILES:-}"
    [[ -n "$spec" ]] || return 0
    HIDDEN_LOAD_FILES=()
    local IFS=$';\n'
    for item in $spec; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -z "$item" ]] && continue
        rel="${item#./}"
        abs="$repo_path/$rel"
        if [[ ! -f "$abs" ]]; then
            log "WARN" "LOAD_HIDE_FILES: нет файла $rel — пропуск"
            continue
        fi
        mv "$abs" "${abs}.hidden-for-load"
        HIDDEN_LOAD_FILES+=("$abs")
        log "INFO" "LOAD_HIDE_FILES: спрятан $rel → *.hidden-for-load"
    done
    if [[ ${#HIDDEN_LOAD_FILES[@]} -gt 0 ]]; then
        _LOAD_HIDE_PREV_TRAP=$(trap -p EXIT 2>/dev/null || true)
        trap 'restore_load_hide_files; cleanup_temp_files; cleanup_changed_files_list; eval "${_LOAD_HIDE_PREV_TRAP:-true}"' EXIT
    fi
}

# Partial + Configuration.xml после merge: designer валидирует весь dump (десятки минут)
# и типично падает. Канон — -F, не начинать doomed partial. Обход: --force-partial.
abort_costly_merge_partial() {
    local marker_sha="$1"
    local list_file="temp_changed_files.txt"
    [[ "$FULL_RESYNC" == "true" ]] && return 0
    [[ "$FORCE_PARTIAL" == "true" ]] && return 0
    [[ -n "$LIST_FILE" ]] && return 0
    [[ -s "$list_file" ]] || return 0
    grep -qx 'Configuration.xml' "$list_file" || return 0
    local merge_here=false
    if head_is_merge; then
        merge_here=true
    elif [[ -n "$marker_sha" ]]; then
        local mc
        mc=$(git_nq rev-list --merges --count "$marker_sha..HEAD" 2>/dev/null || echo 0)
        [[ "${mc:-0}" -gt 0 ]] && merge_here=true
    fi
    [[ "$merge_here" == "true" ]] || return 0
    if [[ -z "$marker_sha" ]]; then
        marker_sha=$(git rev-parse HEAD^1)
    fi
    local n added
    n=$(wc -l < "$list_file" | tr -d ' ')
    added=$(git_nq diff --name-only --diff-filter=A "$marker_sha"..HEAD -- \
        "$CONFIG_GIT_PREFIX/Catalogs/" "$CONFIG_GIT_PREFIX/Documents/" \
        "$CONFIG_GIT_PREFIX/DataProcessors/" "$CONFIG_GIT_PREFIX/Reports/" \
        "$CONFIG_GIT_PREFIX/CommonModules/" "$CONFIG_GIT_PREFIX/CommonForms/" \
        "$CONFIG_GIT_PREFIX/InformationRegisters/" "$CONFIG_GIT_PREFIX/Enums/" \
        2>/dev/null | grep -E '/[^/]+\.xml$' | grep -v '/Ext/' | wc -l | tr -d ' ')
    added="${added:-0}"
    local min_files="${LOAD_MERGE_PARTIAL_MAX_FILES:-20}"
    if [[ "$added" -ge 1 || "$n" -ge "$min_files" ]]; then
        log "ERROR" "Partial load после merge включает Configuration.xml ($n файлов conf,"
        log "ERROR" "новых корневых XML объектов: $added)."
        log "ERROR" "Designer тогда обходит весь dump: десятки минут и почти наверняка"
        log "ERROR" "«Неизвестный объект метаданных» / «Неверный путь к данным»."
        log "ERROR" "Канон: ./load-changed-files.sh -F -U"
        log "ERROR" "  (LOAD_HIDE_FILES — спрятать битую типовую форму на время -F)."
        log "ERROR" "Если ИБ уже синхронна и нужен именно partial: --force-partial"
        return 1
    fi
    log "WARN" "В partial-списке Configuration.xml после merge ($n файлов)."
    log "WARN" "Если загрузка пойдёт долго/упадёт — ./load-changed-files.sh -F -U"
    return 0
}

# Merge тронул conf/cfe, список пуст (не кэш) — не делать вид, что UpdateDB = синхронизация.
abort_empty_load_after_merge() {
    local marker_sha="$1"
    [[ "$FULL_RESYNC" == "true" ]] && return 0
    [[ -n "$LIST_FILE" ]] && return 0
    local base="${marker_sha}"
    if [[ -z "$base" ]] && head_is_merge; then
        base=$(git rev-parse HEAD^1)
    fi
    [[ -n "$base" ]] || return 0
    head_is_merge || return 0
    local changed
    changed=$(git_nq diff --name-only --diff-filter=ACMR "$base"..HEAD -- \
        "$CONFIG_GIT_PREFIX" "$EXTENSIONS_GIT_PREFIX" 2>/dev/null || true)
    [[ -n "$changed" ]] || return 0
    log "ERROR" "HEAD — merge, в ${base:0:8}..HEAD есть изменения $CONFIG_PATH/ или $EXTENSIONS_PATH/,"
    log "ERROR" "но список загрузки пуст. -U сделал бы только UpdateDB — ИБ осталась бы старой."
    log "ERROR" "Частые причины: маркер уже записан на merge-HEAD до загрузки файлов;"
    log "ERROR" "файлы есть в git, но нет на диске (NTFS case-fold)."
    log "ERROR" "Канон: ./load-changed-files.sh -F -U"
    log "ERROR" "Или сдвиньте маркер на первый родитель: git rev-parse HEAD^1 > .tmp/load-cache/loaded-head-<ИБ>.sha"
    return 1
}

# Кириллица в путях conf/: при core.quotepath=true git diff оборачивает пути в кавычки+octal,
# case "$file" in conf/*) в discover_changed_files_from_git не матчит.
git_nq() {
    git -c core.quotepath=false "$@"
}

# true, если marker..HEAD содержит хотя бы один путь
committed_range_has_changes() {
    local marker_sha="$1"
    [[ -n "$marker_sha" ]] || return 1
    git_nq diff --name-only --diff-filter=ACMR "$marker_sha..HEAD" 2>/dev/null | grep -q .
}

# Git-пути: committed (marker..HEAD) + working tree
git_all_changed_paths() {
    local marker_sha="$1"
    if [[ -n "$marker_sha" ]]; then
        git_nq diff --name-only --diff-filter=ACMR "$marker_sha..HEAD" 2>/dev/null
    fi
    git_nq diff --cached --name-only --diff-filter=ACMR 2>/dev/null
    git_nq diff --name-only --diff-filter=ACMR 2>/dev/null
    git_nq ls-files --others --exclude-standard 2>/dev/null
}

# Старый кэш только Configuration.xml (миграция в manifest)
legacy_configuration_cache_path() {
    local repo_root="$1"
    local config_dir_abs="$2"
    local base_id config_slug
    base_id=$(sanitize_cache_token "$(extract_base_dirname "$IB_CONNECTION")")
    config_slug=$(sanitize_cache_token "$(basename "$config_dir_abs")")
    echo "$repo_root/.tmp/load-cache/configuration-${base_id}-${config_slug}.sha256"
}

# Перенести configuration-*.sha256 в manifest (однократно)
migrate_legacy_configuration_cache() {
    local repo_root="$1"
    local config_dir_abs="$2"
    local manifest="$3"
    local legacy cached_hash config_xml

    [[ -f "$manifest" ]] && return 0

    legacy=$(legacy_configuration_cache_path "$repo_root" "$config_dir_abs")
    [[ -f "$legacy" ]] || return 0

    cached_hash=$(tr -d '[:space:]' < "$legacy")
    [[ -n "$cached_hash" ]] || return 0

    config_xml="$config_dir_abs/Configuration.xml"
    [[ -f "$config_xml" ]] || return 0

    mkdir -p "$(dirname "$manifest")"
    printf 'Configuration.xml\t%s\n' "$cached_hash" > "$manifest"
    log "INFO" "Миграция кэша Configuration.xml → $manifest"
}

# Баг платформы (8.3.x): partial -listFile не грузит Forms/.../Ext/Form/Module.bsl —
# ошибка «Неизвестный объект метаданных …Form.…Ext». Обход: грузить родительский
# Forms/Имя.xml (или CommonForms/Имя.xml) — платформа подтягивает Ext целиком.
# https://forum.infostart.ru/forum9/topic147863/
# Пишет forced-пути (родительские XML) в $2. В $3 (опц.) — исходные Module.bsl
# для кэша хешей. Forced возвращаются после фильтра только если Module.bsl или
# Forms/*.xml отличаются от кэша (иначе ИБ уже синхронна с диском).
rewrite_form_module_paths_in_list() {
    local list_file="$1"
    local forced_file="$2"
    local modules_file="${3:-}"
    local out rel parent rewritten=0
    out="${list_file}.formrewrite"
    : > "$out"
    : > "$forced_file"
    [[ -n "$modules_file" ]] && : > "$modules_file"

    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ -z "$rel" ]] && continue
        case "$rel" in
            */Forms/*/Ext/Form/Module.bsl|CommonForms/*/Ext/Form/Module.bsl)
                parent="${rel%/Ext/Form/Module.bsl}.xml"
                if [[ -f "$CONFIG_PATH_ABS/$parent" ]]; then
                    printf '%s\n' "$parent" >> "$out"
                    printf '%s\n' "$parent" >> "$forced_file"
                    [[ -n "$modules_file" ]] && printf '%s\n' "$rel" >> "$modules_file"
                    rewritten=$((rewritten + 1))
                    log "INFO" "listFile: $rel → $parent (обход бага Module.bsl)"
                else
                    log "WARN" "Нет $parent для $rel — оставляю Module.bsl (загрузка может упасть)"
                    printf '%s\n' "$rel" >> "$out"
                fi
                ;;
            *)
                printf '%s\n' "$rel" >> "$out"
                ;;
        esac
    done < "$list_file"

    awk '!seen[$0]++' "$out" > "${list_file}.tmp" && mv "${list_file}.tmp" "$list_file"
    awk '!seen[$0]++' "$forced_file" > "${forced_file}.tmp" && mv "${forced_file}.tmp" "$forced_file"
    if [[ -n "$modules_file" && -f "$modules_file" ]]; then
        awk '!seen[$0]++' "$modules_file" > "${modules_file}.tmp" && mv "${modules_file}.tmp" "$modules_file"
    fi
    rm -f "$out"
    [[ $rewritten -gt 0 ]] && log_quiet "listFile: $rewritten Form/Module.bsl → родительский Forms/*.xml"
}

# Родительский Forms/*.xml / CommonForms/*.xml → Ext/Form/Module.bsl
form_meta_xml_to_module_bsl() {
    local parent="$1"
    case "$parent" in
        CommonForms/*.xml|*/Forms/*.xml)
            printf '%s\n' "${parent%.xml}/Ext/Form/Module.bsl"
            ;;
    esac
}

# 0 — rel_path есть в manifest и SHA-256 совпадает с диском
conf_rel_matches_cache() {
    local repo_root="$1"
    local config_dir_abs="$2"
    local rel_path="$3"
    local manifest cached_hash current_hash file_path

    [[ "$SKIP_CONFIGURATION_CACHE" == "true" ]] && return 1
    [[ -z "$rel_path" ]] && return 1
    file_path="$config_dir_abs/$rel_path"
    [[ -f "$file_path" ]] || return 1
    manifest=$(conf_files_cache_manifest_path "$repo_root" "$config_dir_abs")
    [[ -f "$manifest" ]] || return 1
    cached_hash=$(awk -F'\t' -v p="$rel_path" '$1 == p { print $2; exit }' "$manifest")
    [[ -n "$cached_hash" ]] || return 1
    current_hash=$(sha256sum "$file_path" 2>/dev/null | awk '{ print $1 }')
    [[ -n "$current_hash" && "$current_hash" == "$cached_hash" ]]
}

# Вернуть forced Forms/*.xml, если кэш не подтверждает синхронность Module.bsl+Forms
readd_forced_conf_paths() {
    local list_file="$1"
    local forced_file="$2"
    local repo_root="${3:-}"
    local config_dir_abs="${4:-$CONFIG_PATH_ABS}"
    local rel module_bsl added=0 skipped_cache=0
    [[ -s "$forced_file" ]] || return 0
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ -z "$rel" ]] && continue
        [[ -f "$CONFIG_PATH_ABS/$rel" ]] || continue
        if [[ -n "$repo_root" ]]; then
            module_bsl=$(form_meta_xml_to_module_bsl "$rel")
            if [[ -n "$module_bsl" ]] \
                && conf_rel_matches_cache "$repo_root" "$config_dir_abs" "$rel" \
                && conf_rel_matches_cache "$repo_root" "$config_dir_abs" "$module_bsl"; then
                skipped_cache=$((skipped_cache + 1))
                continue
            fi
        fi
        if ! grep -Fxq -- "$rel" "$list_file" 2>/dev/null; then
            printf '%s\n' "$rel" >> "$list_file"
            added=$((added + 1))
        fi
    done < "$forced_file"
    if [[ $skipped_cache -gt 0 ]]; then
        log "INFO" "Кэш conf: пропущено $skipped_cache forced Forms/*.xml (Module.bsl+Forms без изменений)"
        log_quiet "Кэш: forced skip $skipped_cache (Module.bsl совпал)"
    fi
    if [[ $added -gt 0 ]]; then
        log "INFO" "Кэш conf: принудительно оставлены $added родительских Forms/*.xml (Module.bsl)"
        log_quiet "Кэш: forced +$added Forms/*.xml из Module.bsl"
    fi
}

# Убрать из listfile файлы, чей хеш совпадает с кэшем последней успешной загрузки
filter_unchanged_conf_files() {
    local list_file="$1"
    local repo_root="$2"
    local config_dir_abs="$3"

    if [[ "$SKIP_CONFIGURATION_CACHE" == "true" ]]; then
        return 0
    fi

    local manifest kept_file rel_path file_path current_hash cached_hash
    local verify_paths_file verify_rel_file hash_results_file
    local -A cached_hashes=()
    local -A current_hashes=()
    local -A verify_rels=()
    local skipped=0 kept=0 total=0

    manifest=$(conf_files_cache_manifest_path "$repo_root" "$config_dir_abs")
    migrate_legacy_configuration_cache "$repo_root" "$config_dir_abs" "$manifest"
    log "INFO" "Кэш хешей conf: $manifest"

    if [[ -f "$manifest" ]]; then
        while IFS=$'\t' read -r rel_path cached_hash _rest; do
            [[ -n "$rel_path" && -n "$cached_hash" ]] && cached_hashes["$rel_path"]="$cached_hash"
        done < "$manifest"
    fi

    kept_file="${list_file}.filtered"
    verify_paths_file="${list_file}.verify_paths"
    verify_rel_file="${list_file}.verify_rel"
    hash_results_file="${list_file}.hashes"
    : > "$kept_file"
    : > "$verify_paths_file"
    : > "$verify_rel_file"

    while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
        [[ -z "$rel_path" ]] && continue
        total=$((total + 1))

        if [[ "$rel_path" == "Configuration.xml" && "$FORCE_CONFIGURATION" == "true" ]]; then
            printf '%s\n' "$rel_path" >> "$kept_file"
            kept=$((kept + 1))
            continue
        fi

        file_path="$config_dir_abs/$rel_path"
        if [[ ! -f "$file_path" ]]; then
            printf '%s\n' "$rel_path" >> "$kept_file"
            kept=$((kept + 1))
            continue
        fi

        cached_hash="${cached_hashes[$rel_path]:-}"
        if [[ -z "$cached_hash" ]]; then
            printf '%s\n' "$rel_path" >> "$kept_file"
            kept=$((kept + 1))
            continue
        fi

        verify_rels["$rel_path"]=1
        printf '%s\n' "$file_path" >> "$verify_paths_file"
        printf '%s\n' "$rel_path" >> "$verify_rel_file"
    done < "$list_file"

    if [[ -s "$verify_paths_file" ]]; then
        batch_sha256_conf_files "$verify_paths_file" "$config_dir_abs" "$hash_results_file"
        while IFS=$'\t' read -r rel_path current_hash; do
            [[ -n "$rel_path" && -n "$current_hash" ]] && current_hashes["$rel_path"]="$current_hash"
        done < "$hash_results_file"

        while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
            [[ -z "$rel_path" ]] && continue
            [[ -z "${verify_rels[$rel_path]:-}" ]] && continue

            cached_hash="${cached_hashes[$rel_path]}"
            current_hash="${current_hashes[$rel_path]:-}"
            if [[ -n "$current_hash" && "$current_hash" == "$cached_hash" ]]; then
                skipped=$((skipped + 1))
            else
                printf '%s\n' "$rel_path" >> "$kept_file"
                kept=$((kept + 1))
            fi
        done < "$verify_rel_file"
    fi

    mv "$kept_file" "$list_file"
    rm -f "$verify_paths_file" "$verify_rel_file" "$hash_results_file"

    if [[ $skipped -gt 0 ]]; then
        log "INFO" "Кэш conf: пропущено $skipped из $total файлов (останется $kept)"
        log_quiet "Кэш: пропущено $skipped неизменённых файлов conf"
    fi
}

# Обновить кэш хешей загруженных файлов conf
update_conf_files_cache() {
    local list_file="$1"
    local repo_root="$2"
    local config_dir_abs="$3"

    if [[ "$SKIP_CONFIGURATION_CACHE" == "true" ]]; then
        return 0
    fi

    [[ -s "$list_file" ]] || return 0

    local manifest new_manifest rel_path file_path file_hash
    local -A update_paths=()

    manifest=$(conf_files_cache_manifest_path "$repo_root" "$config_dir_abs")
    mkdir -p "$(dirname "$manifest")"
    new_manifest="${manifest}.tmp.$$"

    while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
        [[ -n "$rel_path" ]] && update_paths["$rel_path"]=1
    done < "$list_file"

    if [[ -f "$manifest" ]]; then
        while IFS=$'\t' read -r rel_path file_hash; do
            [[ -z "$rel_path" ]] && continue
            [[ -n "${update_paths[$rel_path]:-}" ]] && continue
            printf '%s\t%s\n' "$rel_path" "$file_hash"
        done < "$manifest" > "$new_manifest"
    else
        : > "$new_manifest"
    fi

    local paths_to_hash="${list_file}.hashpaths"
    local hash_results="${list_file}.hashes"
    : > "$paths_to_hash"
    while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
        [[ -z "$rel_path" ]] && continue
        file_path="$config_dir_abs/$rel_path"
        [[ -f "$file_path" ]] || continue
        printf '%s\n' "$file_path" >> "$paths_to_hash"
    done < "$list_file"

    if [[ -s "$paths_to_hash" ]]; then
        batch_sha256_conf_files "$paths_to_hash" "$config_dir_abs" "$hash_results"
        while IFS=$'\t' read -r rel_path file_hash; do
            [[ -n "$rel_path" && -n "$file_hash" ]] || continue
            printf '%s\t%s\n' "$rel_path" "$file_hash" >> "$new_manifest"
        done < "$hash_results"
    fi
    rm -f "$paths_to_hash" "$hash_results"

    mv "$new_manifest" "$manifest"
    log "INFO" "Кэш хешей conf обновлён: $manifest"
}

# После full-resync: список dirty conf (working-tree) + оба ключа Form/Module.bsl↔Forms/*.xml
# для seed кэша хешей (следующий partial не перезальёт уже загруженное).
build_conf_cache_seed_from_git_dirty() {
    local out_file="$1"
    local file relative_path parent
    local seed_raw="${out_file}.raw"

    : > "$seed_raw"
    # Маркер после -F сброшен → только working-tree (как следующий -C после записи HEAD).
    git_all_changed_paths "" | while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        file="${file#./}"
        case "$file" in
            "$CONFIG_GIT_PREFIX"/*)
                relative_path="${file#"$CONFIG_GIT_PREFIX"/}"
                if [[ -n "$relative_path" && -f "$repo_path/$file" ]]; then
                    printf '%s\n' "$relative_path"
                fi
                ;;
        esac
    done | awk '!seen[$0]++' > "$seed_raw"

    : > "$out_file"
    while IFS= read -r relative_path || [[ -n "$relative_path" ]]; do
        [[ -z "$relative_path" ]] && continue
        printf '%s\n' "$relative_path" >> "$out_file"
        case "$relative_path" in
            */Forms/*/Ext/Form/Module.bsl|CommonForms/*/Ext/Form/Module.bsl)
                parent="${relative_path%/Ext/Form/Module.bsl}.xml"
                if [[ -f "$CONFIG_PATH_ABS/$parent" ]]; then
                    printf '%s\n' "$parent" >> "$out_file"
                fi
                ;;
        esac
    done < "$seed_raw"
    awk '!seen[$0]++' "$out_file" > "${out_file}.uniq" && mv "${out_file}.uniq" "$out_file"
    rm -f "$seed_raw"
}

# Читает строки из файла списка или stdin (-); пропускает пустые и #-комментарии
read_list_file_lines() {
    local list_file="$1"

    filter_list_lines() {
        sed '1s/^\xEF\xBB\xBF//' | while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            printf '%s\n' "$line"
        done
    }

    if [[ "$list_file" == "-" ]]; then
        filter_list_lines
    else
        if [[ ! -f "$list_file" ]]; then
            log "ERROR" "Файл списка не найден: $list_file"
            exit 1
        fi
        filter_list_lines < "$list_file"
    fi
}

# Классифицирует путь: echo "conf:<относительно conf>" или "ext:<имя расширения>"
classify_explicit_entry() {
    local raw="$1"
    local entry config_base ext_base entry_abs ext_rel first_part

    entry="$raw"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    entry="${entry#./}"
    [[ -z "$entry" ]] && return 1

    config_base=$(basename "$CONFIG_PATH_ABS")
    ext_base=$(basename "$EXTENSIONS_PATH_ABS")

    # Абсолютный путь
    if [[ "$entry" = /* || "$entry" =~ ^[A-Za-z]:[/\\] ]]; then
        entry_abs=$(win_to_unix_path "$entry")
        if [[ ! -f "$entry_abs" ]]; then
            log "ERROR" "Файл не найден: $raw"
            return 1
        fi
        if [[ "$entry_abs" == "$CONFIG_PATH_ABS"/* ]]; then
            printf 'conf:%s\n' "${entry_abs#$CONFIG_PATH_ABS/}"
            return 0
        fi
        if [[ -d "$EXTENSIONS_PATH_ABS" && "$entry_abs" == "$EXTENSIONS_PATH_ABS"/* ]]; then
            ext_rel="${entry_abs#$EXTENSIONS_PATH_ABS/}"
            printf 'ext:%s\n' "${ext_rel%%/*}"
            return 0
        fi
        log "ERROR" "Путь вне $CONFIG_PATH/ и $EXTENSIONS_PATH/: $raw"
        return 1
    fi

    # Префикс git-пути расширений
    if [[ -n "$EXTENSIONS_GIT_PREFIX" && "$entry" == "$EXTENSIONS_GIT_PREFIX"/* ]]; then
        ext_rel="${entry#"$EXTENSIONS_GIT_PREFIX"/}"
        first_part="${ext_rel%%/*}"
        if [[ -z "$first_part" || ! -f "$EXTENSIONS_PATH_ABS/$ext_rel" ]]; then
            log "ERROR" "Файл расширения не найден: $raw"
            return 1
        fi
        printf 'ext:%s\n' "$first_part"
        return 0
    fi

    # Префикс git-пути conf
    if [[ -n "$CONFIG_GIT_PREFIX" && "$entry" == "$CONFIG_GIT_PREFIX"/* ]]; then
        entry="${entry#"$CONFIG_GIT_PREFIX"/}"
        if [[ ! -f "$CONFIG_PATH_ABS/$entry" ]]; then
            log "ERROR" "Файл conf не найден: $raw"
            return 1
        fi
        printf 'conf:%s\n' "$entry"
        return 0
    fi

    # Префикс basename каталога (cfe.xml/..., conf/...)
    if [[ -d "$EXTENSIONS_PATH_ABS" && "$entry" == "$ext_base"/* ]]; then
        ext_rel="${entry#"$ext_base"/}"
        first_part="${ext_rel%%/*}"
        if [[ -z "$first_part" || ! -f "$EXTENSIONS_PATH_ABS/$ext_rel" ]]; then
            log "ERROR" "Файл расширения не найден: $raw"
            return 1
        fi
        printf 'ext:%s\n' "$first_part"
        return 0
    fi

    if [[ "$entry" == "$config_base"/* ]]; then
        entry="${entry#"$config_base"/}"
        if [[ ! -f "$CONFIG_PATH_ABS/$entry" ]]; then
            log "ERROR" "Файл conf не найден: $raw"
            return 1
        fi
        printf 'conf:%s\n' "$entry"
        return 0
    fi

    # Относительный путь без префикса — сначала conf
    if [[ -f "$CONFIG_PATH_ABS/$entry" ]]; then
        printf 'conf:%s\n' "$entry"
        return 0
    fi

    # Путь вида <Расширение>/... без префикса cfe.xml
    if [[ -d "$EXTENSIONS_PATH_ABS" ]]; then
        first_part="${entry%%/*}"
        if [[ -n "$first_part" && -d "$EXTENSIONS_PATH_ABS/$first_part" && -f "$EXTENSIONS_PATH_ABS/$entry" ]]; then
            printf 'ext:%s\n' "$first_part"
            return 0
        fi
    fi

    log "ERROR" "Файл не найден или путь неоднозначен: $raw"
    return 1
}

discover_changed_files_from_git() {
    local marker_sha marker_short
    resolve_loaded_marker
    marker_sha="$RESOLVED_LOAD_MARKER"
    COMMITTED_CHANGES_PRESENT=false
    if committed_range_has_changes "$marker_sha"; then
        COMMITTED_CHANGES_PRESENT=true
        marker_short="${marker_sha:0:8}"
        log "INFO" "Committed-изменения с маркера ${marker_short}..HEAD"
    elif [[ -n "$marker_sha" ]]; then
        marker_short="${marker_sha:0:8}"
        log "INFO" "Нет committed-изменений с маркера ${marker_short}..HEAD"
    else
        log "INFO" "Маркер загрузки отсутствует — только working-tree"
    fi

    timing_mark "git: diff/ls-files conf"
    git_all_changed_paths "$marker_sha" | while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        file="${file#./}"
        case "$file" in
            "$CONFIG_GIT_PREFIX"/*)
                relative_path="${file#"$CONFIG_GIT_PREFIX"/}"
                if [[ -n "$relative_path" && -f "$repo_path/$file" ]]; then
                    printf '%s\n' "$relative_path"
                fi
                ;;
        esac
    done | awk '!seen[$0]++' > temp_changed_files.txt
    conf_list_lines=$(wc -l < temp_changed_files.txt | tr -d ' ')
    timing_mark "git: список conf (${conf_list_lines} в списке)"

    if [[ "$SKIP_EXTENSIONS" == "true" ]]; then
        : > temp_changed_extensions.txt
    elif [[ -d "$EXTENSIONS_PATH_ABS" ]]; then
        timing_mark "git: diff/ls-files расширения"
        git_all_changed_paths "$marker_sha" | while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            file="${file#./}"
            case "$file" in
                "$EXTENSIONS_GIT_PREFIX"/*)
                    ext_relative="${file#"$EXTENSIONS_GIT_PREFIX"/}"
                    ext_name="${ext_relative%%/*}"
                    if [[ -n "$ext_name" && -d "$repo_path/$EXTENSIONS_GIT_PREFIX/$ext_name" ]]; then
                        printf '%s\n' "$ext_name"
                    fi
                    ;;
            esac
        done | awk '!seen[$0]++' > temp_changed_extensions.txt
        ext_list_lines=$(wc -l < temp_changed_extensions.txt | tr -d ' ')
        timing_mark "git: список расширений (${ext_list_lines} в списке)"
    else
        : > temp_changed_extensions.txt
    fi
}

discover_changed_files_from_list() {
    local list_file="$1"
    local line classified kind value

    rm -f temp_changed_files.txt temp_changed_extensions.txt
    : > temp_changed_files.txt
    : > temp_changed_extensions.txt

    timing_mark "явный список: чтение $list_file"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! classified=$(classify_explicit_entry "$line"); then
            exit 1
        fi
        kind="${classified%%:*}"
        value="${classified#*:}"
        case "$kind" in
            conf)
                printf '%s\n' "$value" >> temp_changed_files.txt
                ;;
            ext)
                if [[ "$SKIP_EXTENSIONS" != "true" ]]; then
                    printf '%s\n' "$value" >> temp_changed_extensions.txt
                fi
                ;;
        esac
    done < <(read_list_file_lines "$list_file")

    awk '!seen[$0]++' temp_changed_files.txt > temp_changed_files.txt.tmp && mv temp_changed_files.txt.tmp temp_changed_files.txt
    awk '!seen[$0]++' temp_changed_extensions.txt > temp_changed_extensions.txt.tmp && mv temp_changed_extensions.txt.tmp temp_changed_extensions.txt

    conf_list_lines=$(wc -l < temp_changed_files.txt | tr -d ' ')
    ext_list_lines=$(wc -l < temp_changed_extensions.txt | tr -d ' ')
    timing_mark "явный список: conf (${conf_list_lines}), расширений (${ext_list_lines})"
}

# Загрузка настроек из .env (повторный source — если файл появился позже; иначе уже .env.example)
if [[ -f ".env" ]]; then
    log "INFO" "Загрузка настроек из файла .env"
    # shellcheck disable=SC1091
    source ".env"
fi
if [[ -f ".env.agent-container" ]]; then
    log "INFO" "Загрузка настроек слота из .env.agent-container"
    # shellcheck disable=SC1091
    source ".env.agent-container"
elif [[ -z "${PLATFORM_BUILD:-}" ]]; then
    log "WARN" "Файл .env не найден, используются значения из .env.example"
fi

# Настройки по умолчанию (если не установлены в .env или переменных окружения)
CONFIG_PATH="${CONFIG_PATH:-conf}"
EXTENSIONS_PATH="${EXTENSIONS_PATH:-cfe.xml}"
GIT_PATH="${GIT_PATH:-.}"
OUTPUT_FILE="changed_files.txt"  # Фиксированное имя файла
IB_CONNECTION="${IB_CONNECTION:-"/F\"C:/base/proj\""}"
DESIGNER_PATH="${DESIGNER_PATH:-$(resolve_designer_default)}"
AUTO_CLOSE_DESIGNER="${AUTO_CLOSE_DESIGNER:-false}"  # Автоматически закрывать конфигуратор
AUTO_UNSUPPORT_OBJECTS="${AUTO_UNSUPPORT_OBJECTS:-false}"
UPDATE_DB="${UPDATE_DB:-false}"
# Авто-retry UpdateDB при ошибке из-за HTTP-клиентов (вторая публикация ИБ).
# true по умолчанию: завершает сеансы принудительно ТОЛЬКО при таком сбое и с WARN.
# На prod-хостах выключайте (false), чтобы не рвать пользователей молча.
UPDATE_DB_FORCE_SESSIONS="${UPDATE_DB_FORCE_SESSIONS:-true}"
REOPEN_DESIGNER_AFTER_LOAD="${REOPEN_DESIGNER_AFTER_LOAD:-false}"
AUTO_CLOSE_CLIENT="${AUTO_CLOSE_CLIENT:-false}"
REOPEN_CLIENT_AFTER_LOAD="${REOPEN_CLIENT_AFTER_LOAD:-false}"
CLIENT_LAUNCH_KEYS="${CLIENT_LAUNCH_KEYS:-}"
APACHE_SERVICE_NAME="${APACHE_SERVICE_NAME:-}"  # Пусто = не управлять Apache
SKIP_CONFIGURATION_CACHE="${SKIP_CONFIGURATION_CACHE:-false}"
FORCE_CONFIGURATION="${FORCE_CONFIGURATION:-false}"
SKIP_EXTENSIONS="${SKIP_EXTENSIONS:-false}"
LOAD_ENGINE="${LOAD_ENGINE:-designer}"   # designer (1cv8.exe CONFIG) | ibcmd
IBCMD_PATH="${IBCMD_PATH:-}"             # пусто = рядом с DESIGNER_PATH
IBCMD_NO_CHECK="${IBCMD_NO_CHECK:-false}"  # true — --no-check у import files (быстро, без проверки метаданных)
LIST_FILE=""
RESET_LOAD_MARKER="${RESET_LOAD_MARKER:-false}"
FULL_RESYNC="${FULL_RESYNC:-false}"   # полная загрузка conf/ целиком (без partial) + reset-marker
FORCE_PARTIAL="${FORCE_PARTIAL:-false}"
LOAD_HIDE_FILES="${LOAD_HIDE_FILES:-}"
RESOLVED_LOAD_MARKER=""
COMMITTED_CHANGES_PRESENT=false

# Парсинг аргументов командной строки
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config-path)
            CONFIG_PATH="$2"
            shift 2
            ;;
        -e|--extensions-path)
            EXTENSIONS_PATH="$2"
            shift 2
            ;;
        -g|--git-path)
            GIT_PATH="$2"
            shift 2
            ;;
        -i|--ib-connection)
            IB_CONNECTION="$2"
            shift 2
            ;;
        -d|--designer-path)
            DESIGNER_PATH="$2"
            shift 2
            ;;
        -n|--no-close)
            AUTO_CLOSE_DESIGNER="false"
            shift
            ;;
        --allow-close-designer)
            AUTO_CLOSE_DESIGNER="true"
            shift
            ;;
        -H|--human-mode)
            AUTO_CLOSE_DESIGNER="true"
            REOPEN_DESIGNER_AFTER_LOAD="true"
            VERBOSE=true
            shift
            ;;
        -C|--open-client)
            UPDATE_DB="true"
            AUTO_CLOSE_DESIGNER="true"
            AUTO_CLOSE_CLIENT="true"
            REOPEN_CLIENT_AFTER_LOAD="true"
            VERBOSE=true
            shift
            ;;
        --client-keys)
            CLIENT_LAUNCH_KEYS="${2:-}"
            if [[ -z "$CLIENT_LAUNCH_KEYS" ]]; then
                log "ERROR" "--client-keys требует строку ключей запуска клиента"
                exit 1
            fi
            shift 2
            ;;
        --refresh-variants)
            UPDATE_DB="true"
            AUTO_CLOSE_DESIGNER="true"
            AUTO_CLOSE_CLIENT="true"
            REOPEN_CLIENT_AFTER_LOAD="true"
            CLIENT_LAUNCH_KEYS='/C"ЗапуститьОбновлениеИнформационнойБазы" /DisableStartupDialogs /DisableStartupMessages'
            VERBOSE=true
            shift
            ;;
        -u|--auto-unsupport)
            AUTO_UNSUPPORT_OBJECTS="true"
            shift
            ;;
        -U|--update-db)
            UPDATE_DB="true"
            shift
            ;;
        --force-sessions)
            UPDATE_DB_FORCE_SESSIONS="true"
            shift
            ;;
        --no-force-sessions)
            UPDATE_DB_FORCE_SESSIONS="false"
            shift
            ;;
        --reopen-designer)
            REOPEN_DESIGNER_AFTER_LOAD="true"
            shift
            ;;
        --force-configuration)
            FORCE_CONFIGURATION="true"
            shift
            ;;
        --list-file)
            LIST_FILE="$2"
            shift 2
            ;;
        --no-extensions)
            SKIP_EXTENSIONS="true"
            shift
            ;;
        --reset-marker)
            RESET_LOAD_MARKER="true"
            shift
            ;;
        --force-partial)
            FORCE_PARTIAL="true"
            shift
            ;;
        -F|--full-resync)
            FULL_RESYNC="true"
            RESET_LOAD_MARKER="true"
            UPDATE_DB="true"
            shift
            ;;
        --engine)
            LOAD_ENGINE="$2"
            shift 2
            ;;
        --ibcmd)
            LOAD_ENGINE="ibcmd"
            shift
            ;;
        --ibcmd-path)
            IBCMD_PATH="$2"
            shift 2
            ;;
        --ibcmd-no-check)
            IBCMD_NO_CHECK="true"
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Использование: $0 [ОПЦИИ]"
            echo ""
            echo "Опции:"
            echo "  -c, --config-path PATH      Путь к папке conf (по умолчанию: conf)"
            echo "  -e, --extensions-path PATH  Путь к папке расширений (по умолчанию: cfe.xml)"
            echo "  -g, --git-path PATH         Путь к git репозиторию (по умолчанию: .)"
            echo "  -i, --ib-connection CONN    Строка подключения к ИБ (по умолчанию: /F\"C:/base/proj\")"
            echo "  -d, --designer-path PATH    Путь к 1cv8.exe (по умолчанию: DESIGNER_PATH из .env / .env.example)"
            echo "  -n, --no-close              Запретить автозакрытие конфигуратора"
            echo "      --allow-close-designer  Явно разрешить автозакрытие конфигуратора"
            echo "  -H, --human-mode            Старый режим: закрыть и переоткрыть конфигуратор"
            echo "  -C, --open-client           Загрузить, обновить БД и открыть тонкий клиент (1cv8c.exe)"
            echo "      --client-keys KEYS      Дополнительные ключи запуска клиента (строка целиком)"
            echo "      --refresh-variants      Актуализировать варианты отчётов (ключ БСП ЗапуститьОбновлениеИнформационнойБазы)"
            echo "  -u, --auto-unsupport        Автоматически снимать с поддержки загружаемые объекты"
            echo "  -U, --update-db             Обновить конфигурацию базы данных после загрузки"
            echo "      --reopen-designer       Открыть конфигуратор после загрузки"
            echo "      --force-configuration   Всегда загружать Configuration.xml (игнорировать кэш для этого файла)"
            echo "      --list-file PATH        Фолбэк: явный список (заменяет git); PATH=- для stdin"
            echo "      --no-extensions         Загружать только conf, без расширений (cfe.xml)"
            echo "      --reset-marker          Сбросить маркер HEAD последней загрузки committed-изменений"
            echo "      --force-partial         Не отменять partial с Configuration.xml после merge"
            echo "  -F, --full-resync           Полная загрузка conf/ целиком (без partial) + reset-marker + авто-UpdateDBCfg"
            echo "      --engine ENGINE         Движок загрузки: designer (по умолчанию) | ibcmd"
            echo "      --ibcmd                 Сокращение для --engine ibcmd"
            echo "      --ibcmd-path PATH       Путь к ibcmd.exe (по умолчанию рядом с DESIGNER_PATH)"
            echo "      --ibcmd-no-check        ibcmd: --no-check у import files (быстро, без проверки метаданных)"
            echo "      --force-sessions        При ошибке UpdateDB из-за HTTP-клиентов повторить с -Dynamic- -SessionTerminate force"
            echo "      --no-force-sessions     Запретить принудительное завершение сеансов (переопределяет UPDATE_DB_FORCE_SESSIONS)"
            echo "      --verbose               Подробный вывод (по умолчанию краткий; -H/-C — подробный)"
            echo "  -h, --help                  Показать эту справку"
            echo ""
            echo "Переменные окружения:"
            echo "  CONFIG_PATH               Путь к папке основной конфигурации"
            echo "  EXTENSIONS_PATH           Путь к папке расширений"
            echo "  GIT_PATH                  Путь к git репозиторию"
            echo "  IB_CONNECTION             Строка подключения к ИБ"
            echo "  DESIGNER_PATH             Путь к 1cv8.exe"
            echo "  AUTO_CLOSE_DESIGNER       Автоматически закрывать конфигуратор"
            echo "  AUTO_UNSUPPORT_OBJECTS    Автоматически снимать с поддержки загружаемые объекты"
            echo "  PARENT_CONFIG_PY          Путь к parent_config.py для preflight (default: scripts/ потребителя, иначе kit)"
            echo "  UPDATE_DB                 Обновить конфигурацию базы данных после загрузки"
            echo "  UPDATE_DB_FORCE_SESSIONS  true (default) — авто-retry UpdateDB с -Dynamic- -SessionTerminate force"
            echo "                            при ошибке «обнаружены клиенты, работающие по HTTP»; false — не завершать сеансы"
            echo "  REOPEN_DESIGNER_AFTER_LOAD Открывать конфигуратор после загрузки"
            echo "  APACHE_SERVICE_NAME       Имя службы Apache для остановки/запуска при UPDATE_DB"
            echo "                            (пусто = не управлять; пример: Apache2.4)"
            echo "  SKIP_CONFIGURATION_CACHE  true — не пропускать и не обновлять кэш хешей conf"
            echo "  FORCE_CONFIGURATION       true — то же, что --force-configuration (только Configuration.xml)"
            echo "  SKIP_EXTENSIONS           true — то же, что --no-extensions"
            echo "  RESET_LOAD_MARKER         true — то же, что --reset-marker"
            echo "  FORCE_PARTIAL             true — то же, что --force-partial"
            echo "  FULL_RESYNC               true — то же, что --full-resync"
            echo "  LOAD_HIDE_FILES           «;»-список путей (спрятать на время LoadConfigFromFiles)"
            echo "  LOAD_ENGINE               designer | ibcmd (по умолчанию designer)"
            echo "  IBCMD_PATH                Путь к ibcmd.exe (по умолчанию рядом с DESIGNER_PATH)"
            echo "  IBCMD_NO_CHECK            true — то же, что --ibcmd-no-check"
            echo "  IBCMD_DBMS/IBCMD_DB_SERVER/IBCMD_DB_NAME/IBCMD_DB_USER/IBCMD_DB_PWD"
            echo "                            Параметры серверной ИБ для движка ibcmd (для /S подключений)"
            echo "  LOAD_VERBOSE              true — то же, что --verbose"
            echo "  LOG_FILE_LIST_THRESHOLD   Порог поименного вывода в -H/-C/--verbose (default: 100)"
            exit 0
            ;;
        *)
            log "ERROR" "Неизвестный параметр: $1"
            echo "Используйте $0 --help для справки"
            exit 1
            ;;
    esac
done

if [[ "$REOPEN_DESIGNER_AFTER_LOAD" == "true" && "$REOPEN_CLIENT_AFTER_LOAD" == "true" ]]; then
    log "ERROR" "Нельзя одновременно использовать -H (--human-mode) и -C (--open-client)"
    exit 1
fi

# Linux-слот: путь 1cv8 из платформы, если в .env остался Windows-путь
if [[ "${PROJECT_OS}" == "linux" ]]; then
    _designer_unix=$(win_to_unix_path "$DESIGNER_PATH")
    if [[ ! -x "$_designer_unix" ]]; then
        _linux_default=$(resolve_designer_default)
        if [[ -n "$_linux_default" && -x "$_linux_default" ]]; then
            DESIGNER_PATH="$_linux_default"
            log "INFO" "DESIGNER_PATH (Linux): $DESIGNER_PATH"
        fi
    fi
fi

ib_config_auth_suffix
normalize_ib_connection_linux

# Полный путь к 1cv8 (до LoadConfigFromFiles / UpdateDBCfg / -H/-C)
if [[ "${PROJECT_OS}" == "linux" ]]; then
    DESIGNER_CMD="$DESIGNER_PATH"
else
    DESIGNER_PATH=$(unix_to_win_path "$DESIGNER_PATH")
    DESIGNER_CMD="$DESIGNER_PATH"
fi

if [[ ! -x "$DESIGNER_CMD" && ! -f "$DESIGNER_CMD" ]]; then
    log "ERROR" "1С:Предприятие не найден по пути: $DESIGNER_PATH"
    log "ERROR" "Укажите DESIGNER_PATH в .env или опцию -d"
    exit 1
fi

# Движок загрузки: designer (1cv8.exe CONFIG) или ibcmd
if [[ "$LOAD_ENGINE" != "designer" && "$LOAD_ENGINE" != "ibcmd" ]]; then
    log "ERROR" "Неизвестный движок: $LOAD_ENGINE (допустимо: designer | ibcmd)"
    exit 1
fi

if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
    [[ -z "$IBCMD_PATH" ]] && IBCMD_PATH=$(resolve_ibcmd_default)
    if [[ "${PROJECT_OS}" == "linux" ]]; then
        IBCMD_CMD="$IBCMD_PATH"
    else
        IBCMD_CMD=$(unix_to_win_path "$(win_to_unix_path "$IBCMD_PATH")")
    fi
    if [[ ! -x "$IBCMD_CMD" && ! -f "$IBCMD_CMD" ]]; then
        log "ERROR" "ibcmd не найден по пути: $IBCMD_PATH"
        log "ERROR" "Укажите IBCMD_PATH в .env или опцию --ibcmd-path"
        exit 1
    fi
    if ! build_ibcmd_db_args; then
        exit 1
    fi
    build_ibcmd_auth
    log "INFO" "Движок загрузки: ibcmd ($IBCMD_CMD)"
fi

# Начало выполнения
log "INFO" "Начало выполнения скрипта загрузки измененных файлов"
timing_reset
timing_mark "старт"

# Проверяем наличие необходимых команд
check_command git

# Преобразуем пути
CONFIG_PATH=$(win_to_unix_path "$CONFIG_PATH")
EXTENSIONS_PATH=$(win_to_unix_path "$EXTENSIONS_PATH")
GIT_PATH=$(win_to_unix_path "$GIT_PATH")

# Переходим в директорию репозитория
if [[ ! -d "$GIT_PATH" ]]; then
    log "ERROR" "Директория git репозитория не найдена: $GIT_PATH"
    exit 1
fi

cd "$GIT_PATH" || {
    log "ERROR" "Не удалось перейти в директорию: $GIT_PATH"
    exit 1
}

log "INFO" "Рабочая директория: $(pwd)"

# Получаем изменения в основной конфигурации и расширениях
if [[ -n "$LIST_FILE" ]]; then
    log "INFO" "Фолбэк: явный список (--list-file $LIST_FILE), git-discovery отключён"
else
    log "INFO" "Получение списка изменений из git..."
fi

# Очищаем временные файлы
rm -f temp_changed_files.txt temp_changed_extensions.txt

# Получаем полный путь к репозиторию
repo_path=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$repo_path" ]]; then
    repo_path=$(pwd)
fi

# Ранний EXIT-trap: temp-файлы не остаются даже при exit до основного trap.
trap 'cleanup_temp_files' EXIT

# Нормализация пути основной конфигурации
if [[ "$CONFIG_PATH" = /* || "$CONFIG_PATH" =~ ^[A-Za-z]:/ ]]; then
    CONFIG_PATH_ABS="$CONFIG_PATH"
else
    CONFIG_PATH_ABS="$repo_path/$CONFIG_PATH"
fi
CONFIG_PATH_ABS=$(win_to_unix_path "$CONFIG_PATH_ABS")

if [[ ! -d "$CONFIG_PATH_ABS" ]]; then
    log "ERROR" "Папка конфигурации не найдена: $CONFIG_PATH_ABS"
    exit 1
fi

if [[ "$CONFIG_PATH_ABS" != "$repo_path"* ]]; then
    log "ERROR" "Папка конфигурации должна находиться внутри git-репозитория: $CONFIG_PATH_ABS"
    exit 1
fi

CONFIG_GIT_PREFIX="${CONFIG_PATH_ABS#$repo_path/}"
CONFIG_GIT_PREFIX="${CONFIG_GIT_PREFIX#/}"
CONFIG_GIT_PREFIX="${CONFIG_GIT_PREFIX%/}"

# Нормализация пути расширений
if [[ "$EXTENSIONS_PATH" = /* || "$EXTENSIONS_PATH" =~ ^[A-Za-z]:/ ]]; then
    EXTENSIONS_PATH_ABS="$EXTENSIONS_PATH"
else
    EXTENSIONS_PATH_ABS="$repo_path/$EXTENSIONS_PATH"
fi
EXTENSIONS_PATH_ABS=$(win_to_unix_path "$EXTENSIONS_PATH_ABS")

EXTENSIONS_GIT_PREFIX="${EXTENSIONS_PATH_ABS#$repo_path/}"
EXTENSIONS_GIT_PREFIX="${EXTENSIONS_GIT_PREFIX#/}"
EXTENSIONS_GIT_PREFIX="${EXTENSIONS_GIT_PREFIX%/}"

timing_mark "подготовка (cd, пути)"

if [[ "$RESET_LOAD_MARKER" == "true" ]]; then
    rm -f "$(loaded_marker_path "$repo_path")" 2>/dev/null || true
    log "INFO" "Маркер загрузки сброшен (--reset-marker)"
    if [[ "$FULL_RESYNC" != "true" ]] && head_is_merge; then
        log "WARN" "--reset-marker при merge не заменяет -F: при чистом дереве без fallback"
        log "WARN" "был бы пустой список. Ниже маркер выводится из HEAD^1."
    fi
fi

if [[ "$FULL_RESYNC" != "true" && -z "$LIST_FILE" ]]; then
    restore_missing_worktree_from_index "$CONFIG_GIT_PREFIX" || exit 21
    if [[ "$SKIP_EXTENSIONS" != "true" && -n "$EXTENSIONS_GIT_PREFIX" ]]; then
        restore_missing_worktree_from_index "$EXTENSIONS_GIT_PREFIX" || exit 21
    fi
fi

if [[ "$FULL_RESYNC" == "true" ]]; then
    log "INFO" "Режим --full-resync: полная загрузка $CONFIG_PATH/ целиком (без partial), git-discovery отключён"
    : > temp_changed_files.txt
elif [[ -n "$LIST_FILE" ]]; then
    discover_changed_files_from_list "$LIST_FILE"
else
    discover_changed_files_from_git
    warn_if_merge_in_range "${RESOLVED_LOAD_MARKER:-}"
    abort_costly_merge_partial "${RESOLVED_LOAD_MARKER:-}" || {
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 21
    }
fi

if [[ "$SKIP_EXTENSIONS" == "true" ]]; then
    : > temp_changed_extensions.txt
    log "INFO" "Режим --no-extensions: расширения ($EXTENSIONS_PATH/) не загружаются"
fi

# При full-resync грузим все расширения целиком (список = все каталоги cfe.xml/)
if [[ "$FULL_RESYNC" == "true" && "$SKIP_EXTENSIONS" != "true" && -d "$EXTENSIONS_PATH_ABS" ]]; then
    : > temp_changed_extensions.txt
    for d in "$EXTENSIONS_PATH_ABS"/*/; do
        [[ -d "$d" ]] || continue
        printf '%s\n' "$(basename "$d")" >> temp_changed_extensions.txt
    done
    ext_count=$(wc -l < temp_changed_extensions.txt | tr -d ' ')
    log "INFO" "Full-resync: все расширения ($ext_count шт.)"
fi

conf_list_before_cache=0
: > temp_rewritten_form_modules.txt
if [[ -s temp_changed_files.txt ]]; then
    timing_mark "rewrite Form/Module.bsl → Forms/*.xml"
    rewrite_form_module_paths_in_list temp_changed_files.txt temp_forced_form_metas.txt temp_rewritten_form_modules.txt
    conf_list_before_cache=$(wc -l < temp_changed_files.txt | tr -d ' ')
    timing_mark "фильтр кэша conf"
    filter_unchanged_conf_files temp_changed_files.txt "$repo_path" "$CONFIG_PATH_ABS"
    readd_forced_conf_paths temp_changed_files.txt temp_forced_form_metas.txt "$repo_path" "$CONFIG_PATH_ABS"
    conf_list_lines=$(wc -l < temp_changed_files.txt | tr -d ' ')
    timing_mark "после фильтра conf (${conf_list_lines} в списке)"
fi
rm -f temp_forced_form_metas.txt

has_conf_changes="false"
has_extension_changes="false"
if [[ "$FULL_RESYNC" == "true" ]]; then
    has_conf_changes="true"
fi
if [[ -s temp_changed_files.txt ]]; then
    has_conf_changes="true"
fi
if [[ -s temp_changed_extensions.txt ]]; then
    has_extension_changes="true"
fi

nothing_to_load="false"
if [[ "$has_conf_changes" == "false" && "$has_extension_changes" == "false" ]]; then
    nothing_to_load="true"
    if [[ "$conf_list_before_cache" -gt 0 ]]; then
        log "WARN" "Нет файлов к загрузке: все $conf_list_before_cache файлов conf пропущены кэшем (содержимое не изменилось)"
        log_quiet "Загрузка пропущена: кэш conf, 0 файлов к загрузке"
    elif [[ -n "$LIST_FILE" ]]; then
        if [[ "$SKIP_EXTENSIONS" == "true" ]]; then
            log "WARN" "Явный список пуст или не содержит валидных путей в $CONFIG_PATH/"
        else
            log "WARN" "Явный список пуст или не содержит валидных путей в $CONFIG_PATH/ и $EXTENSIONS_PATH/"
        fi
    elif [[ "$SKIP_EXTENSIONS" == "true" ]]; then
        log "WARN" "Изменений в папке $CONFIG_PATH/ не найдено (--no-extensions)"
    else
        log "WARN" "Изменений в папках $CONFIG_PATH/ и $EXTENSIONS_PATH/ не найдено"
    fi
    timing_mark "изменений нет"
    if [[ "${conf_list_before_cache:-0}" -eq 0 ]]; then
        abort_empty_load_after_merge "${RESOLVED_LOAD_MARKER:-}" || {
            rm -f temp_changed_files.txt temp_changed_extensions.txt
            exit 21
        }
    fi
    if [[ "$REOPEN_CLIENT_AFTER_LOAD" != "true" && "$REOPEN_DESIGNER_AFTER_LOAD" != "true" && "$UPDATE_DB" != "true" ]]; then
        timing_summary "conf: 0 файлов | расширения: 0"
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 0
    fi
    if [[ "$UPDATE_DB" == "true" ]]; then
        log "INFO" "Загрузка пропущена; продолжаем для UpdateDB (-U/-C)"
    else
        log "INFO" "Загрузка пропущена; продолжаем для -H/-C (запуск конфигуратора/клиента)"
    fi
fi

file_count=0
ext_count=0
if [[ "$nothing_to_load" != "true" ]]; then
    if [[ "$has_conf_changes" == "true" ]]; then
    if [[ "$FULL_RESYNC" != "true" ]]; then
    file_count=$(wc -l < temp_changed_files.txt)
    log "INFO" "Найдено $file_count измененных файлов в $CONFIG_PATH/"

    # Создаем итоговый файл со списком измененных файлов в UTF-8 with BOM (только основная конфигурация).
    # Пишем во временный каталог потребителя (.tmp/, рядом с логом загрузки) и снимаем
    # на любом выходе через EXIT-trap — артефакт не остаётся в корне репозитория.
    mkdir -p "$repo_path/.tmp"
    full_output_file="$repo_path/.tmp/$OUTPUT_FILE"
    _LIST_OUTPUT_FILE="$full_output_file"
    trap 'cleanup_temp_files; cleanup_changed_files_list' EXIT
    {
        printf '\xEF\xBB\xBF'
        cat temp_changed_files.txt
    } > "$full_output_file"

    log_file_list "Содержимое файла $OUTPUT_FILE:" temp_changed_files.txt "полный список в $OUTPUT_FILE"
    else
    file_count="all"
    log "INFO" "Full-resync: загрузка $CONFIG_PATH/ целиком (без listFile)"
    fi
    fi

    if [[ "$has_extension_changes" == "true" ]]; then
    ext_count=$(wc -l < temp_changed_extensions.txt)
    log "INFO" "Найдено $ext_count измененных расширений в $EXTENSIONS_PATH/"
    log_file_list "Будут загружены расширения целиком:" temp_changed_extensions.txt
    fi

    timing_mark "итог списка (conf: ${file_count} файлов, расширений: ${ext_count})"

    quiet_plan_parts=()
    [[ "$has_conf_changes" == "true" ]] && quiet_plan_parts+=("conf: ${file_count} файлов")
    [[ "$has_extension_changes" == "true" ]] && quiet_plan_parts+=("расширений: ${ext_count}")
    [[ "$UPDATE_DB" == "true" ]] && quiet_plan_parts+=("UpdateDB")
    quiet_plan_joined=$(IFS=' | '; echo "${quiet_plan_parts[*]}")
    log_quiet "Загрузка: ${quiet_plan_joined}"

    log "INFO" "Загрузка файлов в конфигурацию 1С..."
else
    if [[ "$UPDATE_DB" == "true" ]]; then
        log_quiet "Загрузка пропущена; только UpdateDB"
    else
        log_quiet "Загрузка пропущена (нечего грузить)"
    fi
fi

# Закрытие клиента перед загрузкой (режим -C)
if [[ "$AUTO_CLOSE_CLIENT" == "true" ]]; then
    close_1c_enterprise
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Не удалось закрыть клиент. Выполнение прервано."
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 1
    fi
fi

# Обработка активного конфигуратора перед загрузкой
if [[ "$AUTO_CLOSE_DESIGNER" == "true" ]]; then
    close_1c_designer
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Не удалось закрыть конфигуратор. Выполнение прервано."
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 1
    fi
else
    designer_pids=$(find_1c_designer_pids)
    if [[ -n "$designer_pids" ]]; then
        log "WARN" "Обнаружен запущенный конфигуратор для базы: $IB_CONNECTION"
        log "WARN" "Автозакрытие отключено. Закройте конфигуратор вручную или разрешите автозакрытие ключом --allow-close-designer"
        if [[ -t 0 ]]; then
            read -r -p "Закрыть конфигуратор автоматически сейчас? [y/N]: " close_now
            if [[ "$close_now" =~ ^[Yy]$ ]]; then
                close_1c_designer
                if [[ $? -ne 0 ]]; then
                    log "ERROR" "Не удалось закрыть конфигуратор. Выполнение прервано."
                    rm -f temp_changed_files.txt temp_changed_extensions.txt
                    exit 1
                fi
            else
                log "ERROR" "Загрузка прервана пользователем: активный конфигуратор не закрыт"
                rm -f temp_changed_files.txt temp_changed_extensions.txt
                exit 2
            fi
        else
            log "ERROR" "Загрузка прервана: активный конфигуратор не закрыт, а stdin неинтерактивный"
            log "ERROR" "Закройте конфигуратор вручную или запустите скрипт с --allow-close-designer"
            rm -f temp_changed_files.txt temp_changed_extensions.txt
            exit 2
        fi
    fi
fi

if [[ "$nothing_to_load" != "true" || "$UPDATE_DB" == "true" ]]; then
if [[ "$nothing_to_load" != "true" ]]; then
timing_mark "подготовка конфигуратора"

# Файловая ИБ слота: agent в группе www-data, но lock-файлы могут быть 640 после root batch.
if [[ "${PROJECT_OS}" == "linux" && "${IB_CONNECTION:-}" == *"/srv/ib"* ]]; then
    sudo -n chmod -R g+rwX /srv/ib 2>/dev/null || chmod -R g+rwX /srv/ib 2>/dev/null || true
fi

# Apache держит файловую ИБ (worker httpd.exe через wsisapi/wsap24):
#  - Linux-слот — и на LoadConfigFromFiles, и на UpdateDBCfg;
#  - движок ibcmd — на любом ОС: `config import` требует **монопольного**
#    доступа (в отличие от конфигуратора), поэтому стоп нужен ДО импорта
#    (иначе «Ошибка исключительной блокировки информационной базы»);
#  - Windows + конфигуратор — достаточно стопа перед UpdateDBCfg (блок ниже).
_slot_apache_was_running="false"
if { [[ "${PROJECT_OS}" == "linux" && "${IB_CONNECTION:-}" == *"/srv/ib"* ]] || [[ "$LOAD_ENGINE" == "ibcmd" ]]; } \
    && apache_is_running; then
    if ! apache_stop; then
        log "ERROR" "Stop Apache не удался — загрузка отменена"
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 30
    fi
    _slot_apache_was_running="true"
    trap 'log "WARN" "Аварийный выход — пробую поднять Apache"; apache_start || true; cleanup_temp_files; cleanup_changed_files_list' EXIT
fi
else
_slot_apache_was_running="false"
timing_mark "подготовка UpdateDB (загрузка файлов не требуется)"
fi

# Preflight по поддержке объектов
PARENT_CONFIG_BIN="$CONFIG_PATH_ABS/Ext/ParentConfigurations.bin"
PARENT_CONFIG_JSON="$repo_path/ParentConfigurations.json"
CONFIG_DUMP_INFO_PATH="$CONFIG_PATH_ABS/ConfigDumpInfo.xml"
# parent_config.py для preflight: явный PARENT_CONFIG_PY → скрипт потребителя → канон в kit.
if [[ -z "${PARENT_CONFIG_PY:-}" ]]; then
    if [[ -f "$repo_path/scripts/parent_config.py" ]]; then
        PARENT_CONFIG_PY="$repo_path/scripts/parent_config.py"
    else
        PARENT_CONFIG_PY="$_KIT_LOAD_DIR/parent_config.py"
    fi
fi

if [[ "$has_conf_changes" == "true" && -f "$PARENT_CONFIG_BIN" && "$FULL_RESYNC" != "true" ]]; then
    if [[ ! -f "$PARENT_CONFIG_PY" ]]; then
        log "WARN" "Preflight по поддержке пропущен: не найден parent_config.py"
        log "WARN" "Ожидался PARENT_CONFIG_PY, $repo_path/scripts/parent_config.py или $_KIT_LOAD_DIR/parent_config.py; либо запустите с -F (full-resync без preflight)"
        timing_mark "preflight поддержки (пропущен)"
    else
        PREFLIGHT_ARGS=(
            "$PARENT_CONFIG_PY"
            "preflight-load"
            "--config-dir" "$CONFIG_PATH_ABS"
            "--list-file" "$full_output_file"
            "--bin" "$PARENT_CONFIG_BIN"
            "--json" "$PARENT_CONFIG_JSON"
        )

        if [[ -f "$CONFIG_DUMP_INFO_PATH" ]]; then
            PREFLIGHT_ARGS+=("--configdump" "$CONFIG_DUMP_INFO_PATH")
        fi

        if [[ "$AUTO_UNSUPPORT_OBJECTS" == "true" ]]; then
            PREFLIGHT_ARGS+=("--auto-unsupport")
            log "INFO" "Включен режим автоматического снятия с поддержки (--auto-unsupport)"
        fi

        run_python "${PREFLIGHT_ARGS[@]}"
        preflight_exit_code=$?
        if [[ $preflight_exit_code -eq 20 ]]; then
            log "ERROR" "Загрузка остановлена: нужно снять объекты с поддержки или запустить скрипт с --auto-unsupport"
            rm -f temp_changed_files.txt
            exit 20
        elif [[ $preflight_exit_code -ne 0 ]]; then
            log "ERROR" "Preflight по поддержке завершился с ошибкой (код: $preflight_exit_code)"
            rm -f temp_changed_files.txt
            exit $preflight_exit_code
        fi
        timing_mark "preflight поддержки"
    fi
fi

if [[ "$has_conf_changes" == "true" && "$FULL_RESYNC" == "true" && -f "$PARENT_CONFIG_BIN" ]]; then
    log "WARN" "Full-resync: preflight по поддержке пропущен (грузим conf/ целиком, без list-file). Проверьте поддержку объектов вручную, если есть сомнения."
fi

# Преобразуем пути для командной строки 1С
mkdir -p "$repo_path/.tmp"
LOAD_LOG_FILE="$repo_path/.tmp/load-changed-files.log"
if [[ "${PROJECT_OS}" == "linux" ]]; then
    CONFIG_PATH_CMD="$CONFIG_PATH_ABS"
    LOAD_LOG_FILE_CMD="$LOAD_LOG_FILE"
else
    CONFIG_PATH_CMD=$(unix_to_win_path "$CONFIG_PATH_ABS")
    LOAD_LOG_FILE_CMD=$(unix_to_win_path "$LOAD_LOG_FILE")
fi

if [[ "$nothing_to_load" != "true" ]]; then
# Выполняем загрузку измененных файлов основной конфигурации (partial + listFile)
if [[ "$has_conf_changes" == "true" ]]; then
    apply_load_hide_files
    if [[ "$FULL_RESYNC" != "true" ]]; then
        if [[ "${PROJECT_OS}" == "linux" ]]; then
            OUTPUT_FILE_CMD="$full_output_file"
        else
            OUTPUT_FILE_CMD=$(unix_to_win_path "$full_output_file")
        fi
        if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
            ibcmd_import_conf "$CONFIG_PATH_CMD" "$CONFIG_PATH_ABS"
            load_exit_code=$?
        else
            LOAD_COMMAND="/LoadConfigFromFiles \"$CONFIG_PATH_CMD\" -listFile \"$OUTPUT_FILE_CMD\" -Format Hierarchical -partial -updateConfigDumpInfo"

            LOAD_COMMAND="$LOAD_COMMAND /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
            COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $LOAD_COMMAND"
            log "INFO" "Выполнение команды (основная конфигурация): $COMMAND"
            : > "$LOAD_LOG_FILE"
            run_1c_command "$COMMAND"
            load_exit_code=$?
        fi
    else
        # Full-resync: полная загрузка conf/ целиком, без -partial и -listFile.
        # Лечит «Неверный путь к данным»/«Неизвестный объект» после merge/rebase.
        if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
            # ibcmd: полный импорт конфигурации из XML — команда `import` (БЕЗ `files`),
            # каталог передаётся позиционным аргументом. Вариант `import files`
            # (только с `--base-dir=` и списком файлов) — это частичный импорт.
            # `--no-check` поддерживает только `import files`, поэтому здесь не передаём.
            fr_cmd="\"$IBCMD_CMD\" infobase config import $IBCMD_DB_ARGS $IBCMD_AUTH \"$CONFIG_PATH_CMD\" > \"$LOAD_LOG_FILE\" 2>&1"
            log "INFO" "Выполнение команды (ibcmd, полная загрузка conf): $fr_cmd"
            : > "$LOAD_LOG_FILE"
            run_1c_command "$fr_cmd"
            load_exit_code=$?
        else
            LOAD_COMMAND="/LoadConfigFromFiles \"$CONFIG_PATH_CMD\" -Format Hierarchical -updateConfigDumpInfo"
            LOAD_COMMAND="$LOAD_COMMAND /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
            COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $LOAD_COMMAND"
            log "INFO" "Выполнение команды (основная конфигурация, полная загрузка): $COMMAND"
            : > "$LOAD_LOG_FILE"
            run_1c_command "$COMMAND"
            load_exit_code=$?
        fi
    fi
    restore_load_hide_files
    if [[ -n "${_LOAD_HIDE_PREV_TRAP:-}" ]]; then
        eval "$_LOAD_HIDE_PREV_TRAP"
    fi
    if [[ $load_exit_code -ne 0 ]]; then
        log "ERROR" "Загрузка $CONFIG_PATH/ завершилась с ошибкой (код: $load_exit_code)"
        dump_load_log "$LOAD_LOG_FILE"
        diagnose_load_failure "$LOAD_LOG_FILE"
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit $load_exit_code
    fi
    if [[ "$FULL_RESYNC" == "true" ]]; then
        timing_mark "кэш conf после full-resync"
        build_conf_cache_seed_from_git_dirty temp_full_resync_cache_seed.txt
        if [[ -s temp_full_resync_cache_seed.txt ]]; then
            seed_count=$(wc -l < temp_full_resync_cache_seed.txt | tr -d ' ')
            log "INFO" "Full-resync: запись кэша хешей для $seed_count dirty conf путей (Module.bsl+Forms)"
            update_conf_files_cache temp_full_resync_cache_seed.txt "$repo_path" "$CONFIG_PATH_ABS"
        else
            log "INFO" "Full-resync: dirty conf нет — seed кэша хешей пропущен"
        fi
        rm -f temp_full_resync_cache_seed.txt
    else
        : > temp_cache_update_list.txt
        if [[ -s temp_changed_files.txt ]]; then
            cat temp_changed_files.txt >> temp_cache_update_list.txt
        fi
        if [[ -s temp_rewritten_form_modules.txt ]]; then
            cat temp_rewritten_form_modules.txt >> temp_cache_update_list.txt
        fi
        if [[ -s temp_cache_update_list.txt ]]; then
            awk '!seen[$0]++' temp_cache_update_list.txt > temp_cache_update_list.uniq \
                && mv temp_cache_update_list.uniq temp_cache_update_list.txt
            update_conf_files_cache temp_cache_update_list.txt "$repo_path" "$CONFIG_PATH_ABS"
        fi
        rm -f temp_cache_update_list.txt temp_cache_update_list.uniq
    fi
    timing_mark "загрузка conf (${file_count} файлов)"
fi
rm -f temp_rewritten_form_modules.txt

# Выполняем загрузку измененных расширений целиком (без listFile)
if [[ "$has_extension_changes" == "true" ]]; then
    while IFS= read -r extension_name; do
        [[ -z "$extension_name" ]] && continue
        extension_path="$EXTENSIONS_PATH_ABS/$extension_name"
        if [[ "${PROJECT_OS}" == "linux" ]]; then
            extension_path_cmd="$extension_path"
        else
            extension_path_cmd=$(unix_to_win_path "$extension_path")
        fi

        if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
            ibcmd_run "импорт расширения $extension_name" infobase config import $IBCMD_DB_ARGS $IBCMD_AUTH --extension="\"$extension_name\"" "\"$extension_path_cmd\""
            load_exit_code=$?
        else
            EXT_LOAD_COMMAND="/LoadConfigFromFiles \"$extension_path_cmd\" -Extension \"$extension_name\" -Format Hierarchical /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
            COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $EXT_LOAD_COMMAND"
            log "INFO" "Выполнение команды (расширение $extension_name): $COMMAND"
            : > "$LOAD_LOG_FILE"
            run_1c_command "$COMMAND"
            load_exit_code=$?
        fi
        if [[ $load_exit_code -ne 0 ]]; then
            log "ERROR" "Загрузка расширения $extension_name завершилась с ошибкой (код: $load_exit_code)"
            dump_load_log "$LOAD_LOG_FILE"
            diagnose_load_failure "$LOAD_LOG_FILE"
            rm -f temp_changed_files.txt temp_changed_extensions.txt
            exit $load_exit_code
        fi
    done < temp_changed_extensions.txt
    timing_mark "загрузка расширений (${ext_count} шт.)"
fi
fi

# Отдельный шаг обновления расширений в базе данных (после загрузки расширений)
if [[ "$UPDATE_DB" == "true" ]]; then
    warn_other_apache_services
    # Освобождаем lock файловой ИБ: останавливаем Apache (worker httpd.exe держит файл ИБ
    # через wsap24.dll). Без этого /UpdateDBCfg упрётся в «база занята».
    # trap гарантирует Start даже при сбое /UpdateDBCfg или Ctrl+C.
    apache_was_running="false"
    if apache_is_running; then
        apache_was_running="true"
        if ! apache_stop; then
            log "ERROR" "Stop Apache не удался — обновление БД отменено"
            rm -f temp_changed_files.txt temp_changed_extensions.txt
            exit 30
        fi
        trap 'log "WARN" "Аварийный выход — пробую поднять Apache"; apache_start || true; cleanup_temp_files; cleanup_changed_files_list' EXIT
    fi

    if [[ "$has_extension_changes" == "true" ]]; then
        while IFS= read -r extension_name; do
            [[ -z "$extension_name" ]] && continue
            if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
                ibcmd_run "apply расширения $extension_name" infobase config apply $IBCMD_DB_ARGS $IBCMD_AUTH --extension="\"$extension_name\"" --force
                update_db_exit_code=$?
            else
                EXT_DB_UPDATE_COMMAND="/UpdateDBCfg -Extension \"$extension_name\" /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
                COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $EXT_DB_UPDATE_COMMAND"
                log "INFO" "Выполнение команды (обновление расширения в БД $extension_name): $COMMAND"
                : > "$LOAD_LOG_FILE"
                run_1c_command "$COMMAND"
                update_db_exit_code=$?
            fi
            if [[ $update_db_exit_code -ne 0 ]]; then
                log "ERROR" "Обновление расширения $extension_name в БД завершилось с ошибкой (код: $update_db_exit_code)"
                dump_load_log "$LOAD_LOG_FILE"
                rm -f temp_changed_files.txt temp_changed_extensions.txt
                exit $update_db_exit_code
            fi
        done < temp_changed_extensions.txt
    fi

    # Отдельный шаг обновления основной конфигурации базы данных
    # ponytail: при -U/-C и кэше файлов (nothing_to_load) конфигуратор уже актуален — БД всё равно обновляем
    if [[ "$has_conf_changes" == "true" || "$nothing_to_load" == "true" ]]; then
        if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
            ibcmd_run "apply основной конфигурации" infobase config apply $IBCMD_DB_ARGS $IBCMD_AUTH --force
            update_db_exit_code=$?
        else
            DB_UPDATE_COMMAND="/UpdateDBCfg /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
            COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $DB_UPDATE_COMMAND"
            log "INFO" "Выполнение команды (обновление основной конфигурации БД): $COMMAND"
            : > "$LOAD_LOG_FILE"
            run_1c_command "$COMMAND"
            update_db_exit_code=$?
        fi
        if [[ $update_db_exit_code -ne 0 ]] && log_has_http_clients "$LOAD_LOG_FILE"; then
            if [[ "$UPDATE_DB_FORCE_SESSIONS" == "true" ]]; then
                log "WARN" "UpdateDB: обнаружены HTTP-клиенты (ИБ публикует другая служба Apache)."
                log "WARN" "Повторяю обновление с ПРИНУДИТЕЛЬНЫМ завершением сеансов: -Dynamic- -SessionTerminate force."
                log "WARN" "ВНИМАНИЕ: активные сеансы пользователей будут прерваны."
                if [[ "$LOAD_ENGINE" == "ibcmd" ]]; then
                    ibcmd_run "apply основной конфигурации (force sessions)" infobase config apply $IBCMD_DB_ARGS $IBCMD_AUTH --force --dynamic=disable --session-terminate=force
                    update_db_exit_code=$?
                else
                    DB_UPDATE_COMMAND="/UpdateDBCfg -Dynamic- -SessionTerminate force /Out \"$LOAD_LOG_FILE_CMD\" /DisableStartupDialogs"
                    COMMAND="\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION $IB_CONFIG_AUTH $DB_UPDATE_COMMAND"
                    log "INFO" "Выполнение команды (обновление основной конфигурации БД, force sessions): $COMMAND"
                    : > "$LOAD_LOG_FILE"
                    run_1c_command "$COMMAND"
                    update_db_exit_code=$?
                fi
                [[ $update_db_exit_code -eq 0 ]] && log "SUCCESS" "UpdateDB с принудительным завершением сеансов прошёл"
            else
                log "WARN" "UpdateDB упёрся в HTTP-клиенты, но UPDATE_DB_FORCE_SESSIONS=false."
                log "WARN" "Принудительное завершение сеансов выключено. Запустите с --force-sessions"
                log "WARN" "(или UPDATE_DB_FORCE_SESSIONS=true), чтобы повторить как -Dynamic- -SessionTerminate force."
            fi
        fi
        if [[ $update_db_exit_code -ne 0 ]]; then
            log "ERROR" "Обновление основной конфигурации базы данных завершилось с ошибкой (код: $update_db_exit_code)"
            dump_load_log "$LOAD_LOG_FILE"
            rm -f temp_changed_files.txt temp_changed_extensions.txt
            exit $update_db_exit_code
        fi
    fi

    # Файловая ИБ слота: load под root ломает владельца temp-файлов для www-data.
    # До apache_start — иначе Apache видит root-owned temp (узкое окно 500 на MCP/web).
    if [[ "${PROJECT_OS}" == "linux" && "${IB_CONNECTION:-}" == *"/srv/ib"* ]]; then
        log "INFO" "chown www-data на /srv/ib после UpdateDBCfg (до старта Apache)"
        sudo -n chown -R www-data:www-data /srv/ib 2>/dev/null \
            || chown -R www-data:www-data /srv/ib 2>/dev/null \
            || log "WARN" "chown /srv/ib не удался"
        sudo -n chmod -R g+rwX /srv/ib 2>/dev/null || chmod -R g+rwX /srv/ib 2>/dev/null || true
    fi

    # Успех — снимаем аварийный trap и явно поднимаем Apache, если останавливали
    if [[ "$apache_was_running" == "true" ]]; then
        cleanup_changed_files_list
        trap - EXIT
        if ! apache_start; then
            log "WARN" "Обновление БД прошло, но Apache не стартовал — запустите вручную"
        fi
    fi
    timing_mark "UpdateDBCfg"
fi

# Поднимаем Apache, если останавливали до LoadConfigFromFiles.
# При UPDATE_DB=true chown уже выполнен в блоке UpdateDBCfg; без UpdateDB — делаем здесь.
if [[ "$_slot_apache_was_running" == "true" ]]; then
    if [[ "$UPDATE_DB" != "true" && "${IB_CONNECTION:-}" == *"/srv/ib"* ]]; then
        log "INFO" "chown www-data на /srv/ib после load (до старта Apache)"
        sudo -n chown -R www-data:www-data /srv/ib 2>/dev/null \
            || chown -R www-data:www-data /srv/ib 2>/dev/null \
            || log "WARN" "chown /srv/ib не удался"
        sudo -n chmod -R g+rwX /srv/ib 2>/dev/null || chmod -R g+rwX /srv/ib 2>/dev/null || true
    fi
    cleanup_changed_files_list
    trap - EXIT
    if ! apache_start; then
        log "WARN" "Загрузка прошла, но Apache не стартовал — запустите вручную"
    fi
fi

if [[ "$UPDATE_DB" == "true" ]]; then
    if [[ "$nothing_to_load" == "true" ]]; then
        log "SUCCESS" "Обновление конфигурации базы данных завершено (загрузка файлов не требовалась)"
    else
        log "SUCCESS" "Загрузка и обновление конфигурации/расширений базы данных завершены успешно"
    fi
else
    log "SUCCESS" "Файлы успешно загружены в конфигурацию"
fi
fi

if [[ "$nothing_to_load" == "true" && "$UPDATE_DB" != "true" ]]; then
    log "SUCCESS" "Загрузка не требовалась (нечего грузить)"
fi

# Маркер: после загрузки или если committed-diff целиком закрыт кэшем хешей.
# При full-resync discover пропущен → COMMITTED_CHANGES_PRESENT=false, но маркер
# всё равно надо записать (ИБ только что полностью синхронизирована с диском).
if [[ -z "$LIST_FILE" \
      && "$SKIP_EXTENSIONS" != "true" \
      && ( "$COMMITTED_CHANGES_PRESENT" == "true" || "$FULL_RESYNC" == "true" ) ]]; then
    if [[ "$nothing_to_load" != "true" ]] \
        || { [[ "${conf_list_before_cache:-0}" -gt 0 ]] && [[ "$has_conf_changes" == "false" ]]; }; then
        write_loaded_marker "$(loaded_marker_path "$repo_path")"
    fi
fi
if [[ "$FULL_RESYNC" == "true" && "$SKIP_EXTENSIONS" == "true" ]]; then
    log "WARN" "Full-resync с --no-extensions: маркер HEAD не обновлён (нужен для последующей заливки cfe.xml)."
    log "WARN" "Дальше: ./load-changed-files.sh -U   # без --no-extensions; conf возьмёт кэш/маркер-fallback"
fi

# Опциональный запуск конфигуратора или клиента после загрузки
if [[ "$REOPEN_CLIENT_AFTER_LOAD" == "true" ]]; then
    THIN_CLIENT_CMD_UNIX=$(win_to_unix_path "$DESIGNER_CMD")
    THIN_CLIENT_CMD_UNIX="${THIN_CLIENT_CMD_UNIX%/*}/1cv8c.exe"
    THIN_CLIENT_CMD=$(unix_to_win_path "$THIN_CLIENT_CMD_UNIX")
    if [[ ! -f "$THIN_CLIENT_CMD_UNIX" && ! -f "$THIN_CLIENT_CMD" ]]; then
        log "ERROR" "Тонкий клиент 1С не найден: $THIN_CLIENT_CMD"
        log "ERROR" "Для режима -C нужен 1cv8c.exe рядом с DESIGNER_PATH. Толстый клиент 1cv8.exe не запускаю."
        rm -f temp_changed_files.txt temp_changed_extensions.txt
        exit 1
    fi
    log "INFO" "Запуск тонкого клиента 1С:Предприятие: $THIN_CLIENT_CMD ${CLIENT_LAUNCH_KEYS:-}"
    run_1c_command "\"$THIN_CLIENT_CMD\" ENTERPRISE $IB_CONNECTION ${CLIENT_LAUNCH_KEYS:-}" &
elif [[ "$REOPEN_DESIGNER_AFTER_LOAD" == "true" ]]; then
    log "INFO" "Запуск конфигуратора для проверки..."
    run_1c_command "\"$DESIGNER_CMD\" CONFIG $IB_CONNECTION" &
else
    log "INFO" "Перезапуск конфигуратора/клиента отключен"
fi

timing_mark "завершение"
update_db_label="нет"
[[ "$UPDATE_DB" == "true" ]] && update_db_label="да"
timing_summary "conf: ${file_count} файлов | расширения: ${ext_count} | UpdateDB: ${update_db_label}"

# Слот agent-container: load от root оставляет conf/ и git index root-only.
if [[ "${PROJECT_OS}" == "linux" && "${IB_CONNECTION:-}" == *"/srv/ib"* ]]; then
    log "INFO" "Права user agent на /work и /srv/src.git/worktrees"
    if chown -R agent:agent /work /srv/src.git/worktrees 2>/dev/null; then
        :
    else
        chmod -R a+rwX /work /srv/src.git/worktrees 2>/dev/null \
            || log "WARN" "не удалось выставить права для user agent"
    fi
fi

rm -f temp_changed_files.txt temp_changed_extensions.txt
