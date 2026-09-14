# Работа с Git

## Критически важные правила

**НИКОГДА НЕ ДЕЛАЙ КОММИТЫ БЕЗ ЯВНОГО РАЗРЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ!**

Это критически важно для контроля версий и избежания непреднамеренных коммитов.

## Kit публичный — OPSEC перед коммитом

Kit `1c-agent-kit` — публичный репозиторий. Перед коммитом в kit
проверь, что в staged нет внутренней инфраструктуры (IP, имена хостов,
пути сервера, кодовые имена, ремоуты, секреты). Канон, denylist,
allowlist плейсхолдеров и self-check:
[commit-hygiene.md](commit-hygiene.md). Если идентификатор уже в
истории — `git filter-repo --replace-text` + force-push **до** смены
видимости репо.

## Staging — только вручную

При коммите **не добавлять файлы в staging автоматически**. Работать только с тем, что пользователь уже staged сам.
Если ничего не staged — спросить пользователя, а не делать `git add` автоматически.

Проектные соглашения (маркеры change, semantic-summary и т.п.) — в дополнительной доке потребителя, если есть.

## Регистр путей (NTFS / APFS vs индекс Git)

На Windows и часто macOS ФС **не различает** `Foo.xml` и `foo.xml`.
Индекс Git **различает**: две строки пути = два объекта дерева, на диске
это один файл. Дамп 1С с кириллицей (`у`/`У`, `анализ`/`Анализ`) ломается
чаще латиницы.

`core.ignorecase=true` (дефолт Win) **не лечит**: merge/checkout всё равно
сравнивают строки пути. `false` на NTFS даёт фантомные untracked.

### Симптомы

- `error: The following untracked working tree files would be overwritten by merge`
  при «чистом» `git status`
- `git mv Old new` по регистру — no-op, статус пустой
- `git status` показывает `D` старого пути и `A` нового при том же blob
- на Linux/слоте файл «есть», на Windows «нет» (другая строка в дереве)

### Диагностика

```bash
git config --get core.ignorecase
git ls-files | grep -F "ИмяКакВИндексе"
git ls-tree -r HEAD --name-only | grep -i "фрагмент"
git ls-tree -r MERGE_HEAD --name-only | grep -i "фрагмент"
```

Дубли в **текущем** индексе (ASCII):

```bash
git ls-files | sort -f | uniq -di
```

Дубли с кириллицей (`casefold`):

```python
from collections import defaultdict
import subprocess

paths = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
groups = defaultdict(list)
for path in paths:
    groups[path.casefold()].append(path)
for variants in groups.values():
    unique = sorted(set(variants))
    if len(unique) > 1:
        print("\n".join(unique))
        print("---")
```

Сравнить два коммита: `git ls-tree -r <sha> --name-only` + тот же
`casefold`. Канон имени — строка в **том** дереве, куда мерджишь /
куда должны смотреть LoadConfigFromFiles и агенты.

### Починить только регистр (тот же blob, история не рвётся)

Windows/macOS: один `git mv` по регистру часто **ничего не делает**.
Два шага через промежуточное имя:

```bash
git mv "src/cf/Catalogs/староеИмя.xml" "src/cf/Catalogs/_case.tmp"
git mv "src/cf/Catalogs/_case.tmp" "src/cf/Catalogs/НовоеИмя.xml"
```

Каталог — так же (`git mv dir _case.tmp` → `git mv _case.tmp Dir`).

Индекс без движения файла на диске (уже лежит «как надо»):

```bash
info=$(git ls-files -s "путь/староеИмя.xml")
mode=$(echo "$info" | awk '{print $1}')
blob=$(echo "$info" | awk '{print $2}')
git rm --cached "путь/староеИмя.xml"
git update-index --add --cacheinfo "$mode,$blob,путь/НовоеИмя.xml"
```

Проверка: `git diff --cached --name-status -M` → `R100`, не пара `D`+`A`.
Коммит — только с явного разрешения. `git log --follow -- <новый путь>`
продолжает историю; без `--follow` лог обрывается на переименовании.

### Merge: HEAD и входящий коммит разошлись только регистром

1. Выровнять индекс и диск под канон **входящего** дерева (рецепт выше).
2. Закоммитить выравнивание (явное согласие).
3. Повторить `git merge`.

Не удалять рабочее дерево «чтобы merge пошёл», если в папке есть
незакоммиченные правки.

Если **в одном** коммите поставщика два пути на один blob
(`Foo` и `foo` в одном `ls-tree`) — перед merge в индекс нужно
добавить **вторую** строку тем же `cacheinfo` (тот же `mode`/`blob`).
Иначе Git считает вторую строку untracked и снова `would be overwritten`.

Потребитель с мерджем типовой может держать свои скрипты (пилот ORG:
`scripts/fix-case-merge.sh`, ловушка в `docs/ai/merge-vendor-pitfalls.md`).
В kit скриптов нет — канон агента = диагностика + `git mv` в два шага /
`update-index --cacheinfo`.
