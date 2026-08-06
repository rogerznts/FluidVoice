# Architecture

`/mosk-architect` (Vinicius) escreve aqui: design de sistema, integrações e registros de decisão.

## Base vs spec

- **Base** (esta pasta) — a arquitetura como ela é hoje.
- **Per-spec** (`docs/specs/{id}/architecture/`) — ADRs e modelos de dados que uma feature introduz. Sobem para cá no arquivamento, via `promote:`.

## Arquitetura atual

A descrição da arquitetura vigente está em [`.claude/rules/project.md`](../../.claude/rules/project.md), seção *Architecture* — camadas, convenções de concorrência e mapa de pastas. Esse arquivo é a fonte canônica; não duplique o conteúdo aqui.

Resumo: aplicativo macOS de processo único, sem backend. `AppServices` é o container de serviços; `SettingsStore` é a fonte central de configuração; serviços de UI são `@MainActor` e trabalho de áudio em tempo real roda em actors ou filas seriais dedicadas.

## Decisões

- `adr/` — registros de decisão arquitetural. Vazio.

Decisões arquiteturais da spec 001 estão em [`docs/specs/001-feature-meeting-copilot/plan.md`](../specs/001-feature-meeting-copilot/plan.md), seção 3 (AD-001 a AD-005). Ainda não foram promovidas.
