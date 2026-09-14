# OpenSpec staging в kit

Каталог **подготовка** к полноценному OpenSpec внутри `1c-agent-kit`.

- Сейчас: Markdown-артефакты changes лежат здесь вручную.
- Пока **нет** гарантии, что `openspec list` из корня **пилота** видит эти
  changes (CLI и `config.yaml` kit — отдельная сессия / change).
- После внедрения OpenSpec-in-kit: этот корень станет cwd для propose/apply
  по изменениям самого kit.

Активных черновиков нет. Завершённые черновики удаляются после apply —
история остаётся в git.
