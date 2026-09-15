## Harness (kit)

Общие правила, skills и tools — submodule [harness/](harness/README.md).
Диагностика: `bash harness/scripts/kit-doctor.sh .`
Файлы kit не коммитим как обычные файлы проекта; изменения в kit — promote
через skill `harness-promote` (коммит внутри `harness/` → bump gitlink).
