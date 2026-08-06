# UI

Duas mãos escrevem aqui, com focos distintos:

- `/mosk-ux-expert` (Salete) — estrutura e comportamento: `flows/`, wireframes, specs de front-end.
- `/mosk-ui-expert` (Tiago) — acabamento visual: `design-system.md`, `styles/`.

## Base vs spec

- **Base** (esta pasta) — o design system e os fluxos do produto como ele é hoje.
- **Per-spec** (`docs/specs/{id}/ui/`) — fluxos e componentes de uma feature específica.

## Design system atual

O tema vive no código, em `Sources/Fluid/Theme/`. Ainda não há documentação de design system escrita — componentes e tokens são lidos direto da fonte.

A regra `A11Y-009` do PRD de reuniões vale para toda UI nova: reusar tipografia, cards, botões, espaçamento e alturas de controle existentes em vez de criar chrome próprio.

## Conteúdo

- `flows/` — fluxos de usuário. Vazio.
