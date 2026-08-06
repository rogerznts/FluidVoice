# Feature Specification: Meeting Copilot

**Feature Branch**: `feature/001-meeting-copilot`
**Created**: 2026-08-06
**Status**: Draft
**Tipo**: feature
**Input**: Funcionalidade "meeting" — painel que acompanha a transcrição, gera insights em tempo real usando o AI Enhancement já configurado, funciona como note taker, oferece ações rápidas e chat, e produz um briefing final formatado por perfil de prompt.

---

## 1. Contexto e posicionamento

### 1.1 O que já existe

Esta spec **estende** a base de Meeting Transcription herdada de `upstream/1.6.8/meeting-m1`, já integrada ao `main` deste fork:

| Componente existente | Papel | Reuso nesta feature |
| --- | --- | --- |
| `MeetingCaptureEngine` | Captura dual-track (app + microfone) | Consumido sem alteração de contrato |
| `MeetingSessionCoordinator` | Máquina de estados app-wide | Estendido com o modo `.live` |
| `MeetingProcessingPipeline` | Diarização + ASR offline | Permanece a fonte autoritativa |
| `MeetingSessionStore` | Persistência versionada em disco | Estendido com artefatos de copiloto |
| `MeetingTranscriptionView` | Canvas de setup/gravação/resultado + histórico | Ganha o painel de copiloto |
| `LLMClient` | Cliente LLM com streaming e tool calling, 13 providers | Motor dos insights |
| `SettingsStore.DictationPromptProfile` | Perfis de prompt do AI Enhancement | Modelo base dos perfis de reunião |
| `CommandModeService` + `ChatHistoryStore` | Chat com histórico e roles | Padrão de referência do chat |
| `ParakeetRealtimeProvider` | ASR streaming de baixa latência | Alimenta a transcrição provisória |
| `AudioActivityArbiter` | Arbitragem microfone entre dictation e meeting | Governa conflitos |

### 1.2 Divergência declarada do PRD upstream

O `MEETING_TRANSCRIPTION_PRD.md` herdado define como **não-objetivos** exatamente o que esta feature entrega. A divergência é deliberada e é a razão de ser deste fork:

| Item do PRD upstream | Decisão desta spec |
| --- | --- |
| `NONGOAL-003` — sem resumos ou action items automáticos | **Revogado.** Insights automáticos são o núcleo do produto. |
| `PIPE-005` — não aplicar AI enhancement à fala da reunião | **Revogado para a camada de copiloto.** A transcrição armazenada continua crua; o enhancement atua sobre uma cópia. |
| `[FUTURE · LIVE]` M5 — transcrição progressiva fora do V1 | **Antecipado.** É pré-requisito dos insights ao vivo. |
| `DEC-002` — caminho de dados estritamente local | **Relaxado com consentimento.** Padrão local; nuvem exige opt-in explícito por sessão. |

Tudo o que o PRD upstream marca como `[MUST · FOUNDATION]` permanece válido e **não deve ser quebrado** — em especial a durabilidade da captura, IDs estáveis de segmento e a separação de domínios de falha entre captura e processamento.

---

## 2. Problema e oportunidade

Quem conduz uma reunião de alto risco — entrevista técnica, entrevista de emprego, ligação de vendas, aula, reunião interna — precisa **pensar e falar ao mesmo tempo**. A transcrição pura só ajuda depois que a reunião acabou, quando a oportunidade de agir já passou.

O FluidVoice já tem os três ativos que resolvem isso: captura de reunião confiável, um motor de LLM multi-provider e um sistema de perfis de prompt. Falta a camada que os conecta em tempo real.

**Oportunidade:** transformar o gravador de reuniões em um copiloto que entende o contexto da conversa e responde no ritmo dela — assumindo comportamentos diferentes conforme o perfil selecionado, sem que o usuário precise reconfigurar nada.

---

## 3. Usuários e atores

| Ator | Descrição | Necessidade primária |
| --- | --- | --- |
| **Candidato** | Passa por entrevista técnica ou de emprego | Estruturar a resposta a uma pergunta difícil enquanto ela ainda está no ar |
| **Entrevistador** | Conduz entrevista técnica | Lembrar o que falta sondar; avaliar profundidade da resposta |
| **Vendedor** | Conduz call comercial | Responder objeção com dado concreto; não perder o próximo passo |
| **Aluno / Professor** | Participa ou conduz aula | Capturar o que importa sem parar de acompanhar |
| **Participante de reunião interna** | Reunião de time ou de decisão | Recapitular o que perdeu; sair com as decisões registradas |

Todos são **um único usuário local do macOS** operando o FluidVoice na própria máquina. Não há multi-usuário, servidor ou sincronização nesta feature.

---

## 4. Cenários de usuário

### User Story 1 — Insight ao vivo guiado por perfil (Prioridade: P1)

O usuário inicia uma reunião com o perfil **Entrevista Técnica** selecionado. Enquanto o interlocutor fala, o painel de copiloto exibe, logo abaixo da transcrição, um cartão com o contexto detectado, a citação do que foi dito e uma resposta sugerida. Ao trocar para o perfil **Vendas**, os cartões passam a destacar objeções e dados de suporte em vez de arquitetura.

**Por que P1**: é o núcleo da proposta de valor. Sem isso, a feature é apenas o gravador que já existe.

**Teste independente**: iniciar uma sessão, reproduzir uma pergunta em voz alta e verificar que um cartão de insight coerente com o perfil aparece dentro do orçamento de latência definido em SC-001.

**Cenários de aceite**:

1. **Dado** uma sessão gravando com perfil ativo, **Quando** um turno de fala do interlocutor termina, **Então** um cartão de insight é gerado a partir da janela de contexto e exibido sem interromper a transcrição.
2. **Dado** dois perfis com prompts distintos, **Quando** o usuário alterna entre eles durante a sessão, **Então** os cartões seguintes seguem o novo prompt e os anteriores permanecem intactos com a marcação do perfil que os gerou.
3. **Dado** que o provider de IA falha ou expira, **Quando** um insight é solicitado, **Então** o cartão exibe o erro de forma discreta, a captura e a transcrição continuam intactas, e o erro não derruba a sessão.
4. **Dado** um período sem fala relevante, **Quando** o gatilho de insight avalia a janela, **Então** nenhum cartão é gerado e nenhuma chamada ao provider é feita.

---

### User Story 2 — Ações rápidas sob demanda (Prioridade: P1)

Durante a reunião o usuário aciona **Esclarecer**, **Recapitular** ou **Pesquisar** e recebe uma resposta imediata baseada no que já foi transcrito, sem sair da tela nem digitar nada.

**Por que P1**: é o controle manual sobre o copiloto. O gatilho automático acerta a maior parte do tempo; as ações cobrem o resto, e são o que torna a ferramenta confiável em momentos de pressão.

**Teste independente**: com uma transcrição parcial em tela, acionar cada botão e verificar que a resposta corresponde à semântica da ação e ao perfil ativo.

**Cenários de aceite**:

1. **Dado** um trecho recém-transcrito, **Quando** o usuário aciona **Esclarecer**, **Então** o copiloto explica o último ponto discutido em linguagem direta.
2. **Dado** uma reunião com mais de 10 minutos, **Quando** o usuário aciona **Recapitular**, **Então** o copiloto resume o que foi tratado até o momento, organizado por tópico.
3. **Dado** um termo mencionado na conversa, **Quando** o usuário aciona **Pesquisar**, **Então** o copiloto responde a partir do próprio conhecimento do modelo e declara explicitamente que não consultou fontes externas.
4. **Dado** qualquer ação acionada, **Quando** a resposta chega, **Então** ela entra no mesmo fluxo cronológico dos insights automáticos e é preservada na sessão.

---

### User Story 3 — Chat com o copiloto (Prioridade: P2)

O usuário digita uma pergunta na caixa de texto do painel e recebe resposta que leva em conta a transcrição corrente, sem que sua digitação seja confundida com fala transcrita.

**Por que P2**: complementa as ações rápidas para o que não cabe em um botão. Depende da mesma infraestrutura de US1 e US2, então chega barato depois delas.

**Teste independente**: digitar uma pergunta sobre algo dito minutos antes e verificar que a resposta referencia corretamente aquele trecho.

**Cenários de aceite**:

1. **Dado** uma sessão ativa, **Quando** o usuário envia uma mensagem, **Então** a resposta considera a transcrição acumulada e o prompt do perfil ativo.
2. **Dado** um histórico de chat na sessão, **Quando** o usuário faz uma pergunta de acompanhamento, **Então** o copiloto mantém o fio da conversa anterior.
3. **Dado** que o usuário está digitando, **Quando** a transcrição recebe novos segmentos, **Então** o texto em digitação não é perdido nem o foco é roubado.
4. **Dado** uma sessão encerrada, **Quando** o usuário a reabre no histórico, **Então** o chat daquela sessão está preservado e permite novas perguntas sobre a transcrição final.

---

### User Story 4 — Note taker e biblioteca de sessões (Prioridade: P2)

Ao longo da reunião o copiloto acumula notas estruturadas — decisões, pendências, perguntas em aberto. Ao fim, a sessão inteira fica salva e recuperável.

**Por que P2**: é o valor que sobrevive à reunião. A base de histórico já existe no `meeting-m1`; esta story a estende em vez de recriá-la.

**Teste independente**: gravar uma reunião curta com decisões explícitas, encerrar e verificar que as notas aparecem na sessão salva e sobrevivem ao relançamento do app.

**Cenários de aceite**:

1. **Dado** uma reunião em andamento, **Quando** uma decisão ou pendência é enunciada, **Então** ela é acumulada nas notas da sessão com o timestamp de origem.
2. **Dado** uma sessão encerrada, **Quando** o usuário a abre na biblioteca, **Então** vê transcrição, insights, chat, notas e briefing juntos.
3. **Dado** que o app é encerrado e reaberto, **Quando** a biblioteca é consultada, **Então** todos os artefatos de copiloto persistiram.
4. **Dado** que o usuário exclui o áudio de uma sessão, **Quando** a sessão é reaberta, **Então** transcrição, notas e insights continuam disponíveis.

---

### User Story 5 — Briefing final formatado por perfil (Prioridade: P2)

Encerrada a reunião, o usuário escolhe um perfil de briefing e recebe um documento formatado conforme o prompt daquele perfil — relatório de entrevista, resumo de call de vendas, notas de aula.

**Por que P2**: é o entregável que o usuário compartilha. Depende da transcrição final autoritativa, portanto vem depois do fluxo ao vivo.

**Teste independente**: sobre uma transcrição já concluída, gerar briefings com dois perfis diferentes e verificar que o formato de saída difere conforme o prompt.

**Cenários de aceite**:

1. **Dado** uma sessão com transcrição final, **Quando** o usuário seleciona um perfil de briefing e confirma, **Então** o briefing é gerado a partir da transcrição autoritativa, não da provisória.
2. **Dado** um briefing gerado, **Quando** o usuário troca o perfil e regenera, **Então** o novo briefing coexiste com o anterior, identificado pelo perfil e pelo horário de geração.
3. **Dado** um briefing pronto, **Quando** o usuário o exporta, **Então** o arquivo contém o briefing e nenhum metadado interno de modelo, embedding ou confiança.
4. **Dado** que a transcrição final ainda está processando, **Quando** o usuário pede o briefing, **Então** a interface explica a espera e oferece gerar sobre o texto provisório com aviso explícito de que é preliminar.

---

## 5. Requisitos funcionais

### 5.1 Transcrição ao vivo

- **FR-000**: A transcrição ao vivo DEVE suportar português e inglês, selecionados pelo `languageCode` da sessão, sem exigir migração de schema.
- **FR-001**: O sistema DEVE produzir segmentos de transcrição provisórios durante a gravação, sem interferir na durabilidade da captura em disco.
- **FR-002**: A falha do caminho ao vivo NÃO DEVE interromper a gravação nem o processamento offline. São domínios de falha separados.
- **FR-003**: Após o Stop, o pipeline offline DEVE permanecer a fonte autoritativa e reconciliar os segmentos provisórios, preservando IDs estáveis e correções manuais do usuário.
- **FR-004**: O sistema DEVE distinguir visualmente texto provisório de texto final.

### 5.2 Painel de copiloto

- **FR-005**: O painel DEVE acompanhar a área de transcrição, com posição configurável **acima** ou **abaixo** dela, e a escolha DEVE persistir entre sessões.
- **FR-006**: O usuário DEVE poder recolher e reabrir o painel sem afetar a gravação.
- **FR-007**: Insights, respostas de ação rápida e mensagens de chat DEVEM compartilhar um fluxo cronológico único, cada item identificado por sua origem.
- **FR-008**: A renderização DEVE permanecer responsiva em sessões longas; o fluxo não pode ser uma árvore SwiftUI monolítica sem virtualização.

### 5.3 Motor de insights

- **FR-009**: Insights automáticos DEVEM ser disparados por fim de turno de fala relevante, com janela de contexto limitada e supressão de disparos redundantes.
- **FR-010**: O prompt do perfil ativo DEVE determinar o comportamento do insight. Trocar o perfil durante a sessão afeta apenas os insights seguintes.
- **FR-011**: O sistema DEVE limitar a taxa de chamadas ao provider e cancelar requisições obsoletas quando a conversa avança.
- **FR-012**: Falhas de provider DEVEM ser exibidas de forma discreta e não podem escalar para falha de sessão.
- **FR-013**: O sistema NÃO DEVE afirmar que consultou fontes externas. A ação **Pesquisar** responde a partir do conhecimento do modelo e declara essa limitação.

### 5.4 Perfis de copiloto

- **FR-014**: O sistema DEVE oferecer perfis de reunião com prompt editável, reutilizando o modelo de perfis do AI Enhancement.
- **FR-015**: O sistema DEVE embarcar perfis iniciais para entrevista técnica, entrevista de emprego, vendas, aula e reunião interna, todos editáveis e duplicáveis.
- **FR-016**: Perfis de reunião DEVEM ser distinguíveis dos perfis de ditado, sem colidir com o roteamento de prompt existente.
- **FR-017**: Cada perfil DEVE poder definir prompt de insight ao vivo e prompt de briefing final de forma independente.
- **FR-033**: Cada perfil DEVE declarar seu formato de insight — resposta redigida ou tópicos de apoio — e o formato DEVE ser editável pelo usuário (`DEC-COP-002`).
- **FR-034**: Os prompts embarcados DEVEM existir em português e inglês, selecionados pelo `languageCode` da sessão (`DEC-COP-001`).

### 5.5 Note taker e persistência

- **FR-018**: O sistema DEVE acumular notas estruturadas durante a sessão, ancoradas a timestamps da transcrição.
- **FR-019**: Insights, chat, notas e briefings DEVEM ser persistidos junto da sessão e sobreviver ao encerramento do app.
- **FR-020**: A exclusão do áudio NÃO DEVE remover os artefatos de copiloto.
- **FR-021**: A exclusão da reunião DEVE remover todos os artefatos de copiloto associados.

### 5.6 Briefing final

- **FR-022**: O briefing DEVE ser gerado sobre a transcrição autoritativa, com aviso explícito quando gerado sobre texto provisório.
- **FR-023**: Múltiplos briefings por sessão DEVEM coexistir, identificados por perfil e horário.
- **FR-024**: A exportação DEVE omitir embeddings, fingerprints de modelo e vetores de confiança internos.

### 5.7 Privacidade e provedor

- **FR-025**: O padrão DEVE ser o provedor local (Fluid Intelligence). Nenhuma fala sai da máquina sem ação do usuário.
- **FR-026**: Usar provedor em nuvem DEVE exigir opt-in explícito, com aviso claro de que a transcrição da reunião — incluindo a fala de terceiros — será enviada a um serviço externo.
- **FR-027**: Enquanto um provedor em nuvem estiver ativo, a interface DEVE exibir um indicador persistente do destino dos dados.
- **FR-028**: Analytics, logs e diagnósticos NÃO DEVEM conter transcrição, insights, notas, briefings, nomes de participantes ou títulos de reunião.
- **FR-029**: O sistema NÃO DEVE afirmar que determina a legalidade da gravação nem substituir o aviso aos participantes.

### 5.8 Convivência com o app existente

- **FR-030**: O copiloto NÃO DEVE adicionar latência ao ditado quando nenhuma reunião está ativa.
- **FR-031**: O arbitramento de áudio existente entre ditado e reunião DEVE ser respeitado sem alteração do contrato atual.
- **FR-032**: Fechar a janela principal NÃO DEVE interromper a sessão nem a geração de insights.

---

## 6. Entidades principais

| Entidade | Representa | Atributos essenciais |
| --- | --- | --- |
| **MeetingCopilotProfile** | Perfil que define o comportamento do copiloto | ID estável, nome, prompt de insight, prompt de briefing, ícone, editável, datas |
| **CopilotInsight** | Um cartão gerado pelo copiloto | ID, timestamp da mídia, origem (automático/ação/chat), perfil gerador, contexto citado, corpo, estado, erro |
| **CopilotChatMessage** | Uma troca no chat da sessão | ID, papel, conteúdo, timestamp, referência a segmentos citados |
| **CopilotNote** | Nota estruturada acumulada | ID, tipo (decisão/pendência/pergunta), texto, timestamp de origem |
| **CopilotBriefing** | Documento final formatado | ID, perfil usado, corpo, gerado em, base (provisória/final) |
| **CopilotSessionArtifacts** | Agregado persistido junto à sessão | Versão de schema, insights, mensagens, notas, briefings, provedor usado |

Todas as entidades pertencem a uma `MeetingSession` existente e seguem o mesmo versionamento de schema já adotado por ela.

---

## 7. Casos de borda

- **Provider indisponível ou sem chave** — o painel explica e oferece trocar de provedor; captura e transcrição seguem normalmente.
- **Reunião muito longa** — a janela de contexto tem teto; o copiloto opera sobre janela deslizante mais um resumo acumulado, sem crescer indefinidamente.
- **Silêncio prolongado** — nenhum insight é gerado e nenhuma chamada é feita.
- **Fala sobreposta** — o gatilho usa o modelo de sobreposição já existente e não força ordem falsa de turnos.
- **Troca de perfil no meio da sessão** — insights anteriores mantêm a marcação do perfil que os originou.
- **Stop durante insight em voo** — a requisição é cancelada; o resultado parcial é descartado sem corromper a sessão.
- **Encerramento do app durante a sessão** — artefatos já persistidos sobrevivem; os em voo são perdidos sem corromper o índice.
- **Máquina Intel** — sem diarização, os insights operam sobre transcrição não rotulada por locutor e a interface declara a limitação.
- **Modelo local insuficiente na máquina** — o sistema avisa antes de iniciar em vez de falhar cartão a cartão.
- **Usuário digitando quando chega insight** — o texto em digitação e o foco são preservados.

---

## 8. Premissas e defaults adotados

| # | Premissa | Justificativa |
| --- | --- | --- |
| A-01 | Insights são automáticos por padrão, com opção de passar para manual | As telas de referência mostram reação autônoma à fala do interlocutor |
| A-02 | Gatilho por fim de turno com janela deslizante | Mais estável que gatilho por intervalo fixo; alinhado ao modelo de segmentos existente |
| A-03 | Retenção herda a política de áudio do PRD upstream (`OPEN-001`, 7 dias) | Evita criar uma segunda política de retenção divergente |
| A-04 | **Pesquisar** não faz busca na web no V1 | Não há infraestrutura de busca no app; prometer o contrário seria falso |
| A-05 | Transcrição provisória usa o provider de ASR streaming já embarcado | Evita introduzir um segundo motor de ASR |
| A-06 | Um único painel de copiloto por sessão | O coordinator já permite apenas uma sessão ativa |
| A-07 | Perfis embarcados são editáveis, não fixos | Consistente com o comportamento dos perfis de ditado existentes |

---

## 9. Decisões resolvidas

- **DEC-COP-001 — Idiomas do V1: português e inglês.** Revoga `DEC-001` (English-only) do PRD upstream. A transcrição ao vivo usa um modelo de ASR multilíngue já embarcado; os prompts dos perfis embarcados existem em pt-BR e en. O `languageCode` da sessão, que já é persistido, seleciona o conjunto de prompts. Consequência aceita: latência ligeiramente maior que o Parakeet Flash só-inglês.

- **DEC-COP-002 — Formato do insight é configurável por perfil.** Cada `MeetingCopilotProfile` declara seu formato de saída: resposta redigida pronta para ser dita, ou tópicos de apoio. Perfis embarcados adotam o formato adequado ao seu contexto, e o usuário pode alterá-lo. Consequência: o formato de resposta pronta permanece disponível, e a responsabilidade pelo uso adequado em processos seletivos é do usuário — o produto não avalia contexto nem política de terceiros.

### 9.1 Nota de contexto de uso

Perfis que entregam resposta redigida durante entrevistas de emprego podem conflitar com a política do processo seletivo ou do empregador. Esta é uma informação de produto, não um bloqueio: o sistema não determina legalidade nem política aplicável (`FR-029`), e a decisão de uso é do usuário.

---

## 10. Critérios de sucesso

- **SC-001**: Um insight automático aparece em até **5 segundos** após o fim do turno de fala que o disparou, em hardware Apple Silicon com provedor local.
- **SC-002**: Uma ação rápida (**Esclarecer**, **Recapitular**, **Pesquisar**) entrega a primeira palavra da resposta em até **3 segundos**.
- **SC-003**: Uma sessão de **60 minutos** completa sem crescimento não-limitado de memória e sem perda de segmentos finalizados.
- **SC-004**: Ativar o copiloto **não altera** a latência do primeiro PCM do ditado quando nenhuma reunião está ativa, medido contra a baseline atual.
- **SC-005**: Uma falha completa do provedor de IA durante uma sessão de 30 minutos resulta em **zero** perda de áudio, transcrição ou notas já persistidas.
- **SC-006**: Todos os artefatos de copiloto de uma sessão sobrevivem ao encerramento forçado do app e ao relançamento.
- **SC-007**: Uma auditoria de logs, analytics e tráfego de rede não encontra conteúdo de reunião quando o provedor local está selecionado.
- **SC-008**: O usuário consegue gerar dois briefings com perfis diferentes sobre a mesma sessão e obter documentos com estruturas distintas.

---

## 11. Fora de escopo

- Detecção automática de reunião (é `M4` no PRD upstream)
- Perfis de voz persistentes entre reuniões (é `M3` no PRD upstream)
- Busca na web real dentro da ação **Pesquisar**
- Integração com calendário, bots de reunião ou envio automático de briefing
- Sincronização em nuvem de sessões ou perfis
- Tradução em tempo real
- Suporte a múltiplas sessões simultâneas
