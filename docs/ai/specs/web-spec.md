# Веб-публикация 1С — техническая спецификация

Описание артефактов, необходимых для публикации информационной базы 1С через Apache HTTP Server.

## default.vrd

Дескриптор виртуального ресурса. XML-файл, описывающий подключение к информационной базе.

### Формат

```xml
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
       xmlns:xs="http://www.w3.org/2001/XMLSchema"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       base="/appname"
       ib="connection-string"
       enableStandardOdata="true">
    <ws pointEnableCommon="true"/>
    <httpServices publishByDefault="true"/>
</point>
```

### Атрибут `base`

URL-путь публикации. Должен начинаться с `/`, совпадает с `Alias` в httpd.conf.

### Атрибут `ib`

Строка подключения к информационной базе.

**Файловая база:**
```
File=&quot;C:\Bases\MyDB&quot;;
```

**Серверная база:**
```
Srvr=&quot;server01&quot;;Ref=&quot;MyDB&quot;;
```

**С авторизацией:**
```
File=&quot;C:\Bases\MyDB&quot;;Usr=&quot;Admin&quot;;Pwd=&quot;123&quot;;
```

> Кавычки внутри значения `ib` экранируются как `&quot;` (XML-сущность).

### Дочерние элементы

#### `enableStandardOdata` (атрибут `<point>`)
Стандартный OData-интерфейс платформы. `enableStandardOdata="true"` открывает REST-доступ ко всем объектам.
URL: `/{AppName}/odata/standard.odata`

#### `<ws>`
Публикация SOAP web-сервисов. `pointEnableCommon="true"` публикует все сервисы из конфигурации.
URL: `/{AppName}/ws/{WebServiceName}?wsdl`

#### `<httpServices>`
Публикация HTTP-сервисов. `publishByDefault="true"` публикует все сервисы из конфигурации.
URL: `/{AppName}/hs/{RootUrl}/...`

#### JWT и `<accessTokenAuthentication>`

Аутентификация по JWT (RFC 7519) для веб-/тонкого клиента настраивается в **`default.vrd`**,
дочерний элемент `<point>` (или для отдельных HTTP-сервисов — см. руководство
администратора, приложение 3). В Apache в `httpd.conf` — только блок публикации
(`ManagedApplicationDescriptor` на каталог с `default.vrd`).

- Описание элемента: [1ci — accessTokenAuthentication](https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.5.1_Administrator_Guide/Appendix_3._Description_and_location_of_internal_files/3.21._default.vrd/3.21.14.__accessTokenAuthentication_/?language=en).
- `issuer/@keyInformation` в vrd — **Base64**-строка; JWT HS256 подписывается по
  **UTF-8 этой же строки** (не по «сырому» секрету).
- Генератор JWT / патч публикации — скрипты потребителя, если есть.

**`default.vrd`:** не оставлять пустые
`<accessTokenRecepientName/>` / `<issuers/>` — XDTO падает. JWT-фрагмент —
только у публикаций под платформу, которая его понимает (схема 8.5+).

### Расположение

`{ApachePath}/publish/{AppName}/default.vrd`

## httpd.conf для 1С

### LoadModule

Apache загружает модуль расширения 1С:

```apache
LoadModule _1cws_module "C:/Program Files/1cv8/{PLATFORM_BUILD}/bin/wsap24.dll"
```

`{PLATFORM_BUILD}` — ключ в `.env.example` потребителя.

- Модуль `wsap24.dll` — 64-разрядный, требует x64-версию Apache
- Путь использует forward slashes
- **Один `httpd` = один `wsap24.dll`.** Нельзя одновременно держать
  две ветки платформы (например 8.3.18 и 8.5) в одном Apache.

### Две платформы на одной машине

| Роль | Где |
| --- | --- |
| Apache `LoadModule` | один `wsap24.dll` в `httpd.conf` |
| Designer / legacy | может быть другая ветка (`DESIGNER_PATH`) |
| Публикации другой ветки | **другой** Apache / порт |

JWT (`issuers` / `keyInformation`) — схема 8.5; модуль 8.3.18 такой
`default.vrd` не парсит → HTTP 500 «Ошибка при разборе дескриптора
виртуальных ресурсов» / XDTO `issuers`.

**Запрещено:** переключать `LoadModule` вручную «под текущий Designer» —
сломаете JWT/MCP на публикации, заточенной под другую ветку.

### Listen

```apache
Listen 8081
```

Порт для веб-клиента. По умолчанию `8081` (стандартный `80` может быть занят).

### Alias + Directory

Для каждой публикации добавляется блок:

```apache
Alias "/appname" "C:/path/to/apache/publish/appname"
<Directory "C:/path/to/apache/publish/appname">
    AllowOverride All
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "C:/path/to/apache/publish/appname/default.vrd"
</Directory>
```

- `Alias` — URL-путь → физический каталог
- `SetHandler 1c-application` — делегирование обработки запросов модулю wsap24
- `ManagedApplicationDescriptor` — путь к default.vrd

### Маркерный подход

Скрипты используют маркерные комментарии для идемпотентного управления блоками:

```apache
# --- 1C: global ---
Listen 8081
LoadModule _1cws_module "C:/Program Files/1cv8/{PLATFORM_BUILD}/bin/wsap24.dll"
# --- End: global ---

# --- 1C Publication: mydb ---
Alias "/mydb" "C:/tools/apache24/publish/mydb"
<Directory "C:/tools/apache24/publish/mydb">
    AllowOverride All
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "C:/tools/apache24/publish/mydb/default.vrd"
</Directory>
# --- End: mydb ---
```

При повторном запуске блок между маркерами заменяется целиком.

## wsap24.dll

Модуль расширения Apache для 1С:Предприятие.

- Расположение: `{V8Path}/bin/wsap24.dll`
- Архитектура: x64 (Apache тоже должен быть x64)
- Имя модуля: `_1cws_module`
- В `LoadModule` — та же ветка платформы, что и JWT в `default.vrd` (если JWT есть).

## Portable Apache

### Дистрибутив

Apache Lounge — Windows-сборка Apache HTTP Server (x64):
- Сайт: `https://www.apachelounge.com/download/`
- Прямая ссылка (2.4.62, VS17): `https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-240904-win64-VS17.zip`
- Внутри ZIP: каталог `Apache24/` с полной структурой

### Структура после установки

```
tools/apache24/
├── bin/
│   ├── httpd.exe
│   └── ...
├── conf/
│   ├── httpd.conf
│   └── ...
├── logs/
│   ├── error.log
│   └── access.log
├── modules/
│   └── ...
└── publish/
    └── {appname}/
        └── default.vrd
```

### Пост-распаковка

1. `Expand-Archive` распаковывает ZIP во временный каталог
2. Содержимое `Apache24/` перемещается в `{ApachePath}`
3. В `httpd.conf` патчится `ServerRoot`:

```apache
Define SRVROOT "C:/path/to/apache24"
ServerRoot "${SRVROOT}"
```

Путь `SRVROOT` — абсолютный, с forward slashes.

### Запуск

```
httpd.exe                  # foreground (для отладки)
httpd.exe -k start         # фоновый запуск (не работает без установки сервиса)
```

> Portable Apache запускается напрямую через `Start-Process httpd.exe` без установки Windows-сервиса.

### Остановка

```
httpd.exe -k stop           # graceful shutdown (требует сервис)
Stop-Process -Name httpd    # принудительная остановка (portable)
```

### Перезагрузка

```
httpd.exe -k restart        # graceful restart (требует сервис)
```

Для portable варианта: остановка + запуск.
