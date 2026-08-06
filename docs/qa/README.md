# QA

`/mosk-qa` (Joaquim) escreve aqui: quality gates, estratégia de teste e avaliações de risco e NFR.

## Estrutura

- `gates/` — vereditos de gate por spec (`PASS` / `CONCERNS` / `FAIL` / `WAIVED`).
- `assessments/` — avaliações de risco, NFR e rastreabilidade, quando produzidas.

O `gate.yaml` de cada spec vive dentro da própria spec (`docs/specs/{id}/gate.yaml`); esta pasta guarda os gates consolidados do projeto.

## Como rodar os testes

Comandos em [`.claude/rules/project.md`](../../.claude/rules/project.md), seção *Testing*. Resumo: alvo único `FluidDictationIntegrationTests`, via `xcodebuild test`, e `swiftlint lint --strict` no mesmo padrão do CI.

## Conteúdo

Nenhum gate ainda.
