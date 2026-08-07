---
description: "Tarefas de implementação — Meeting Copilot"
---

# Tasks: Meeting Copilot

**Input**: `docs/specs/001-feature-meeting-copilot/` (spec.md, plan.md)
**Branch**: `feature/001-meeting-copilot`

## Formato: `[ID] [P?] [Story] Descrição`

- **[P]** — pode rodar em paralelo (arquivos distintos, sem dependência)
- **[Story]** — user story da spec (US1–US5) ou `FND` para fundação
- Caminhos de arquivo são exatos e relativos à raiz do repositório

## Convenções

- Serviços novos: `Sources/Fluid/Services/Meeting/Copilot/`
- UI nova: `Sources/Fluid/UI/Meeting/Copilot/`
- Testes: `Tests/FluidDictationIntegrationTests/Copilot/`
- Antes de qualquer commit: SwiftFormat + SwiftLint estrito (`TEST-REPO-001`)
- Build de verificação neste ambiente: `./build.sh unsigned`

---

## Fase 1: Fundação (bloqueante)

**Objetivo**: modelos, persistência e perfis. Nada de US1–US5 pode começar antes desta fase fechar.

- [x] **T001** [FND] Criar `Sources/Fluid/Services/Meeting/Copilot/CopilotModels.swift` com `CopilotInsight`, `CopilotChatMessage`, `CopilotNote`, `CopilotBriefing` e `CopilotSessionArtifacts`. Todos `Codable`, `Sendable`, `Identifiable`, com `schemaVersion`. Insights ancoram em `MeetingMediaTime`, **não** em `MeetingTranscriptSegmentID` (AD-002).
- [x] **T002** [FND] Criar `Sources/Fluid/Persistence/MeetingCopilotProfileStore.swift` com `MeetingCopilotProfile` (id, nome, prompt de insight, prompt de briefing, `insightFormat`, variantes pt/en). Tipo próprio, **não** estender `SettingsStore.PromptMode` (AD-003).
- [x] **T003** [P] [FND] Semear cinco perfis embarcados em pt-BR e en — entrevista técnica, entrevista de emprego, vendas, aula, reunião interna — todos editáveis e duplicáveis (`FR-015`, `FR-034`).
- [x] **T004** [FND] Estender `Sources/Fluid/Services/Meeting/MeetingSessionStore.swift` para persistir `CopilotSessionArtifacts` junto da sessão, com escrita atômica e migração de schema. Não usar `UserDefaults` (`CODE-006`).
- [x] **T005** [FND] Adicionar `transcriptMode` (`.offlineAfterStop` | `.live`) e `copilotProviderChoice` a `MeetingSession` em `MeetingModels.swift`, incrementando `currentSchemaVersion` com migração do valor anterior (`LIVE-001`, AD-005).
- [x] **T006** [P] [FND] Adicionar preferências do copiloto ao `SettingsStore.swift`: posição do painel (acima/abaixo), estado de colapso, perfil padrão, modo de insight (automático/manual).
- [x] **T007** [P] [FND] Criar `Tests/FluidDictationIntegrationTests/Copilot/CopilotArtifactPersistenceTests.swift` — round-trip, migração de schema e sobrevivência a relaunch (`SC-006`).

**Checkpoint F1**: artefatos gravam e recarregam; perfis embarcados aparecem; `./build.sh unsigned` passa.

### Registro de execução F1 — 2026-08-06

Entregue além do previsto nas tarefas, por necessidade:

- `MeetingModels.swift`: `validateForPersistence()` travava `languageCode == "en"` (upstream `DEC-001` codificado). Relaxado para `MeetingSession.supportedLanguageCodes = ["en", "pt"]`, conforme `DEC-COP-001`.
- `MeetingSessionStore.swift`: seis membros passaram de `private` a `internal` e `MeetingSessionFileSystem` deixou de ser `private`, para que a persistência de artefatos coubesse em `MeetingSessionStore+Copilot.swift` em vez de dentro do arquivo herdado (R-05).
- `MeetingSession`: ganhou `init(from decoder:)` explícito. O inicializador sintetizado falharia ao ler manifests v1, que não têm os dois campos novos.
- Teste extra não previsto: `MeetingCopilotProfileStoreTests.swift`, cobrindo seeds, idempotência e resolução de idioma.

Validações executadas:

- `./build.sh unsigned` → `** BUILD SUCCEEDED **`
- `swiftlint --strict` (Docker `ghcr.io/realm/swiftlint:0.63.2`, igual ao CI) → `0 violations in 163 files`
- `xcodebuild test` → **não executou**. O test host trava com `The test runner hung before establishing connection`. Reproduzido em `AudioBufferConverterTests`, teste pré-existente não tocado por esta fase: é limitação do ambiente local, não do código desta spec. Os testes **compilam** — a falha ocorre após o build, ao subir o runner. Execução pendente em ambiente de CI.

Desvio de nomenclatura detectado: T010 fala em "array `segments` da sessão"; o campo real é `transcriptSegments`.

---

## Fase 2: Transcrição ao vivo (bloqueante para US1)

**Objetivo**: texto provisório durante a gravação, sem tocar na durabilidade da captura.

- [x] **T008** [FND] Expor um consumidor opcional de buffers em `MeetingCaptureEngine.swift`: cópia downsampled entregue por stream limitado com **descarte** sob pressão. Callbacks de captura permanecem mínimos (`CAP-012`, AD-001, R-02).
- [x] **T009** [FND] Criar `Copilot/LiveTranscriptionTap.swift` consumindo esse stream e alimentando ASR streaming multilíngue (pt/en) conforme o `languageCode` da sessão (`FR-000`, `DEC-COP-001`).
- [x] **T010** [FND] Emitir segmentos com `status = .provisional` no array `segments` da sessão, com IDs estáveis e `revision` incremental (`LIVE-002`).
- [x] **T011** [FND] Serializar o acesso ao provider de ASR entre caminho ao vivo e pipeline offline; o vivo cede prioridade ao durável (`PIPE-006`, `PIPE-015`, R-01).
- [x] **T012** [FND] Implementar reconciliação pós-Stop em `MeetingProcessingPipeline.swift`: segmentos finais substituem provisórios **preservando correções manuais** do usuário (`LIVE-007`, `LIVE-008`, R-03).
- [x] **T013** [P] [FND] Criar `Tests/FluidDictationIntegrationTests/Copilot/LiveTranscriptReconciliationTests.swift` cobrindo substituição, preservação de correção e ancoragem temporal de insights.
- [x] **T014** [FND] Teste de carga: sessão longa com consumidor ao vivo artificialmente lento, provando que nenhum chunk finalizado é perdido (`CAP-018`, R-02).

**Checkpoint F2**: texto provisório aparece durante a gravação e é substituído corretamente após o Stop; captura permanece íntegra sob estresse.

### Registro de execução F2 — 2026-08-06

Arquivos novos, todos em `Services/Meeting/Copilot/`:

- `MeetingLiveAudioSink.swift` — protocolo do sink, ring buffer limitado com descarte, conversão de `CMSampleBuffer` para mono `Float`
- `LiveTranscriptionTap.swift` — janela deslizante, gate de silêncio, throttle, resample para 16 kHz fora do callback
- `MeetingASRAccessArbiter.swift` — serialização entre caminho ao vivo e offline; o vivo é recusado, não enfileirado
- `LiveTranscriptReconciler.swift` — construtor de segmento provisório e reconciliação pós-Stop

Alterações em arquivos herdados, cirúrgicas:

- `MeetingCaptureEngine.swift`: `setLiveAudioSink` no protocolo **com implementação default vazia**, para não quebrar `FakeMeetingCaptureController` nos testes existentes; sink propagado aos dois runtimes; uma linha em cada callback de sample buffer.
- `MeetingSessionCoordinator.swift`: `session.transcriptSegments = result.segments` virou chamada ao reconciler — é a mudança que impede a perda de correções do usuário.

Decisões tomadas na implementação:

- O ring descarta o **mais antigo**, não o mais novo: o copiloto só consegue agir sobre o presente da conversa.
- `runLiveIfAvailable` retorna `nil` quando o offline detém o provider, em vez de esperar. Transcrição ao vivo que chega atrasada não tem valor, e enfileirar só cria backlog.
- `resample` retorna `[]` em vez de opcional (exigência do lint `discouraged_optional_collection`); vazio e falha levam à mesma ação do chamador.

Validações executadas:

- `xcodebuild build-for-testing` → exit 0, zero erros (app + alvo de testes compilam)
- `swiftlint --strict` (Docker, igual ao CI) → `0 violations in 169 files`
- `xcodebuild test` → **não executou**, mesmo bloqueio de ambiente da F1: `The test runner hung before establishing connection`, reproduzido em teste pré-existente. 26 testes novos escritos e compilando, execução pendente de CI.

Não entregue nesta fase: nada. T008–T014 completos no código; a validação de comportamento em runtime depende do CI.

---

## Fase 3: Motor de insights — US1 (P1)

**Objetivo**: cartões de insight guiados pelo perfil ativo.

- [x] **T015** [US1] Criar `Copilot/CopilotContextWindow.swift`: janela deslizante com teto de tokens mais resumo acumulado para reuniões longas (`FR-011`, R-04).
- [x] **T016** [US1] Criar `Copilot/CopilotPromptBuilder.swift` montando o prompt a partir do perfil, do `insightFormat` (`FR-033`), do idioma da sessão e da janela de contexto.
- [x] **T017** [US1] Criar `Copilot/CopilotInsightEngine.swift`: gatilho por fim de turno de fala, supressão de disparos redundantes, throttle e cancelamento de requisições obsoletas (`FR-009`, `FR-011`).
- [x] **T018** [US1] Integrar com `LLMClient` usando streaming; nenhuma chamada quando não há fala relevante (`FR-009`).
- [x] **T019** [US1] Criar `Copilot/MeetingCopilotService.swift` como orquestrador por sessão, criado e destruído pelo `MeetingSessionCoordinator` (AD-004).
- [x] **T020** [US1] Instanciar o serviço no `MeetingSessionCoordinator.swift`, amarrado ao ciclo de vida da sessão e sobrevivendo ao fechamento da janela (`FR-032`).
- [x] **T021** [US1] Tratar falha de provider como erro isolado no cartão, jamais como falha de sessão (`FR-012`, `SC-005`).
- [x] **T022** [P] [US1] Criar `Tests/FluidDictationIntegrationTests/Copilot/CopilotInsightTriggerTests.swift` e `CopilotContextWindowTests.swift` — disparo, silêncio, sobreposição, teto de janela.
- [x] **T023** [P] [US1] Criar `Tests/FluidDictationIntegrationTests/Copilot/CopilotPromptBuilderTests.swift` — variação por perfil, formato e idioma.

**Checkpoint F3**: insights coerentes com o perfil, dentro de `SC-001`, com falha de IA isolada.

### Registro de execução F3 — 2026-08-06

Arquivos novos em `Services/Meeting/Copilot/`:

- `CopilotContextWindow.swift` — janela deslizante por orçamento de caracteres, com backlog do que saiu para virar resumo
- `CopilotPromptBuilder.swift` — perfil + formato + idioma → mensagens; guardas de honestidade em todos os pedidos
- `CopilotInsightEngine.swift` — política de gatilho pura, rota de provider, execução com supersessão
- `MeetingCopilotService.swift` — orquestrador por sessão, estado observável, persistência com debounce
- `MeetingSessionCoordinator+Copilot.swift` — ciclo de vida e ponte tap → copiloto

Alterações no coordinator herdado: propriedade `copilot`, acessores estreitos, `appendProvisionalSegment` e as chamadas de start/stop. O grosso da lógica ficou no arquivo de extensão (R-05).

Decisões tomadas na implementação:

- **Orçamento em caracteres, não tokens.** Tokenização varia por modelo e a exatidão não compra nada aqui; ~8000 caracteres ficam perto de 2k tokens.
- **Um pedido novo cancela o anterior.** Quando a resposta antiga chega, a conversa já andou — mostrá-la seria pior que não mostrar nada. Cartão superado é removido, não deixado obsoleto.
- **Gatilho não dispara na fala do próprio usuário.** O copiloto responde ao interlocutor; reagir à fala de quem o usa sugeriria respostas para si mesmo.
- **Chat carrega histórico; os demais pedidos não.** Mantém o custo dos automáticos constante ao longo de uma reunião longa.
- **`recap` e `briefing` ignoram `insightFormat`.** São sumários por natureza; forçar "resposta pronta" distorceria a saída.
- **Provider resolvido por `DictationProviderRoute`**, o mesmo caminho do AI Enhancement — `privateAIRoute` para local, `resolve` para nuvem (AD-005).
- **ASR ao vivo usa `asr.fileTranscriptionProvider`**, o mesmo acessor da transcrição de arquivo, para não instanciar um segundo modelo (`PIPE-006`).

Validações executadas:

- `xcodebuild build-for-testing` → exit 0, zero erros
- `swiftlint --strict` (Docker, igual ao CI) → `0 violations in 176 files`
- `xcodebuild test` → **não executou**, mesmo bloqueio de ambiente das fases anteriores. 24 testes novos escritos e compilando.

**Não entregue nesta fase, e importante:** o copiloto só liga quando `session.transcriptMode == .live`, e nada ainda define esse valor — o padrão é `.offlineAfterStop`. Falta também a seleção de provider antes do Start (T046). Portanto **a Fase 3 não é observável na interface**: os serviços existem, compilam e têm o ciclo de vida ligado, mas nenhuma reunião os aciona até a Fase 4 trazer o painel e o setup.

---

## Fase 4: Painel — US1 (P1)

**Objetivo**: a superfície visível. Pode começar em paralelo à F3 com dados simulados.

- [x] **T024** [US1] Criar `UI/Meeting/Copilot/CopilotPanelView.swift`: container com posição acima/abaixo persistida e colapso sem afetar a gravação (`FR-005`, `FR-006`).
- [x] **T025** [US1] Criar `UI/Meeting/Copilot/CopilotStreamView.swift`: fluxo cronológico **virtualizado** — nunca uma árvore SwiftUI monolítica (`FR-008`, `PERF-004`, R-07).
- [x] **T026** [US1] Criar `UI/Meeting/Copilot/CopilotInsightCard.swift` seguindo as telas de referência: contexto detectado, citação do interlocutor, corpo do insight. Reusar tema e componentes existentes (`A11Y-009`).
- [x] **T027** [US1] Criar `UI/Meeting/Copilot/CopilotProfilePicker.swift`; troca de perfil afeta só insights seguintes e preserva a marcação dos anteriores (`FR-010`).
- [x] **T028** [US1] Hospedar o painel em `UI/MeetingTranscriptionView.swift` sem quebrar os estados de canvas existentes (setup, gravação, processamento, resultado, interrompido).
- [x] **T029** [US1] Distinguir visualmente texto provisório de final (`FR-004`).
- [x] **T030** [P] [US1] Acessibilidade do painel: navegação completa por teclado, ordem lógica de VoiceOver, sem depender de cor isolada (`A11Y-001`, `A11Y-003`, `A11Y-004`).

- [x] **T030b** [US1] **Dívida herdada — restaurar virtualização do transcript.** A correção do travamento (ver "Correção de bug herdado", abaixo) trocou `LazyVStack` por `VStack` em `MeetingResultCanvas`, removendo a virtualização. Restaurar `LazyVStack` com altura de linha estável, atendendo `PERF-004` e `FR-008`. **Bloqueia T025**, que constrói o fluxo virtualizado do copiloto sobre o mesmo padrão.

  **Medido em 2026-08-06, não estimado:**

  | Segmentos | Duração equivalente | Comportamento |
  | --- | --- | --- |
  | 3 | 35 s | instantâneo |
  | 135 | 12m55s | abre bem, rolagem fluida |
  | 1200 | ~1h45 | **lento, engasga na rolagem**, sem travar |

  Taxa observada: ~10,4 segmentos por minuto de reunião. Uma reunião de 1 hora fica em ~625 segmentos, dentro da faixa onde a degradação já aparece. O fixture de stress usado no teste pode ser recriado clonando uma sessão e multiplicando `transcriptSegments`.

  **Resolvido em 2026-08-06.** `LazyVStack` restaurado e `.fixedSize(horizontal: false, vertical: true)` aplicado à linha inteira, não apenas ao `Text` interno.

  Mecanismo: o `LazyVStack` dimensiona o conteúdo do scroll a partir de linhas que ainda não construiu. Uma linha cuja altura muda depois de materializada desloca o total, e o scroll salta — o salto move o ponteiro para outra linha, que remede, que salta de novo. `.textSelection` remedindo sob o cursor bastava para iniciar o ciclo. Fixar a altura na primeira medição encerra a realimentação.

  Verificado à mão contra os três fixtures (3, 135 e 1200 segmentos): abertura rápida, rolagem fluida e scroll imóvel com o mouse parado sobre o texto.

**Checkpoint F4**: US1 completa e demonstrável de ponta a ponta.

### Registro de execução F4 — 2026-08-06

Primeira fase validada em uso real, e a mais cara: **nove correções** depois do "pronto", todas encontradas rodando o app.

Arquivos novos em `UI/Meeting/Copilot/`: `CopilotPanelView`, `CopilotStreamView`, `CopilotInsightCard` (+ `CopilotChatBubble`), `CopilotProfilePicker`.

Entregue além das tarefas, por necessidade de tornar a fase testável:

- **Toggle do copiloto e seletor de provider** no setup (antecipa parte de T046). Sem eles nada ligava `transcriptMode = .live` e a fase era invisível.
- **Seletor de idioma** — `Language` era texto fixo `English`. `DEC-COP-001` estava implementada só no modelo; faltavam três guardas exigindo `== "en"` em `MeetingCaptureConfiguration.validate()`, `MeetingProcessingPipeline.process()` e a mensagem de erro.
- **Exclusão de reunião** com confirmação, `MeetingSessionStore.deleteSession` e `removeFromIndex`.
- **Painel redimensionável** por arraste, com alternativa por teclado.

Bugs corrigidos, na ordem em que apareceram:

1. `PrivateFeatures.privateAIProvider` é `false` no build público — o padrão `.local` é inatingível neste fork
2. Copiloto desistia em silêncio sem provider; agora o painel aparece e explica
3. `startCopilot` rodava **depois** de `capture.start()`, e o engine passa o sink aos runtimes ao criá-los — o sink nunca chegava
4. Sink instalado dentro de um `Task` solto, sem ordem garantida; virou `await`
5. `delegate` do tap era `weak` e o bridge era criado inline — desalocado imediatamente, toda transcrição caía em nulo
6. Três guardas de idioma bloqueando pt-BR
7. Debounce de 2,5s **menor** que o intervalo de transcrição (~3,5s): nunca esperava nada, todo fragmento disparava
8. Teto de fala contínua comparava contra `lastInsightAt`, `nil` antes do primeiro insight — com fala contínua nada disparava nunca
9. Citação do cartão mostrava só o último fragmento em vez do trecho acumulado

Ajustes de comportamento pedidos na validação:

- Insight espera pausa real de 7 s, com teto de 20 s e mínimo de 220 caracteres acumulados
- Cartão é **revisado no lugar** enquanto o assunto continua (janela de 90 s), em vez de empilhar um por fragmento
- Prompt de `supportingPoints` reescrito: pede leitura do momento, não lista do que acabou de ser dito
- Buffer do tap de 64 → 512 chunks; o pump drena após cada passagem (o selo "Degraded" era perda real de áudio)

Validações executadas:

- `./build.sh unsigned` → `** BUILD SUCCEEDED **`
- `swiftlint --strict` → `0 violations in 180 files`
- **Validação manual em reunião real**, em pt-BR, com provider Gemini: cartões coerentes, citação acumulada, painel redimensionável, exclusão funcionando
- `xcodebuild test` → segue sem executar neste ambiente

**Lacuna de teste identificada:** os bugs 3 a 8 são de fiação e de aritmética temporal, e nenhum dos 24 testes da F3 os pegaria — todos exercitam lógica pura. Falta um teste do `MeetingCopilotService` com relógio e transcrição simulados. Enquanto ele não existir, a validação manual é o único mecanismo real de verificação desta feature.

---

## Fase 5: Ações rápidas e chat — US2 (P1) e US3 (P2)

- [x] **T031** [US2] Criar `UI/Meeting/Copilot/CopilotActionBar.swift` com **Esclarecer**, **Recapitular** e **Pesquisar**.
- [x] **T032** [US2] Implementar as três ações no `CopilotInsightEngine`, cada uma com sua semântica de prompt sobre a janela de contexto.
- [x] **T033** [US2] **Pesquisar** declara explicitamente que responde a partir do conhecimento do modelo e não consultou fontes externas (`FR-013`, A-04).
- [x] **T034** [US2] Respostas de ação entram no mesmo fluxo cronológico dos insights automáticos, identificadas por origem (`FR-007`).
- [x] **T035** [US3] Criar `Copilot/CopilotChatService.swift` mantendo o fio da conversa e citando a transcrição acumulada.
- [x] **T036** [US3] Criar `UI/Meeting/Copilot/CopilotChatInput.swift`; novos segmentos de transcrição **não** podem apagar o texto em digitação nem roubar o foco (`FR-007`, edge case).
- [x] **T037** [US3] Permitir chat sobre sessões já encerradas, a partir da transcrição final (`US3` cenário 4).

**Checkpoint F5**: US2 e US3 completas, dentro de `SC-002`.

---

## Fase 6: Notas e briefing — US4 (P2) e US5 (P2)

- [x] **T038** [US4] Criar `Copilot/CopilotNoteExtractor.swift` acumulando decisões, pendências e perguntas em aberto, ancoradas a timestamps (`FR-018`).
- [x] **T039** [US4] Exibir notas na sessão salva e garantir que a exclusão do áudio as preserve (`FR-020`).
- [x] **T040** [US4] Estender o painel de histórico herdado do `meeting-m1` para mostrar transcrição, insights, chat, notas e briefings juntos (`US4` cenário 2).
- [x] **T041** [US4] Exclusão da reunião remove todos os artefatos de copiloto associados (`FR-021`).
- [x] **T042** [US5] Criar `Copilot/CopilotBriefingService.swift` gerando sobre a transcrição **autoritativa**, com aviso explícito quando a base for provisória (`FR-022`).
- [x] **T043** [US5] Criar `UI/Meeting/Copilot/CopilotBriefingView.swift` com seletor de perfil de briefing e geração sob demanda.
- [x] **T044** [US5] Permitir múltiplos briefings coexistindo por sessão, identificados por perfil e horário (`FR-023`).
- [x] **T045** [US5] Exportação omitindo embeddings, fingerprints de modelo e vetores de confiança (`FR-024`, `UX-RESULT-010`).

**Checkpoint F6**: US4 e US5 completas; `SC-008` verificado.

### Registro de execução F5 e F6 — 2026-08-07

Arquivos novos: `CopilotActionBar`, `CopilotBriefingView` (UI); `CopilotNoteExtractor`, `CopilotWebSearchService` (serviços).

Entregue além das tarefas, a pedido durante a validação:

- **`Search web` — quinta ação, com busca real.** Revoga a premissa `A-04`; registrado como `DEC-COP-003` na spec. Usa a API nativa do Gemini com `google_search`, porque o endpoint OpenAI-compatível do app não expõe grounding. Exibe fontes clicáveis. Com outro provedor, falha explicitamente em vez de responder de memória fingindo pesquisa.
- **`Take notes` sob demanda** em vez de extração automática por turno: cada extração é uma chamada completa ao modelo e competiria com as sugestões que o usuário está lendo.

Correções feitas na validação:

- **Ações usavam só a última fatia de ~3,5s.** `recentStretch()` passou a combinar o bloco aberto com o que foi dito desde então; os prompts pedem "o assunto sendo tratado agora", não "a última frase".
- **Ordenação do fluxo estava por tempo de mídia.** Uma ação manual acontece agora mas ancora no tempo de mídia da última fala, que pode ser anterior ao de cartões já em tela — a resposta era inserida acima deles. Passou a ordenar por `createdAt`: o painel é uma sequência de eventos, não uma linha do tempo da gravação.

Decisões de implementação:

- **`CopilotNoteExtractor` descarta linhas sem prefixo reconhecido.** Uma decisão inventada registrada como fato é pior que uma decisão faltando.
- **Deduplicação de notas por tipo + texto normalizado.** Notas são extraídas várias vezes ao longo da reunião; sem isso a lista vira transcrição de si mesma.
- **T037 resolvido com um copiloto de revisão** (`loadForReview`), criado a partir da sessão do histórico com a transcrição autoritativa como contexto. Chat, notas e briefing funcionam sobre reuniões encerradas.

Validações executadas:

- `xcodebuild build-for-testing` → exit 0
- `swiftlint --strict` → `0 violations in 186 files`
- **Validação manual**: cinco ações, chat, notas e briefing confirmados em uso real
- `xcodebuild test` → segue sem executar neste ambiente

Testes novos: `CopilotTurnAccumulatorTests` (10) e `CopilotNoteExtractorTests` (12). O primeiro é regressão direta dos dois bugs de aritmética temporal da F4 — a política de tempo foi extraída para `CopilotTurnAccumulator`, um struct puro, justamente para ser testável sem reunião rodando.

---

## Fase 7: Privacidade, robustez e prova

- [ ] **T046** Implementar seleção de provedor por sessão, fixada antes do Start, com padrão **local** (`FR-025`, AD-005).
- [ ] **T047** Implementar opt-in explícito para provedor em nuvem, com aviso claro de que a fala de terceiros sai da máquina (`FR-026`).
- [ ] **T048** Exibir indicador persistente do destino dos dados enquanto a nuvem estiver ativa (`FR-027`).
- [ ] **T049** Auditar analytics, logs e diagnósticos: nenhum conteúdo de reunião pode aparecer (`FR-028`, `SC-007`, `TEST-PRIV-001`, R-06).
- [ ] **T050** Verificação de capacidade do modelo local antes do Start, com aviso honesto em vez de falha cartão a cartão (R-08).
- [ ] **T051** Degradação em Intel: insights sobre transcrição sem rótulo de locutor, com a limitação declarada na interface (`DEC-009`).
- [ ] **T052** Medir a latência do primeiro PCM do ditado contra a baseline atual e provar impacto zero (`FR-030`, `SC-004`).
- [ ] **T053** Matriz de falhas: provider fora do ar, chave inválida, timeout, cancelamento no Stop, encerramento forçado durante insight em voo (`SC-005`).
- [ ] **T054** Sessão de 60 minutos com memória limitada e sem perda de segmentos finalizados (`SC-003`).
- [ ] **T055** SwiftFormat e SwiftLint estrito em toda a superfície nova (`TEST-REPO-001`).
- [ ] **T056** Validação no app instalado, em reunião real, em pt-BR e en (`TEST-REPO-003`).

**Checkpoint F7**: `SC-001` a `SC-008` verificados; feature pronta para gate de QA.

---

## Dependências

```text
F1 (T001–T007) ──┬──> F2 (T008–T014) ──> F3 (T015–T023) ──> F5 (T031–T037)
                 │                            │
                 │                            └──> F4 (T024–T030)
                 └──────────────────────────> F6 (T038–T045)
                                                   │
                                          F7 (T046–T056) <── todas
```

- **F1 e F2 são bloqueantes.** Nenhuma user story fecha sem elas.
- **F4 pode começar em paralelo a F3** usando dados simulados, mas só fecha depois de T019.
- **F6 depende de F1** para persistência, mas não de F3 — o briefing opera sobre a transcrição final, que já existe na base herdada.
- **F7 fecha por último**, pois valida o conjunto.

## Paralelismo

Marcadas com **[P]** e seguras para execução simultânea: T003, T006, T007, T013, T022, T023, T030.

## Contagem

56 tarefas — 14 de fundação, 16 de US1, 7 de US2/US3, 8 de US4/US5, 11 de robustez.

---

## Regras de parada

Pare e escale antes de prosseguir se qualquer tarefa exigir:

- quebrar a durabilidade da captura ou a recuperabilidade de chunks finalizados
- unir os domínios de falha de captura e processamento
- mover sessões de reunião para `UserDefaults`
- alterar o contrato do `AudioActivityArbiter` entre ditado e reunião
- tornar IDs de segmento instáveis sob renomeação de locutor
- adicionar latência ao caminho de ditado

---

## Correção de bug herdado — travamento ao abrir sessão do histórico

Descoberto durante a validação manual das fases 1 e 2, em 2026-08-06. **Não foi causado por esta spec**, mas a bloqueava: a US4 depende de abrir sessões salvas, e o painel de copiloto vive nessa mesma tela.

### Sintoma

Clicar numa reunião salva no inspector de histórico congelava o app por completo. Main thread a 100%, árvore de views com 11.608 frames de profundidade, 8.293 deles em `SwiftUICore`, nenhum código do app no stack.

### Prova de que é herdado

Build do commit `cd58ff8` — anterior a qualquer linha desta spec — em worktree separado. **Travou de forma idêntica.**

### Bisect

1. Substituir `MeetingResultCanvas` por um `Text` → não travou ⇒ causa dentro do canvas de resultado
2. Reter o `ForEach` dos segmentos → não travou ⇒ causa na renderização de segmento
3. Trocar `Grid` por `HStack` em `MeetingTranscriptSegmentRow` → travamento eliminado
4. Sobrou oscilação de scroll sob hover; trocar `LazyVStack` por `VStack` → resolvido

Hipóteses testadas e descartadas no caminho: IDs duplicados entre sessões (regenerados, travou igual), `duration` com `Date()` e `endedAt` nulo (as sessões têm `endedAt`), oscilação do `ViewThatFits` nos metadados (isolado, travou igual).

### Causa raiz

Cada segmento construía o **próprio** `Grid` de uma única `GridRow`. Um `Grid` alinha colunas *entre as linhas dele mesmo* — com uma linha só, não alinha nada. O que ele fazia era medir o `Text` da transcrição com proposta de largura ilimitada, ciclando contra o `LazyVStack`/`ScrollView` quando o inspector de histórico (290 pt) estreitava o canvas. Fora do histórico havia folga de largura e o ciclo não se fechava — por isso a tela funcionava logo após o processamento.

### Correção aplicada

`Sources/Fluid/UI/MeetingTranscriptionView.swift`: `HStack` com coluna de timestamp de largura fixa, e `VStack` no lugar de `LazyVStack`.

### Dívida deixada

O `VStack` não virtualiza. Rastreado em **T030b**, que bloqueia T025.

### Sugestão

Vale reportar ao upstream `altic-dev/FluidVoice`: o defeito está no código deles e afeta qualquer usuário com reuniões salvas.
