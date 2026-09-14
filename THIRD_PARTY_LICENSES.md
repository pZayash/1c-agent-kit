# Third-Party Licenses and Attribution

This repository vendors and adapts content from third-party projects. This file
records the origin and license of each such component. The MIT license requires
that redistributions retain the copyright notice and permission notice; the
relevant notices are reproduced below.

Components that are only *referenced* (installed or downloaded at runtime, or
linked in documentation) are listed separately — they are not distributed as
part of this repository.

Each vendored component directory also contains a copy of the upstream license
in its own `LICENSE` file, so that directories copied or linked into consumer
projects retain the copyright notice.

## Vendored / adapted content

### 1. `skills/cc-1c/` — cc-1c-skills

- Source: <https://github.com/Nikolay-Shirokov/cc-1c-skills>
- License: MIT
- Copyright: (c) 2025-2026 Nick Shirokov

Vendored upstream 1C configuration skills. See MIT license text below.

### 2. `cursor/skills/handoff/` — handoff

- Source: <https://github.com/mattpocock/skills/tree/main/skills/productivity/handoff>
- License: MIT
- Copyright: (c) 2026 Matt Pocock

Adapted for the 1C consumer stack. See MIT license text below.

### 3. `cursor/skills/explore/`, `docs/ai/ADR-FORMAT.md`, `docs/ai/CONTEXT-FORMAT.md`,
`docs/ai/ANALYTICS-FORMAT.md`, `docs/ai/ROLES-FORMAT.md` — grill-with-docs

- Source: <https://github.com/mattpocock/skills> (`skills/engineering/grill-with-docs`)
- License: MIT
- Copyright: (c) 2026 Matt Pocock

Adapted for the 1C consumer stack. See MIT license text below.

### 4. `cursor/skills/ponytail/`, `cursor/rules/ponytail.mdc` — ponytail

- Source: <https://github.com/DietrichGebert/ponytail>
- License: MIT
- Copyright: (c) 2026 DietrichGebert

See MIT license text below.

### 5. `cursor/skills/openspec-*` — OpenSpec

- Source: <https://github.com/fission-ai/openspec>
- License: MIT
- Copyright: (c) 2024 OpenSpec Contributors

Adapted OpenSpec workflow skills (frontmatter `license: MIT`). See MIT license
text below.

### 6. `cursor/skills/caveman/`, `cursor/rules/caveman.mdc`

Original content in this repository; no third-party origin recorded. Licensed
under the repository MIT license.

## Referenced at runtime (not distributed)

| Component | License | Notes |
| --- | --- | --- |
| `bsl-language-server` (<https://github.com/1c-syntax/bsl-language-server>) | LGPL-3.0 | Downloaded to host cache by `tools/bsl-check/update-bsl-language-server.sh`; not vendored. |
| `bsl-parser` (<https://github.com/1c-syntax/bsl-parser>) | GPL-3.0 | Dependency reference only. |
| `tree-sitter-bsl` (<https://github.com/alkoleft/tree-sitter-bsl>) | MIT | Dependency reference only. |
| `rtk` (<https://github.com/rtk-ai/rtk>) | Apache-2.0 | Operator installs manually; kit no longer auto-downloads it. |
| `qmd` (fork <https://github.com/pZayash/qmd>) | MIT | Referenced in docs only; upstream (c) Tobi Lutke. |

## MIT license text

The following permission notice applies to components licensed under MIT
listed above. The copyright line varies per component as shown in each entry.

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
