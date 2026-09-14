#!/usr/bin/env bash
# Прямой JSON-RPC к MCP-серверу 1С (минует кэш инструментов IDE).
# Зависимости: curl, jq. См. tools/mcp-call/README.md
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_TOOL_ERROR=1
readonly EXIT_JSONRPC_ERROR=2
readonly EXIT_NETWORK_ERROR=3
readonly EXIT_ARGS_ERROR=4

readonly DEFAULT_SERVER_KEY="dev_dt"
readonly DEFAULT_TIMEOUT=60
readonly RPC_PATH="/rpc"

LIST=false
SCHEMA=""
SERVER="$DEFAULT_SERVER_KEY"
URL=""
CONFIG=""
TIMEOUT="$DEFAULT_TIMEOUT"
REQUEST_ID=1
FAIL_ON_SUCCESS_FALSE=true
TOOL=""
ARGS_JSON=""
# Заголовки из CLI (--header / --bearer); мержатся после resolve_endpoint.
CLI_HEADERS_LINES=()

eprint() { printf '%s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Использование: bash tools/mcp-call/mcp-call.sh [опции] [TOOL [ARGS_JSON]]

Опции:
  --list                      список инструментов (tools/list)
  --schema TOOL               inputSchema инструмента
  --server KEY                ключ в .cursor/mcp.json / .mcp.json (по умолчанию: dev_dt)
  --url URL                   прямой URL (заголовки из mcp.json не читаются)
  --header "Name: value"      доп. HTTP-заголовок (можно несколько раз; с --url тоже)
  --bearer TOKEN              Authorization: Bearer TOKEN (удобно с --url)
  --config PATH               явный путь к mcp.json
  --timeout SEC               таймаут curl (по умолчанию: 60)
  --id N                      JSON-RPC id (по умолчанию: 1)
  --no-fail-on-success-false  не выходить 1 при success:false в теле tool
  -h, --help                  эта справка

ARGS_JSON — JSON-объект или @path/to/file.json (UTF-8).

Слоты agent-container с хоста (без записи в .cursor/mcp.json):
  bash docker/agent-container/mcp-call-slot.sh N version_get
  см. docs/ai/mcp-server.md § «MCP agent-слотов с хоста».
EOF
}

require_cmds() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if ((${#missing[@]} > 0)); then
        eprint "mcp-call: нужны: ${missing[*]}"
        return "$EXIT_ARGS_ERROR"
    fi
    return 0
}

default_config_path() {
    if [[ -f ".cursor/mcp.json" ]]; then
        printf '%s' ".cursor/mcp.json"
    elif [[ -f ".mcp.json" ]]; then
        printf '%s' ".mcp.json"
    else
        printf '%s' ".mcp.json"
    fi
}

normalize_rpc_url() {
    local base="${1%/}"
    if [[ "$base" == *"$RPC_PATH" ]]; then
        printf '%s' "$base"
    else
        printf '%s%s' "$base" "$RPC_PATH"
    fi
}

url_for_sandbox_if_needed() {
    local url="$1"
    # Agent-slot: /.dockerenv есть, но MCP — localhost самого контейнера, не хоста.
    # AGENT_SLOT=true выставляется в ENV образа агента.
    if [[ ! -f "/.dockerenv" || "${AGENT_SLOT:-}" == "true" ]]; then
        printf '%s' "$url"
        return 0
    fi
    if [[ "$url" == *"127.0.0.1"* ]]; then
        printf '%s' "${url/127.0.0.1/host.docker.internal}"
        return 0
    fi
    if [[ "$url" == *"localhost"* ]]; then
        printf '%s' "${url/localhost/host.docker.internal}"
        return 0
    fi
    printf '%s' "$url"
}

# Заполняет глобалы ENDPOINT_URL и EXTRA_HEADERS_LINES (массив "Key: value").
# Не печатает результат в stdout, чтобы вызов без command-substitution
# не терял изменения массива в subshell.
resolve_endpoint() {
    ENDPOINT_URL=""
    EXTRA_HEADERS_LINES=()

    if [[ -n "$URL" ]]; then
        ENDPOINT_URL="$(normalize_rpc_url "$(url_for_sandbox_if_needed "$URL")")"
        return 0
    fi

    local config_path="${CONFIG:-$(default_config_path)}"
    if [[ ! -f "$config_path" ]]; then
        eprint "Ошибка конфигурации: не найден файл MCP: $config_path"
        return 1
    fi

    local base_url
    if ! base_url=$(jq -r --arg s "$SERVER" '.mcpServers[$s].url // empty' "$config_path"); then
        eprint "Ошибка конфигурации: невалидный JSON в $config_path"
        return 1
    fi
    if [[ -z "$base_url" || "$base_url" == "null" ]]; then
        local keys
        keys=$(jq -r '.mcpServers | keys | join(", ")' "$config_path" 2>/dev/null || echo "(нет)")
        eprint "Ошибка конфигурации: сервер '$SERVER' не найден в $config_path. Доступные: $keys"
        return 1
    fi

    mapfile -t EXTRA_HEADERS_LINES < <(
        jq -r --arg s "$SERVER" '
            (.mcpServers[$s].headers // {}) | to_entries[]
            | select(.value != null) | "\(.key): \(.value)"
        ' "$config_path" | tr -d '\r'
    )

    ENDPOINT_URL="$(normalize_rpc_url "$(url_for_sandbox_if_needed "$base_url")")"
    return 0
}

# $1 url, $2 путь к JSON-файлу тела → stdout: response body
post_jsonrpc_file() {
    local url="$1"
    local payload_file="$2"
    local -a curl_args=(
        -sS
        -X POST
        "$url"
        --data-binary "@${payload_file}"
        -H "Content-Type: application/json; charset=utf-8"
        -H "Accept: application/json"
        --max-time "$TIMEOUT"
        -w $'\n%{http_code}'
    )
    local hdr
    for hdr in "${EXTRA_HEADERS_LINES[@]:-}"; do
        hdr="${hdr//$'\r'/}"
        [[ -n "$hdr" ]] && curl_args+=(-H "$hdr")
    done

    local raw http_code body
    if ! raw=$(curl "${curl_args[@]}" 2>&1); then
        eprint "Сетевая ошибка $url: $raw"
        return "$EXIT_NETWORK_ERROR"
    fi

    http_code="${raw##*$'\n'}"
    body="${raw%$'\n'*}"

    if [[ "$http_code" != "200" ]]; then
        eprint "HTTP $http_code при обращении к $url"
        [[ -n "$body" ]] && eprint "$body"
        return "$EXIT_NETWORK_ERROR"
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
        eprint "Не удалось разобрать ответ сервера как JSON"
        eprint "Сырой ответ: ${body:0:500}"
        return "$EXIT_NETWORK_ERROR"
    fi

    printf '%s' "$body"
    return 0
}

# $1 url, $2 json payload (строка) → stdout: response body
# curl -d "$payload" на Windows/WSL ломает UTF-8 (кириллица в BSL для execute_code).
post_jsonrpc() {
    local url="$1"
    local payload="$2"
    local payload_file
    payload_file="$(mktemp)"
    printf '%s' "$payload" >"$payload_file"
    local rc=0
    post_jsonrpc_file "$url" "$payload_file" || rc=$?
    rm -f "$payload_file"
    return "$rc"
}

handle_jsonrpc_response() {
    local response="$1"
    if jq -e '.error' >/dev/null 2>&1 <<<"$response"; then
        local code msg data
        code=$(jq -r '.error.code // -32603' <<<"$response")
        msg=$(jq -r '.error.message // "Неизвестная ошибка"' <<<"$response")
        eprint "JSON-RPC error $code: $msg"
        if jq -e '.error.data' >/dev/null 2>&1 <<<"$response"; then
            jq -c '.error.data' <<<"$response" >&2
        fi
        return "$EXIT_JSONRPC_ERROR"
    fi
    if ! jq -e '.result' >/dev/null 2>&1 <<<"$response"; then
        eprint "JSON-RPC error -32603: Ответ без поля result"
        return "$EXIT_JSONRPC_ERROR"
    fi
    printf '%s' "$response"
    return 0
}

op_list() {
    local url="$1"
    local payload
    payload=$(jq -n --argjson id "$REQUEST_ID" '{jsonrpc:"2.0", id:$id, method:"tools/list", params:{}}')
    local response rc
    response=$(post_jsonrpc "$url" "$payload") || return $?
    response=$(handle_jsonrpc_response "$response") || return $?

    local count
    count=$(jq '.result.tools | length' <<<"$response")
    if [[ "$count" == "0" ]]; then
        echo "(инструменты не найдены)"
        return "$EXIT_OK"
    fi
    jq -r '.result.tools[] | "\(.name)\t\((.description // "") | split("\n") | .[0] // "")"' <<<"$response"
    return "$EXIT_OK"
}

op_schema() {
    local url="$1"
    local tool_name="$2"
    local payload
    payload=$(jq -n --argjson id "$REQUEST_ID" '{jsonrpc:"2.0", id:$id, method:"tools/list", params:{}}')
    local response rc
    response=$(post_jsonrpc "$url" "$payload") || return $?
    response=$(handle_jsonrpc_response "$response") || return $?

    if jq -e --arg n "$tool_name" '.result.tools[] | select(.name == $n)' >/dev/null 2>&1 <<<"$response"; then
        jq --arg n "$tool_name" '.result.tools[] | select(.name == $n) | .inputSchema // {}' <<<"$response"
        return "$EXIT_OK"
    fi
    eprint "Инструмент '$tool_name' не найден на сервере"
    return "$EXIT_ARGS_ERROR"
}

# Валидирует ARGS_JSON (@file или inline) → пишет JSON-объект в $1 (путь).
# Крупный payload (extension_load_post + .cfe base64) нельзя гонять через
# bash <<< / jq --argjson: ARG_MAX → «Argument list too long».
write_tool_arguments_file() {
    local out_file="$1"
    local raw="${2:-}"
    if [[ -z "$raw" ]]; then
        printf '%s\n' '{}' >"$out_file"
        return 0
    fi
    if [[ "$raw" == @* ]]; then
        local path="${raw:1}"
        if [[ ! -f "$path" ]]; then
            eprint "Файл аргументов не найден: $path"
            return 1
        fi
        if ! jq -e 'type == "object"' "$path" >/dev/null 2>&1; then
            eprint "Аргументы инструмента должны быть JSON-объектом: $path"
            return 1
        fi
        # Копия: jq -c нормализует; без загрузки всего в bash-переменную.
        if ! jq -c . "$path" >"$out_file"; then
            eprint "Невалидный JSON в аргументах: $path"
            return 1
        fi
        return 0
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw"; then
        eprint "Аргументы инструмента должны быть JSON-объектом"
        return 1
    fi
    printf '%s' "$raw" >"$out_file"
    return 0
}

tool_body_implies_error() {
    local parsed="$1"
    if [[ "$FAIL_ON_SUCCESS_FALSE" != true ]]; then
        return 1
    fi
    jq -e 'has("success") and .success == false' >/dev/null 2>&1 <<<"$parsed"
}

op_call() {
    local url="$1"
    local tool_name="$2"
    local args_raw="${3:-}"

    local args_file payload_file
    args_file="$(mktemp)"
    payload_file="$(mktemp)"
    if ! write_tool_arguments_file "$args_file" "$args_raw"; then
        rm -f "$args_file" "$payload_file"
        return "$EXIT_ARGS_ERROR"
    fi
    # --slurpfile: аргументы из файла, не через argv (ARG_MAX на .cfe base64).
    if ! jq -n \
        --argjson id "$REQUEST_ID" \
        --arg name "$tool_name" \
        --slurpfile args "$args_file" \
        '{jsonrpc:"2.0", id:$id, method:"tools/call", params:{name:$name, arguments:$args[0]}}' \
        >"$payload_file"; then
        rm -f "$args_file" "$payload_file"
        eprint "Не удалось собрать JSON-RPC payload"
        return "$EXIT_ARGS_ERROR"
    fi
    rm -f "$args_file"

    local response
    response=$(post_jsonrpc_file "$url" "$payload_file") || {
        local rc=$?
        rm -f "$payload_file"
        return "$rc"
    }
    rm -f "$payload_file"
    response=$(handle_jsonrpc_response "$response") || return $?

    local is_error text parsed=null
    is_error=$(jq -r '.result.isError // false' <<<"$response")
    text=$(jq -r '.result.content[0].text // empty' <<<"$response")

    if [[ -z "$text" ]]; then
        jq '.result' <<<"$response"
        [[ "$is_error" == "true" ]] && return "$EXIT_TOOL_ERROR"
        return "$EXIT_OK"
    fi

    if jq -e . >/dev/null 2>&1 <<<"$text"; then
        parsed="$text"
        jq . <<<"$parsed"
    else
        printf '%s\n' "$text"
    fi

    if [[ "$is_error" == "true" ]]; then
        return "$EXIT_TOOL_ERROR"
    fi
    if [[ "$parsed" != "null" ]] && tool_body_implies_error "$parsed"; then
        return "$EXIT_TOOL_ERROR"
    fi
    return "$EXIT_OK"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                LIST=true
                shift
                ;;
            --schema)
                [[ $# -lt 2 ]] && { eprint "--schema требует имя инструмента"; exit "$EXIT_ARGS_ERROR"; }
                SCHEMA="$2"
                shift 2
                ;;
            --server)
                [[ $# -lt 2 ]] && { eprint "--server требует ключ"; exit "$EXIT_ARGS_ERROR"; }
                SERVER="$2"
                shift 2
                ;;
            --url)
                [[ $# -lt 2 ]] && { eprint "--url требует адрес"; exit "$EXIT_ARGS_ERROR"; }
                URL="$2"
                shift 2
                ;;
            --header)
                [[ $# -lt 2 ]] && { eprint "--header требует \"Name: value\""; exit "$EXIT_ARGS_ERROR"; }
                CLI_HEADERS_LINES+=("$2")
                shift 2
                ;;
            --bearer)
                [[ $# -lt 2 ]] && { eprint "--bearer требует JWT"; exit "$EXIT_ARGS_ERROR"; }
                CLI_HEADERS_LINES+=("Authorization: Bearer $2")
                shift 2
                ;;
            --config)
                [[ $# -lt 2 ]] && { eprint "--config требует путь"; exit "$EXIT_ARGS_ERROR"; }
                CONFIG="$2"
                shift 2
                ;;
            --timeout)
                [[ $# -lt 2 ]] && { eprint "--timeout требует число"; exit "$EXIT_ARGS_ERROR"; }
                TIMEOUT="$2"
                shift 2
                ;;
            --id)
                [[ $# -lt 2 ]] && { eprint "--id требует число"; exit "$EXIT_ARGS_ERROR"; }
                REQUEST_ID="$2"
                shift 2
                ;;
            --no-fail-on-success-false)
                FAIL_ON_SUCCESS_FALSE=false
                shift
                ;;
            -h | --help)
                usage
                exit "$EXIT_OK"
                ;;
            --)
                shift
                TOOL="${1:-}"
                ARGS_JSON="${2:-}"
                break
                ;;
            -*)
                eprint "Неизвестная опция: $1"
                exit "$EXIT_ARGS_ERROR"
                ;;
            *)
                if [[ -z "$TOOL" ]]; then
                    TOOL="$1"
                elif [[ -z "$ARGS_JSON" ]]; then
                    ARGS_JSON="$1"
                else
                    eprint "Лишний аргумент: $1"
                    exit "$EXIT_ARGS_ERROR"
                fi
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if ! require_cmds; then
        exit "$EXIT_ARGS_ERROR"
    fi

    if [[ "$LIST" != true && -z "$SCHEMA" && -z "$TOOL" ]]; then
        usage >&2
        eprint "Укажите имя инструмента, либо --list / --schema TOOL."
        exit "$EXIT_ARGS_ERROR"
    fi

    if ! resolve_endpoint; then
        exit "$EXIT_ARGS_ERROR"
    fi
    local endpoint="$ENDPOINT_URL"
    local cli_hdr
    for cli_hdr in "${CLI_HEADERS_LINES[@]:-}"; do
        cli_hdr="${cli_hdr//$'\r'/}"
        [[ -n "$cli_hdr" ]] && EXTRA_HEADERS_LINES+=("$cli_hdr")
    done

    if [[ "$LIST" == true ]]; then
        op_list "$endpoint"
        exit $?
    fi
    if [[ -n "$SCHEMA" ]]; then
        op_schema "$endpoint" "$SCHEMA"
        exit $?
    fi
    op_call "$endpoint" "$TOOL" "$ARGS_JSON"
    exit $?
}

main "$@"
