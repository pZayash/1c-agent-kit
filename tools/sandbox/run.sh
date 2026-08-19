#!/bin/bash
# Обертка для выполнения команд внутри изолированного контейнера agent-sandbox.
#
# Agent-slot: Docker недоступен — инструменты установлены нативно, запускаем напрямую.
# Хост (Windows/Linux с Docker): прозрачный запуск в sandbox-контейнере.
# Per-workspace: у каждого репозитория свой контейнер agent-sandbox-<id>.
if ! command -v docker >/dev/null 2>&1; then
    # ponytail: в agent-slot часто только python3, без symlink python
    if [ "${1:-}" = "python" ] && ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        shift
        set -- python3 "$@"
    fi
    exec "$@"
fi

LEGACY_CONTAINER_NAME="agent-sandbox"
IMAGE_NAME="agent-sandbox-image"

# Определяем абсолютные пути
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "${SANDBOX_DIR}/../.." && pwd)"

# MCP dev_dt на хосте (127.0.0.1) — из контейнера через host.docker.internal
SANDBOX_EXTRA_HOSTS=(--add-host=host.docker.internal:host-gateway)

_normalize_workspace_path() {
    local p="${1%/}"
    p="${p//\\//}"
    while [[ "${p}" == //* ]]; do
        p="/${p#//}"
    done
    if [[ "${p}" =~ ^/([A-Za-z])(/.*)?$ ]]; then
        p="/${BASH_REMATCH[1],}${BASH_REMATCH[2]:-}"
    elif [[ "${p}" =~ ^([A-Za-z]):(/.*)?$ ]]; then
        p="/${BASH_REMATCH[1],}${BASH_REMATCH[2]:-}"
    fi
    printf '%s' "${p,,}"
}

_workspace_container_id() {
    local norm
    norm="$(_normalize_workspace_path "$1")"
    printf '%s' "${norm}" | sha256sum | awk '{print substr($1, 1, 12)}'
}

CONTAINER_NAME="${LEGACY_CONTAINER_NAME}-$(_workspace_container_id "${WORKSPACE_DIR}")"

_container_has_mcp_host() {
    docker inspect "${CONTAINER_NAME}" --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' 2>/dev/null \
        | grep -q 'host.docker.internal'
}

_mounted_workspace() {
    docker inspect "${CONTAINER_NAME}" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null
}

_mount_matches_workspace() {
    local mounted expected
    mounted="$(_mounted_workspace)"
    [[ -n "${mounted}" ]] || return 1
    expected="$(_normalize_workspace_path "${WORKSPACE_DIR}")"
    [[ "$(_normalize_workspace_path "${mounted}")" == "${expected}" ]]
}

_remove_legacy_global_container() {
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${LEGACY_CONTAINER_NAME}\$"; then
        echo "Удаляем устаревший глобальный контейнер ${LEGACY_CONTAINER_NAME} (изоляция per-workspace)..."
        docker rm -f "${LEGACY_CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
}

_recreate_container() {
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    echo "Сборка и запуск контейнера ${CONTAINER_NAME} → ${WORKSPACE_DIR} (host.docker.internal → хост)..."
    docker build -t "${IMAGE_NAME}" "${SANDBOX_DIR}"
    docker run -d --name "${CONTAINER_NAME}" \
        "${SANDBOX_EXTRA_HOSTS[@]}" \
        -v "/${WORKSPACE_DIR}:/workspace" \
        "${IMAGE_NAME}" > /dev/null
}

_remove_legacy_global_container

# Проверяем, запущен ли контейнер
if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
        if ! _container_has_mcp_host || ! _mount_matches_workspace; then
            echo "Контейнер ${CONTAINER_NAME} устарел (mount/MCP) — пересоздаём..."
            _recreate_container
        else
            echo "Запуск контейнера ${CONTAINER_NAME}..."
            docker start "${CONTAINER_NAME}" > /dev/null
        fi
    else
        _recreate_container
    fi
elif ! _container_has_mcp_host || ! _mount_matches_workspace; then
    echo "Контейнер ${CONTAINER_NAME} без host.docker.internal или с неверным mount — пересоздаём..."
    docker rm -f "${CONTAINER_NAME}" > /dev/null
    _recreate_container
fi

# Проброс WEB_TEST_* из .env в контейнер: node-runner web-test читает env напрямую
# (без python-dotenv). Python-скрипты грузят .env сами — лишние -e им не мешают.
SANDBOX_ENV_ARGS=()
ENV_FILE="${WORKSPACE_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r _line; do
        SANDBOX_ENV_ARGS+=(-e "${_line}")
    done < <(grep -E '^(WEB_TEST_|B24_)[A-Z_]+=' "${ENV_FILE}")
fi
# В контейнере нет дисплея — web-test только headless (перекрывает значение из .env)
SANDBOX_ENV_ARGS+=(-e WEB_TEST_HEADLESS=1)

# Выполняем переданную команду (WORKDIR образа = /workspace; .env — через python-dotenv в скриптах)
# Git Bash/MSYS: не конвертировать /workspace → C:/Program Files/Git/workspace
MSYS_NO_PATHCONV=1 docker exec -w /workspace "${SANDBOX_ENV_ARGS[@]}" "${CONTAINER_NAME}" "$@"
