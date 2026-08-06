# Project Documentation Index

Last updated: 2026-08-06

## Overview

- **[Discovery](./discovery/)** — pesquisa, briefs, brainstorming
- **[PRD](./prd/index.md)** — requisitos de produto
- **[Architecture](./architecture/index.md)** — design de sistema + ADRs
- **[UI](./ui/index.md)** — design system, fluxos, wireframes
- **[QA](./qa/README.md)** — quality gates
- **[Project](./project/README.md)** — plano vivo e atualizações datadas

## Active Specs

| # | Spec | Tipo | Branch | Fase | Status |
| --- | --- | --- | --- | --- | --- |
| 001 | [Meeting Copilot](./specs/001-feature-meeting-copilot/spec.md) | feature | `feature/001-meeting-copilot` | implement | active |

### 001 — Meeting Copilot

Camada de copiloto sobre a base de Meeting Transcription: transcrição ao vivo, insights guiados por perfil de prompt, ações rápidas, chat, note taker e briefing final formatado.

- [spec.md](./specs/001-feature-meeting-copilot/spec.md) — 5 user stories, 36 requisitos, 8 critérios de sucesso
- [plan.md](./specs/001-feature-meeting-copilot/plan.md) — 5 decisões de arquitetura, mapa de arquivos, 8 riscos
- [tasks.md](./specs/001-feature-meeting-copilot/tasks.md) — 56 tarefas em 7 fases; **Fases 1 e 2 concluídas** (fundação e transcrição ao vivo), 14/56

## Archived Specs

Nenhuma.

## Domain Contents

### discovery/

- `README.md`

### prd/

- `index.md`

### architecture/

- `index.md`
- `adr/` — vazio

### ui/

- `index.md`
- `flows/` — vazio

### qa/

- `README.md`
- `gates/` — vazio

### project/

- `README.md`

## Fora do layout canônico

Estes documentos não seguem a estrutura MOSK e permanecem onde estão por decisão explícita:

- [`MACOS_UI_AUTOMATION_BRANCH_PLAN.md`](./MACOS_UI_AUTOMATION_BRANCH_PLAN.md) — plano de automação de testes de UI, herdado do upstream `altic-dev` e versionado lá. Movê-lo geraria conflito nos merges futuros do upstream.
- [`../MEETING_TRANSCRIPTION_PRD.md`](../MEETING_TRANSCRIPTION_PRD.md) — PRD da base de captura de reuniões, na raiz do repositório. Mesmo motivo. É leitura obrigatória junto da spec 001.

<!-- custom -->
<!-- /custom -->
