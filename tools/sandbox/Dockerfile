FROM python:3.11-slim

# Установка системных зависимостей, Node.js и Java (для bsl-language-server).
# Node.js ставим из репозитория дистрибутива (без удалённых install-скриптов).
# Если нужен именно Node 20, оператор сам выбирает способ установки:
#   https://github.com/nodesource/distributions
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    default-jre \
    ripgrep \
    nodejs \
    npm \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Установка глобальных пакетов npm (вне /workspace — не перекрывается bind-mount репо)
RUN npm install -g typescript ts-node @fission-ai/openspec@1.2.0

# RTK (Rust Token Killer) — Linux-бинарник. Kit не скачивает и не исполняет
# удалённые install-скрипты; оператор ставит rtk сам, если нужен:
#   https://github.com/rtk-ai/rtk

ENV PATH="/usr/local/bin:/root/.local/bin:${PATH}"

# Python-зависимости cc-1c-skills (cfe-validate, meta-*, web-* и др.)
COPY requirements.txt /tmp/sandbox-requirements.txt
RUN pip install --no-cache-dir -r /tmp/sandbox-requirements.txt && rm /tmp/sandbox-requirements.txt

# Playwright + Chromium (Linux) для web-test в песочнице (только headless).
# JS-пакет ставим в /node_modules: ESM-резолюция из /workspace/... доходит до
# корня (/node_modules), а NODE_PATH для ESM не работает. Браузеры — в
# /ms-playwright (вне node_modules, не зависят от bind-mount хоста с Windows).
# Версия синхронна с package.json (корень + scripts/): playwright 1.50.0, без каретки.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
# --with-deps не годится: на debian тянет несуществующие ubuntu-шрифты
# (ttf-unifont). Ставим runtime-libs Chromium вручную (имена debian bookworm),
# затем `playwright install chromium` без deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libdrm2 libxkbcommon0 libatspi2.0-0 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libgbm1 libxcb1 libxext6 libx11-6 \
    libpango-1.0-0 libcairo2 libasound2 \
    && npm install -g playwright@1.50.0 \
    && mkdir -p /node_modules \
    && ln -s /usr/lib/node_modules/playwright /node_modules/playwright \
    && ln -s /usr/lib/node_modules/playwright-core /node_modules/playwright-core \
    && playwright install chromium \
    && npm cache clean --force \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Настройка рабочей директории
WORKDIR /workspace

# Поддержание жизни контейнера в фоновом режиме
CMD ["tail", "-f", "/dev/null"]
