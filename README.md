# Analise Funil

## Visao Geral

Esta automacao parte de uma unica extracao do Power Automate e gera 2 saidas da mesma rodada:

- `Insight Funil`: resumo executivo principal do funil
- `Comparativo`: comparativo entre periodos com a mesma base da rodada
- `Resumo Mensal Funil`: consolidado mensal auxiliar para analise historica em modo comercial ou calendario

Regra de ordem da publicacao:

1. primeiro publicar o `Insight Funil`
2. depois publicar o `Comparativo`

No desenho atual da automacao local:

- `rodar_fluxo_funil.ps1` e o fluxo principal da rodada
- `rodar_fluxo_comparativo_funil.ps1` gera o comparativo

Modo de operacao atual:

- o Power Automate executa as consultas DAX no Power BI e grava os JSONs na pasta de extracao sincronizada
- a execucao local dos scripts acontece manualmente, por comando, em `Teste` ou `Producao`

## Diagrama do Fluxo

```mermaid
flowchart TD
    DAX["Power BI: consultas DAX"] --> PA["Power Automate salva JSONs brutos<br/>em Entrada/FunilExtracao"]

    PA --> F1START["rodar_fluxo_funil.ps1"]
    PA -.->|"mesma base, via<br/>.ultima_base_funil.json"| F2START["rodar_fluxo_comparativo_funil.ps1"]

    subgraph FLUXO1["Fluxo 1 — Insight Funil"]
        F1START --> T1["tratar_dax_orcamentos/itens_json_power_automate.py"]
        T1 --> P1["automacao_pipeline.py<br/>remove ruido + nao convertidos"]
        P1 --> I1["gerar_resumo_insight_json.py"]
        I1 --> J1["resumo_insight_card_teams_*.json"]
        J1 --> TEAMS1["Power Automate posta<br/>Adaptive Card no Teams"]
        I1 --> DASH1["atualizar_dashboard_resumo_insight_js.py"]
        DASH1 --> JS1["resumo_insight_dashboard.js"]

        T1 --> TI1["gerar_top_itens_json.py<br/>ranking por item"]
        TI1 --> JTI["top_itens_card_teams_*.json"]
        JTI --> DASHTI["atualizar_dashboard_top_itens_js.py"]
        DASHTI --> JSTI["top_itens_dashboard.js"]
    end

    subgraph FLUXO2["Fluxo 2 — Comparativo"]
        F2START --> T2["tratar_dax_orcamentos/itens_json_power_automate.py"]
        T2 --> P2A["automacao_pipeline.py<br/>periodo atual"]
        T2 --> P2B["automacao_pipeline.py<br/>periodo anterior"]
        P2A --> I2A["resumo_insight_periodo_atual_*.json"]
        P2B --> I2B["resumo_insight_periodo_a_*.json"]
        I2A --> COMP["gerar_comparativo_resumo_insight_periodos.py"]
        I2B --> COMP
        COMP --> J2["comparativo_resumo_insight_card_teams_*.json"]
        J2 --> TEAMS2["Power Automate posta<br/>card comparativo no Teams"]
        COMP --> DASH2["atualizar_dashboard_comparativo_js.py"]
        DASH2 --> JS2["comparativo_dashboard.js"]
    end

    JS1 --> PUB["Copy-Item para<br/>SharePoint StaticWebApp"]
    JS2 --> PUB
    JSTI --> PUB
    PUB --> SHARE["Link de compartilhamento<br/>do SharePoint"]
    SHARE --> PAGES["docs/index.html via GitHub Pages<br/>gated por login Microsoft"]
```

### Estrategia adotada

A extracao base da rodada vem do Power Automate, com os arquivos JSON gravados na pasta de entrada sincronizada. Beneficios:

- separa a extracao do processamento local
- permite usar a mesma base para o `Insight Funil` e para o `Comparativo`
- reduz dependencia de login manual no Power BI para a operacao do dia a dia

## Ambientes

Os envios podem ser separados por ambiente:

### Producao

- Site SharePoint: `https://<seu-tenant>.sharepoint.com/sites/<seu-site>`
- Pasta resumo: `Documentos\Producao\FunilInsights`
- Pasta comparativo: `Documentos\Producao\FunilComparativos`

### Teste

- Site SharePoint: `https://<seu-tenant>.sharepoint.com/sites/<seu-site>`
- Pasta resumo: `Documentos\Teste\FunilInsights_teste`
- Pasta comparativo: `Documentos\Teste\FunilComparativos_teste`

## Regra de Remocao de Ruido (Recotacoes)

Varios pontos do pipeline (`gerar_oportunidades_reais_codes.py`, usado pelo `Insight Funil`, `Comparativo` e `Resumo Mensal Historico`; `analisar_evolucao_diaria_item.py`, usado pela aba `Top Itens`) precisam distinguir uma oportunidade real de uma recotacao — quando o vendedor cria um novo orcamento pra mesma negociacao em vez de reaproveitar o orcamento anterior (ex.: cliente pede ajuste, ou so demora a decidir). Sem esse tratamento, a mesma negociacao contaria como "1 perda + 1 faturado" em vez de 1 negociacao so.

### Agrupamento (cluster)

Orcamentos do mesmo vendedor + mesmo cliente (CNPJ), proximos no tempo (ate `--delta_horas`, padrao 360h / 15 dias) e com itens parecidos (similaridade Jaccard >= `--sim_min`, padrao 0.50), sao agrupados no mesmo cluster — tratados como a mesma negociacao sendo reorcada.

A ordem usada pra saber quem vem "antes"/"depois" dentro do cluster (e pra medir a janela de tempo) e sempre a **Data de Criacao** do orcamento — nunca a Data de Faturamento. Faz sentido porque recotacao e um evento de criacao (o vendedor emitiu um orcamento novo); `Faturou` e so uma bandeira de resultado (sim/nao) de cada orcamento, nao um segundo eixo do tempo.

### Regra por segmento

Dentro do cluster (ja ordenado por Data de Criacao), a sequencia e cortada em segmentos a cada orcamento faturado — um faturado sempre fecha a negociacao ate aquele ponto.

- **Segmento termina em faturado**: esse orcamento conta sempre (enviado + faturado). Tudo que veio antes dele, no mesmo segmento, e ruido — foram versoes descartadas da mesma negociacao que fechou por essa via.
- **Segmento sem faturado** (so acontece no trecho final do cluster, depois do ultimo faturado, ou quando nada faturou ainda): conta so o **mais recente** desse trecho como a oportunidade em aberto atual; os anteriores dele sao ruido — rascunhos ja substituidos por uma versao mais nova da mesma negociacao, ainda sem veredito.

Em uma frase: **um orcamento so vira ruido se existir, no mesmo cluster, um orcamento POSTERIOR (ou no mesmo instante) que faturou.** Um faturado anterior nao conta pra isso — um orcamento criado depois de uma negociacao ja fechada e avaliado do zero, como se fosse o inicio de um cluster novo (pode ser uma recompra/negociacao nova).

Exemplo real (cluster de recompras do mesmo cliente):

| Orcamento | Data de Criacao | Faturou | Resultado |
|---|---|---|---|
| 611593 | 31/07 | Sim | Oportunidade real (faturado) |
| 613419 | 11/08 | Sim | Oportunidade real (faturado) |
| 615315 | 21/08 | Sim | Oportunidade real (faturado) |
| 617298 | 31/08 | Nao | Oportunidade real (em aberto) — nenhum faturado depois dele |

### Uma unica classificacao para as duas visoes (Data de Criacao / Data de Faturamento)

A remocao de ruido roda **uma unica vez**, sempre sobre o historico completo (nao isolada por periodo) — assim uma recotacao e reconhecida mesmo quando a negociacao original ficou fora da janela analisada. As visoes "Data de Criacao" e "Data de Faturamento" (ver "Observacao sobre win rate" abaixo) usam essa mesma classificacao de ruido; diferem so em qual data seleciona quem entra no periodo atual, nao em quem e ruido.

## 1. Fluxo Principal da Rodada (Insight Funil)

Objetivo: gerar o JSON final do resumo executivo do funil e enviar para a pasta de teste ou producao, de onde o Power Automate publica o Adaptive Card no Teams.

### O que o fluxo faz

1. leitura dos arquivos JSON mais recentes gerados pelo Power Automate em `/Entrada/FunilExtracao`
2. tratamento dos arquivos em `entrada/`
3. execucao do pipeline Python
4. geracao do JSON do `Insight Funil`
5. copia do JSON para a pasta sincronizada do SharePoint / Teams
6. disparo do Power Automate para postar o Adaptive Card do insight
7. exibicao do tempo total da rodada

### Arquivos envolvidos

- `rodar_fluxo_funil.ps1`
- `tratar_dax_orcamentos_json_power_automate.py`
- `tratar_dax_itens_json_power_automate.py`
- `automacao_pipeline.py`
- `gerar_resumo_insight_json.py`
- `gerar_top_itens_json.py` — rankings Top 5 por item (aba `Top Itens` do dashboard, ver secao 10)
- `atualizar_dashboard_top_itens_js.py`

### Saidas principais

- `entrada\dax_orcamentos_tratado_power_automate_YYYYMMDD_HHMMSS.xlsx`
- `entrada\dax_itens_tratado_power_automate_YYYYMMDD_HHMMSS.xlsx`
- `historico\oportunidades_reais_auto_YYYYMMDD_HHMMSS.xlsx`
- `historico\itens_perdas_reais_auto_YYYYMMDD_HHMMSS.xlsx`
- `alertas\resumo_insight_card_teams_YYYYMMDD_HHMMSS.json`
- `alertas\top_itens_card_teams_YYYYMMDD_HHMMSS.json`
- `.ultima_base_funil.json` (na raiz do projeto)
  - "bilhete" com o caminho exato do DAX1/DAX2 usados nessa rodada
  - lido pelo `rodar_fluxo_comparativo_funil.ps1` pra garantir que o Comparativo nasca da mesma base (ver Fluxo 2)
  - nao entra no Git (esta no `.gitignore`), e regenerado a cada rodada

### Regra padrao dos nao convertidos

Por padrao, o arquivo `historico\itens_perdas_reais_auto_YYYYMMDD_HHMMSS.xlsx` considera orcamentos com `Faturou = 0`, `Aprovado pelo Cliente = 0` e status de recusa/cancelamento, sem filtrar revisao do gestor.

No arquivo de oportunidades, `Aprovado pelo Cliente` vem da coluna `ETAPA 3 FUNIL Aprovados pelo Cliente`. Portanto, o padrao do step 2 remove da base de nao convertidas os casos que ja foram aprovados pelo cliente mas ainda nao faturaram.

Status considerados em `Base_Nao_Convertidas` e `Itens_Nao_Convertidas`:

- `Cancelado por Inatividade`
- `Orçamento Cancelado`
- `Em confecção`

A configuracao fica em `automacao_config.json`:

```json
"filters": {
  "tipo_perda": "todas"
}
```

Opcoes aceitas pelo script de itens nao convertidos: `todas`, `revisadas`, `sem_revisao`.

### Saida detalhada do step 2

O step 2 gera o arquivo `historico\itens_perdas_reais_auto_YYYYMMDD_HHMMSS.xlsx`.

Abas principais:

- `Base_Nao_Convertidas`: orcamentos com `Faturou = 0`, `Aprovado pelo Cliente = 0` e status de recusa/cancelamento, respeitando `tipo_perda`.
- `Itens_Nao_Convertidas`: itens desses orcamentos.
- `Base_Faturados`: orcamentos com `Faturou = 1`, no mesmo recorte de revisao.
- `Itens_Faturados`: itens dos orcamentos faturados.

Rankings mantidos: `Ranking_Geral_Final`, `Ranking_Geral_Revenda`, `Ranking_Geral_Final_Faturados`, `Ranking_Geral_Revenda_Faturados`, `Ranking_Itens_Por_Vendedor`, `Ranking_Itens_Por_Mes`, `Ranking_Itens_Vendedor_Mes`, abas `Top10_<Vendedor>`.

Abas removidas para simplificar o arquivo: `Ranking_Itens_Geral`, `Ranking_Itens_Geral_Tipo`, `Ranking_NC_Recusa_Tipo`, `Ranking_NC_Recusa_Final`, `Ranking_NC_Recusa_Revenda`, `Base_NC_Recusa_Cliente`, `Itens_NC_Recusa_Cliente`, `Analise_Preco_Recusa`, `Ranking_Itens_Tipo_Faturados`.

### Precos e classificacao no step 2

Colunas de preco nos rankings:

- `Preco_Ponderado`: `Valor_Total / Volume_Total`.
- `Preco_Media_Orcamento`: media dos precos calculados por orcamento.
- `Preco_Mediana_Orcamento`: mediana dos precos calculados por orcamento.

Na aba `Analise_Preco_Itens`, as mesmas visoes aparecem separadas para faturados e nao convertidos.

A `Classificacao_Preco` usa a mediana por orcamento como referencia principal (limite de 3%):

- `Dif_Preco_Mediana_% >= 3%` e `Win_Rate_Item_% < 50%`: `Possivel sensibilidade a preco`.
- `Dif_Preco_Mediana_% >= 3%`: `Atencao: preco nao convertido maior`.
- `Dif_Preco_Mediana_% <= -3%`: `Nao convertido com preco menor`.
- diferenca entre `-3%` e `+3%`: `Preco similar`.
- menos de 3 orcamentos faturados ou menos de 3 nao convertidos: `Amostra insuficiente`.

A media ponderada permanece disponivel como referencia financeira/volume.

### Pipeline tecnico atualmente utilizado

- `step1`: `gerar_oportunidades_reais_codes.py` — consolidacao das oportunidades reais
- `step2`: `gerar_itens_perdas_reais.py` — nao convertidos e rankings de itens

### Arquivos esperados na extracao

- `dax_query_base_orcamentos_funil_yyyyMMdd_HHmmss.json`
- `dax_query_base_itens_funil_yyyyMMdd_HHmmss.json`

### Observacao sobre win rate

- o win rate principal do funil e baseado na `Data de Criacao`
- o pipeline tambem calcula um win rate adicional por `Data de Faturamento`
- nesse segundo recorte, a data considerada por oportunidade e:
  - `Data de Faturamento`, quando existir
  - `Data de Criacao`, quando a data de faturamento estiver em branco
- para auditoria desse segundo recorte, o Excel gera a aba `Lista_WR_Data_Fat`
- as duas leituras compartilham a mesma classificacao de ruido (ver "Regra de Remocao de Ruido" no topo do documento) — diferem so em qual data seleciona quem entra no periodo, nao em quem e ruido
- `Comparativo_Geral_Total` traz a leitura por data de criacao; `Comp_Geral_Total_Data_Fat` traz a leitura por data de faturamento

### Regra de mes comercial no fluxo principal

- o mes comercial fecha no penultimo dia util do mes
- o dia seguinte ao fechamento passa a pertencer ao mes comercial seguinte
- o JSON do `Insight Funil` carrega `titulo`, `mes_comercial`, `periodo`, `atualizado_em`
- isso permite ao Adaptive Card diferenciar o ciclo comercial da rodada da parcela efetivamente analisada ate ontem

### Top Itens (ranking por item, aba do dashboard)

`gerar_top_itens_json.py` reaproveita a leitura/remocao de ruido de `analisar_evolucao_diaria_item.py` (nao duplica logica) e gera rankings Top 5 por item, separados em 2 categorias mutuamente exclusivas por orcamento:

- `Faturado`
- `Enviados_Cliente_Nao_Aprovado` — orcamento foi enviado pra aprovacao do cliente e nunca faturou

Essa classificacao **e diferente** da regra de `Base_Nao_Convertidas` do step 2 (secao acima): aqui nao ha filtro por status especifico de recusa/cancelamento, e a categoria de "nao aprovado" e mais ampla de proposito — a analise e por item (Top 5 por quantidade de orcamentos, volume e valor, faturado x nao aprovado), nao pelo funil inteiro. Roda de forma independente do step 2 e nao e afetada por `-SkipItensPerdas`.

Alimenta a aba `Top Itens` do dashboard (ver secao 10), com ranking, detalhe por orcamento (preco praticado, tipo de cliente, revisao do gestor) e ordenacao clicavel nas colunas.

### Parametros disponiveis

- `-Ambiente Teste|Producao` — define a pasta sincronizada do SharePoint de destino
- `-StartDate YYYY-MM-DD` — define a data inicial da extracao
- `-EndDate YYYY-MM-DD` — define a data final da extracao
- `-NoSharePoint` — gera o JSON final apenas localmente, sem copiar para a pasta sincronizada
- `-NoPublicarDashboard` — gera os `.js` do dashboard (Resumo Atual, Comparativo e Top Itens) apenas localmente, sem copiar para `dashboard_analise_funil_publish_dir` (não afeta a publicação pública via GitHub Pages)

### Comportamento padrao

Se `-StartDate` e `-EndDate` nao forem informados:

- o script usa os arquivos JSON mais recentes disponiveis na pasta de extracao
- inicio = primeiro dia do mes comercial atual, fim = ontem
- o `Insight Funil` e gerado somente com esse recorte, mesmo que a extracao contenha uma janela mais ampla para atender o comparativo

### Comandos

```powershell
cd C:\analise_funil
Set-ExecutionPolicy -Scope Process Bypass
.\rodar_fluxo_funil.ps1 -Ambiente Teste
```

```powershell
.\rodar_fluxo_funil.ps1 -Ambiente Producao
```

```powershell
.\rodar_fluxo_funil.ps1 -Ambiente Teste -NoSharePoint
```

```powershell
.\rodar_fluxo_funil.ps1 -Ambiente Teste -StartDate 2026-03-01 -EndDate 2026-03-06
```

## 2. Fluxo Comparativo

Objetivo: gerar o JSON comparativo entre 2 periodos e enviar para a pasta final de teste ou producao, de onde o Power Automate publica o card comparativo no Teams.

### O que o fluxo faz

1. reaproveita a mesma base da rodada utilizada no `Insight Funil`
2. calcula o periodo atual e o periodo anterior proporcional
3. gera 2 resumos independentes
4. consolida o JSON comparativo
5. copia o JSON para a pasta sincronizada do SharePoint / Teams
6. o Power Automate publica o card comparativo no Teams

### Arquivos envolvidos

- `rodar_fluxo_comparativo_funil.ps1`
- `gerar_comparativo_resumo_insight_periodos.py`
- `gerar_resumo_insight_json.py`

### Regra operacional

O comparativo deve ser gerado e publicado sempre depois do `Insight Funil`.

### Reaproveitamento real da base

Ate pouco tempo atras, cada fluxo (`rodar_fluxo_funil.ps1` e `rodar_fluxo_comparativo_funil.ps1`) buscava
o "arquivo mais recente" na pasta de extracao de forma **independente**, no momento exato em que cada um
rodava. Isso causava uma divergencia real: se o Power Automate atualizasse a extracao entre uma rodada e
outra (ex.: rodar o Insight as 08:28 e o Comparativo as 08:39), os dois cards do Teams mostravam numeros
diferentes pro "periodo atual", mesmo com o rotulo do periodo identico.

Isso foi corrigido:

1. `rodar_fluxo_funil.ps1`, depois de escolher o DAX1/DAX2 da rodada, grava um arquivo `.ultima_base_funil.json`
   na raiz do projeto com o caminho exato desses dois arquivos e o timestamp da rodada.
2. `rodar_fluxo_comparativo_funil.ps1`, antes de buscar o DAX1/DAX2, tenta ler esse "bilhete":
   - se existir, tiver no maximo 6 horas e os arquivos referenciados ainda existirem, usa exatamente
     os mesmos arquivos que o Insight Funil usou na ultima rodada (aparece no console:
     `Reaproveitando a mesma base do Insight Funil (rodada de ...)`);
   - se nao existir, estiver velho ou os arquivos tiverem sumido, cai no comportamento antigo
     (busca o arquivo mais recente na pasta de extracao).

Na pratica, isso garante que **Insight Funil e Comparativo nascam sempre da mesma base**, desde que o
Comparativo rode logo depois do Insight Funil (dentro da mesma janela de 6h) — o que ja e a ordem de
publicacao recomendada.

### Observacao sobre nao convertidas no comparativo

Quando o comparativo executa o pipeline auxiliar, ele tambem respeita a regra padrao de nao convertidas: `Faturou = 0`, `Aprovado pelo Cliente = 0`, status de recusa/cancelamento e `tipo_perda = todas`. A troca entre `Teste` e `Producao` muda apenas o destino de publicacao; a regra de calculo continua a mesma.

### Regra de mes comercial no comparativo

- o comparativo usa a mesma logica de mes comercial do fluxo principal
- o `Periodo Atual` nasce do mes comercial atual, o `Periodo Anterior` nasce do mes comercial anterior
- a equivalencia entre os periodos e feita pela mesma quantidade de dias uteis observados
- o JSON comparativo carrega `comparativo.periodo_a.label`, `comparativo.periodo_a.dias_uteis`, `comparativo.periodo_b.label`, `comparativo.periodo_b.dias_uteis`, `atualizado_em`
- o campo `mes_comercial` tambem e gerado nos resumos-base e no JSON comparativo, mesmo que nao precise ser exibido no card final

### Regra de dias uteis no comparativo

O script considera automaticamente: sabados, domingos, feriados nacionais do Brasil e Sexta-feira Santa.

### Parametros disponiveis

- `-Ambiente Teste|Producao` — define a pasta sincronizada do SharePoint de destino
- `-StartDate YYYY-MM-DD` — opcional; define o inicio do periodo atual
- `-EndDate YYYY-MM-DD` — opcional; define o fim do periodo atual
- `-NoPublicarComparativo` — gera os arquivos localmente, mas nao copia o comparativo para a pasta sincronizada
- `-NoPublicarDashboard` — gera o `.js` do dashboard apenas localmente, sem copiar para `dashboard_analise_funil_publish_dir` (não afeta a publicação pública via GitHub Pages)

### Comportamento padrao

Se `-StartDate` e `-EndDate` nao forem informados:

- inicio = primeiro dia do mes comercial atual, fim = ontem
- `Periodo Atual` = mes comercial atual ate ontem
- `Periodo Anterior` = periodo equivalente dentro do mes comercial anterior, com a mesma quantidade de dias uteis observados no periodo atual

### Comandos

```powershell
cd C:\analise_funil
Set-ExecutionPolicy -Scope Process Bypass
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Teste
```

```powershell
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Producao
```

```powershell
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Teste -StartDate 2026-04-01 -EndDate 2026-04-07
```

```powershell
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Teste -NoPublicarComparativo
```

## 3. Fluxos Power Automate

Recomendacao de organizacao:

- `Fluxo 1 - Extracao DAX Power BI`
  Funcao: executar DAX 1 e DAX 2 e salvar arquivos brutos em `/Entrada/FunilExtracao`.
  Observacao: a extracao deve cobrir a janela necessaria para atender o `Insight Funil` e o `Comparativo` na mesma rodada.

- `Fluxo 2 - Publicacao Insight Diario`
  Funcao: monitorar a pasta final do `Insight Funil` e postar o Adaptive Card no Teams.

- `Fluxo 3 - Publicacao Comparativo`
  Funcao: monitorar a pasta final de comparativo e postar o Adaptive Card comparativo no Teams.

## 4. Resumo Mensal Historico (auxiliar)

Objetivo: gerar uma planilha mensal historica com os mesmos conceitos de remocao de ruido usados no funil principal, sem depender do Excel consolidado da rodada.

### O que o fluxo faz

1. le os arquivos DAX1 e DAX2 diretamente em `json` ou em base tratada
2. aplica a mesma logica de remocao de ruido do `gerar_oportunidades_reais_codes.py` (importada de la, nao duplicada — roda uma unica vez sobre o historico completo da base recebida, nunca isolada por mes)
3. consolida os indicadores `Sem Ruído` por linha mensal
4. permite gerar a visao por mes comercial ou por mes calendario
5. grava a saida em um Excel historico auxiliar

### Arquivos envolvidos

- `gerar_resumo_mensal_funil.py` (script principal)
- `gerar_resumo_mensal_comercial.py` — nome antigo mantido como atalho para compatibilidade

### Saida principal

- `historico\resumo_mensal_funil_YYYYMMDD_HHMMSS.xlsx`, aba `Resumo_Mensal_Funil`, com as colunas:
  `Mês/Ano Comercial`, `Periodo`, `Periodo Completo`, `Enviados_Qtd (Sem Ruído)`, `Enviados_Valor (Sem Ruído)`, `Faturado_Qtd (Sem Ruído)`, `Faturado_Valor (Sem Ruído)`, `Nao_Convertidas_Qtd (Sem Ruído)`, `Nao_Convertidas_Valor (Sem Ruído)`, `Win Rate (Volume) % (Sem Ruído)`, `Win Rate (Valor) % (Sem Ruído)`.
- `Periodo Completo` (booleano): indica se a janela analisada bate exatamente com o mes comercial teorico. Fica `False` quando a base recebida trunca uma das pontas do mes (ex.: extracao comecando no meio do mes, ou mes ainda em andamento) — esses meses nao devem ser tratados como definitivos nem entrar no historico consolidado (ver abaixo).

### Modos disponiveis

- `comercial` — padrao do script; cada linha representa um ciclo comercial
- `calendario` — ativado com `--modo calendario`; cada linha representa um mes calendario civil

### Regras importantes

- `--start` e `--end` limitam a janela total da base analisada
- `--modo` define se a agregacao de cada linha sera comercial ou calendario
- `--excluir-orcamentos 612268,615529` remove numeros de orcamento especificos da analise antes da remocao de ruido — usado para expurgar erro de digitacao/duplicidade sem editar a base bruta
- quando a base nao cobre o ciclo inteiro, o script mantem a linha, marca `Periodo Completo = False` e informa no console os meses parciais
- para o primeiro mes comercial sair completo, a extracao deve comecar antes do inicio do mes alvo
  - ex.: para analisar `Jun/25 a Nov/25` em modo comercial, a extracao deve comecar em `01/05/2025`
  - ex.: para analisar `Dez/25 a Abr/26` em modo comercial, a extracao deve comecar em `01/11/2025`

### Exemplos de uso

```powershell
cd C:\analise_funil
py -3.12 .\gerar_resumo_mensal_funil.py -i ".\entrada\dax1_jan_maio.xlsx" -it ".\entrada\dax2_jan_maio.xlsx" --modo calendario --start 2026-04-01 --end 2026-04-30 -o resumo_calendario_abril
```

```powershell
py -3.12 .\gerar_resumo_mensal_funil.py -i ".\entrada\dax1_jan_maio.xlsx" -it ".\entrada\dax2_jan_maio.xlsx" --start 2026-03-31 --end 2026-04-29 -o resumo_comercial_abril
```

Usando os JSONs mais recentes da pasta de extracao:

```powershell
cd C:\analise_funil
$jsonDir = "C:\CAMINHO\PARA\Entrada\FunilExtracao"
$dax1 = Get-ChildItem -LiteralPath $jsonDir -Filter "dax_query_base_orcamentos_funil_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$dax2 = Get-ChildItem -LiteralPath $jsonDir -Filter "dax_query_base_itens_funil_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
py -3.12 .\gerar_resumo_mensal_funil.py -i $dax1.FullName -it $dax2.FullName --modo calendario --start 2025-12-01 --end 2026-04-30 -o resumo_calendario_dez_abr
```

### Historico consolidado e grafico "Historico" no dashboard

Alem da planilha avulsa acima, existe um pipeline separado que mantem um historico mensal que so cresce (nunca reprocessa o passado inteiro), alimentando o botao **"Historico"** no cabecalho do dashboard — um modal com 2 graficos de area (Volume e Valor de orcamentos, Enviados x Faturados, com a linha de Win Rate numa faixa propria pra nunca sobrepor as areas) dos ultimos 12 meses fechados.

Passos (rodados automaticamente todo dia que o mes comercial fecha — ver secao 9):

1. `gerar_resumo_mensal_funil.py` gera a planilha do(s) mes(es) mais recente(s), a partir dos mesmos arquivos DAX tratados que o Fluxo 1 ja gerou naquele dia (a janela rolante de ~2-3 meses da extracao diaria sempre inclui o mes que acabou de fechar).
2. `atualizar_historico_mensal_consolidado.py -i <planilha>` faz **upsert por mes** (chave = `Mês/Ano Comercial`) em `historico\historico_mensal_consolidado.xlsx` — so aceita linhas com `Periodo Completo = True`, substitui qualquer mes ja existente com o mesmo rotulo, e reordena cronologicamente. Rodar de novo para o mesmo mes e seguro (idempotente).
3. `gerar_historico_mensal_json.py -i historico\historico_mensal_consolidado.xlsx --meses 12` gera o JSON com os ultimos N meses completos (`Enviados`/`Faturados`/`Win Rate`, por volume e por valor).
4. `atualizar_dashboard_historico_js.py` grava `Dashboard Analise Funil\data\historico_dashboard.js`, que e publicado no SharePoint junto com os outros 3 arquivos do dashboard.

Como o mecanismo so alimenta o consolidado a partir do mes em que foi criado, popular meses anteriores exige rodar os 4 passos manualmente contra uma extracao mais ampla do Power Automate (feito uma unica vez, em 2026-09, para cobrir Set/25-Ago/26 — usando duas extracoes DAX com filtro de data mais largo, ja que uma unica extracao nao cobre 12 meses de uma vez).

## 5. Estrutura de Pastas

Sugestao de organizacao:

- Entrada bruta: `/Entrada/FunilExtracao`
- Saida insight teste: pasta configurada em `insight_json_dir` do ambiente `Teste`
- Saida insight producao: pasta configurada em `insight_json_dir` do ambiente `Producao`
- Saida comparativo teste: pasta configurada em `comparativo_json_dir` do ambiente `Teste`
- Saida comparativo producao: pasta configurada em `comparativo_json_dir` do ambiente `Producao`
- Logs da automacao agendada: `logs\` (local, fora do Git, com retencao de 30 dias — ver secao 9)

## 6. Regra de Uso

- `rodar_fluxo_funil.ps1` — quando quiser executar a rodada principal do funil e gerar o `Insight Funil`
- `rodar_fluxo_comparativo_funil.ps1` — quando quiser gerar o comparativo depois da rodada principal
- `rodar_fluxos_diarios.ps1` — roda os dois em sequencia (usado pela automacao agendada, ver secao 9)
- `gerar_resumo_mensal_funil.py` — quando quiser gerar uma visao historica mensal auxiliar da base, em mes comercial ou calendario

Observacao operacional:

- o uso diario normal e automatico via Agendador de Tarefas do Windows (ver secao 9); tambem da pra rodar manualmente a qualquer momento, primeiro `Insight Funil`, depois `Comparativo`
- a extracao base ja deve ter sido gerada pelo Power Automate antes dos comandos locais
- no modo padrao: `Insight Funil` considera mes comercial atual ate ontem; `Comparativo` considera mes comercial atual ate ontem versus periodo equivalente do mes comercial anterior por dias uteis; `Resumo Mensal Funil` usa o modo `comercial`, salvo quando `--modo calendario` for informado

Observacao sobre leitura temporal nos cards:

- no `Insight Funil`, o card mostra: `Mes Comercial`, `Periodo analisado`, `Atualizado em`
- no `Comparativo`, o card mostra: `Periodo Anterior`, `Periodo Atual`, `Atualizado em`

## 7. Resumo Operacional

Sempre comece navegando ate a pasta do projeto e liberando a execucao de script (so vale pra essa janela do PowerShell, nao muda nada permanente):

```powershell
cd C:\analise_funil
Set-ExecutionPolicy -Scope Process Bypass
```

Comandos mais usados no dia a dia:

```powershell
# Fluxo 1 (Insight Funil) - teste rapido, sem publicar nada
.\rodar_fluxo_funil.ps1 -Ambiente Teste -SkipItensPerdas -NoSharePoint

# Fluxo 1 - producao real (posta no Teams, publica no dashboard)
.\rodar_fluxo_funil.ps1 -Ambiente Producao -SkipItensPerdas

# Fluxo 2 (Comparativo) - mesma logica
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Teste -SkipItensPerdas -NoPublicarComparativo
.\rodar_fluxo_comparativo_funil.ps1 -Ambiente Producao -SkipItensPerdas

# Os dois em sequencia (o mesmo comando que a automacao agendada roda)
.\rodar_fluxos_diarios.ps1 -Ambiente Producao

# Limpeza de arquivos antigos (simulacao vs. de verdade)
.\limpar_arquivos_antigos.ps1
.\limpar_arquivos_antigos.ps1 -Executar

# Resumo mensal auxiliar
.\gerar_resumo_mensal_funil.py -i ".\entrada\dax1_jan_maio.xlsx" -it ".\entrada\dax2_jan_maio.xlsx" --modo calendario --start 2026-04-01 --end 2026-04-30 -o resumo_calendario_abril
.\gerar_resumo_mensal_funil.py -i ".\entrada\dax1_jan_maio.xlsx" -it ".\entrada\dax2_jan_maio.xlsx" --start 2026-03-31 --end 2026-04-29 -o resumo_comercial_abril
```

> `-SkipItensPerdas` pula a etapa mais lenta (rankings/itens perdidos, ~5-7min) — seguro de usar porque o JSON final e o dashboard nao dependem dela. Sem esse parametro, o fluxo tambem gera o Excel completo em `historico\itens_perdas_reais_auto_*.xlsx`.

## 8. Integracao com o Power Automate

O PowerShell do `Insight Funil`:

1. gera `resumo_insight_card_teams_...json`
2. copia esse JSON para a pasta sincronizada correta
3. deixa o Power Automate assumir a postagem no Teams

O PowerShell do `Comparativo`:

1. gera os dois resumos localmente
2. monta `comparativo_resumo_insight_card_teams_...json`
3. copia o comparativo para a pasta sincronizada correta
4. deixa o Power Automate assumir a postagem no Teams

## 9. Automacao Agendada (Task Scheduler)

A rodada diaria roda sozinha, via **Agendador de Tarefas do Windows**, sem precisar de comando manual.

### Dependencia do Power Automate

O fluxo do Power Automate que extrai as consultas DAX roda de **segunda a sexta, as 7:30** (horario de Brasilia). A automacao local so faz sentido rodar depois disso — nao ha extracao nova aos fins de semana.

### `rodar_fluxos_diarios.ps1`

Script wrapper que roda o `Insight Funil` e, se terminar sem erro, na sequencia o `Comparativo` — ambos com `-SkipItensPerdas` (a etapa de itens/rankings nao e usada pelo JSON final nem pelo dashboard, entao pular ela deixa a rodada bem mais rapida). Se o Fluxo 1 falhar, o Fluxo 2 nao roda.

Depois que os dois fluxos terminam com sucesso, roda mais dois passos, ambos so-leitura/gravacao local (nenhum dos dois refaz a extracao):

- **Snapshot mensal** (`Arquivar-SnapshotMensalSeFechou`): verifica se o mes comercial fechou ontem (mesma regra de penultimo dia util usada no resto do projeto). Se fechou, arquiva uma copia dos 3 JSONs publicados naquele dia — Resumo Atual, Top Itens, Comparativo — em `historico\snapshots_mensais\<AAAA-MM>\` (pensado para, no futuro, permitir "retroceder" as 3 abas do dashboard para um mes fechado).
- **Historico consolidado** (`Atualizar-HistoricoMensalConsolidado`): reaproveitando os mesmos arquivos DAX que o Fluxo 1 acabou de tratar, roda a cadeia descrita na secao 4 (`gerar_resumo_mensal_funil.py` → `atualizar_historico_mensal_consolidado.py` → `gerar_historico_mensal_json.py` → `atualizar_dashboard_historico_js.py`) e publica o resultado no SharePoint.

Na maioria dos dias o mes nao fechou, entao esses dois passos so imprimem um aviso e nao fazem nada. Se algum dos dois falhar, fica so um aviso no log — nao afeta os dados ja publicados pelos Fluxos 1 e 2.

Cria a pasta `logs\` automaticamente e grava um log timestampado de cada execucao (`logs\agendamento_fluxos_YYYYMMDD_HHMMSS.log`, via `Start-Transcript`), com tudo que apareceria na tela numa rodada manual — inclusive erros.

Uso manual (se quiser rodar fora do horario agendado):

```powershell
cd C:\analise_funil
.\rodar_fluxos_diarios.ps1 -Ambiente Producao
```

### Tarefa 1 — `AnaliseFunil_FluxosDiarios`

- Disparador: semanalmente, segunda a sexta, **08:15**
- Acao: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\analise_funil\rodar_fluxos_diarios.ps1" -Ambiente Producao`
- Iniciar em: `C:\analise_funil`
- "Executar somente quando o usuario estiver conectado" (nao guarda senha)
- "Reativar o computador para executar esta tarefa" marcado (funciona mesmo com o PC suspenso)
- "Executar a tarefa o mais cedo possivel apos uma inicializacao agendada perdida" marcado (se o PC estiver desligado no horario, roda assim que ligar)

### `limpar_arquivos_antigos.ps1`

Apaga arquivos com mais de N dias (padrao **30**) de `entrada\`, `historico\`, `alertas\`, `logs\` e `.run_guard\` — as pastas que crescem sem parar a cada rodada. Roda em **modo simulacao por padrao** (so mostra o que apagaria); precisa da flag `-Executar` pra apagar de verdade.

```powershell
cd C:\analise_funil
.\limpar_arquivos_antigos.ps1              # simulacao, 30 dias
.\limpar_arquivos_antigos.ps1 -Executar     # apaga de verdade
.\limpar_arquivos_antigos.ps1 -DiasRetencao 60 -Executar   # outro periodo
```

### Tarefa 2 — `AnaliseFunil_LimparArquivosAntigos`

- Disparador: mensalmente, dia 1, **07:00**
- Acao: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { $logFile = 'C:\analise_funil\logs\limpeza_' + (Get-Date -Format yyyyMMdd_HHmmss) + '.log'; & '.\limpar_arquivos_antigos.ps1' -Executar *>&1 | Tee-Object -FilePath $logFile }"`
- Mesmas configuracoes de condicoes/configuracoes da Tarefa 1

### Conferindo se rodou

Abra `C:\analise_funil\logs\` — cada execucao (dos fluxos ou da limpeza) gera um arquivo novo com timestamp no nome. Se o texto final for `"Fluxo 1 e Fluxo 2 concluidos com sucesso."`, deu tudo certo; se parar no meio com `"ERRO no Fluxo 1: ..."` ou `"ERRO no Fluxo 2: ..."`, o log mostra onde falhou.

## 10. Publicacao publica (GitHub Pages)

O dashboard interativo (`Dashboard Analise Funil\dashboard_analise_funil.dc.html`, com as abas `Resumo Atual`, `Comparativo` e `Top Itens`) tem uma versao publicada de verdade, acessivel por link, sem precisar estar na maquina local.

### Como funciona

- `rodar_fluxo_funil.ps1` copia `resumo_insight_dashboard.js` e `top_itens_dashboard.js`; `rodar_fluxo_comparativo_funil.ps1` copia `comparativo_dashboard.js` — os 3 gerados a cada rodada e copiados pra pasta configurada em `paths.dashboard_analise_funil_publish_dir` (pasta do SharePoint) — a menos que `-NoPublicarDashboard` seja informado.
- A pasta `docs\` na raiz do repositorio contem a versao publicavel do HTML (copia de `Dashboard Analise Funil\dashboard_analise_funil.dc.html`), hospedada via **GitHub Pages**.
- Em vez de carregar os dados de um arquivo local (`./data/*.js`), o `docs\index.html` aponta os 3 `<script src>` (`comparativo_dashboard.js`, `resumo_insight_dashboard.js`, `top_itens_dashboard.js`) pra **URLs de compartilhamento do SharePoint** dos arquivos publicados.
- Isso funciona porque uma tag `<script src>` nao passa pelas travas de CORS que um `fetch()` teria — o navegador carrega o arquivo como um recurso normal, e o cookie de sessao do SharePoint e enviado junto. Resultado: **o link e publico, mas os dados so aparecem pra quem estiver logado na conta Microsoft da empresa** — sem login, o SharePoint bloqueia e nenhum dado carrega.
- Se qualquer uma das 3 fontes nao carregar (falha de login, link expirado, etc.), a pagina mostra um modal explicando que e preciso estar logado, com um botao pra recarregar depois de logar. O dashboard fica com `visibility:hidden` ate as 3 fontes confirmarem sucesso — assim nunca aparece um flash do layout sem dado antes do modal.

### O que isso depende

- Os `.ps1` continuarem publicando os 3 `.js` em `dashboard_analise_funil_publish_dir` a cada rodada — sem isso, a pagina publica fica com dado desatualizado.
- Os links de compartilhamento do SharePoint embutidos no `docs\index.html` continuarem validos — se forem revogados/expirarem, e preciso gerar novos links e atualizar os `<script src>` no arquivo.
- O GitHub Pages estar habilitado nas configuracoes do repositorio (Settings → Pages → Branch `main`, pasta `/docs`).

### Limitacao atual

Como `docs\index.html` e uma copia estatica do `.dc.html`, qualquer mudanca visual feita no dashboard local precisa ser replicada manualmente em `docs\index.html` (trocando so os 3 `<script src>` de volta pros links do SharePoint, mais o bloco do modal de sem-acesso e o gate de `dashboardVisible`) pra a versao publica acompanhar.

## 11. Publicando uma mudanca de codigo

Depois de editar qualquer arquivo do projeto:

```bash
cd C:\analise_funil
git status
git add nome_do_arquivo
git commit -m "Descricao da mudanca"
git push -u origin main
```

Antes de commitar, vale checar que nao vazou nada sensivel:

```bash
git diff --cached --name-only -z | xargs -0 grep -lI "erico.moraes\|BUNZL"
```

## 12. Observacoes importantes

- hoje a operacao normal nao depende de login manual no Power BI, porque a extracao base vem do Power Automate
- a postagem no Teams hoje acontece via Power Automate
- o fluxo de resumo e o fluxo comparativo podem apontar para canais diferentes no Teams
- o comparativo automatico usa dias uteis automaticamente no modo padrao
- a extracao do Power Automate hoje pode trazer uma janela ampliada para atender resumo e comparativo na mesma rodada, mas o recorte efetivo de cada card e definido pelos scripts locais
- no fim de cada rodada os scripts exibem os principais arquivos gerados
- desde a correcao do `.ultima_base_funil.json`, o Insight Funil e o Comparativo sempre nascem da mesma
  base de extracao (contanto que o Comparativo rode ate 6h depois do Insight Funil)
- a aba `Top Itens` do dashboard (secao 1 e 10) nao depende do step 2 (`itens_perdas`) nem e afetada por
  `-SkipItensPerdas` — a remocao de ruido e feita internamente pelo proprio `gerar_top_itens_json.py`
- a rodada diaria (seg-sex, 08:15) roda sozinha via Agendador de Tarefas do Windows, chamando
  `rodar_fluxos_diarios.ps1`; a limpeza de arquivos antigos roda mensalmente (dia 1, 07:00) — ver secao 9
- a identidade do Git usada nos commits deve ser `Erico Casarano <erico.casarano@exemplo.com>` — se um
  commit sair com outro autor (ex.: e-mail corporativo real), corrija antes de publicar
  (`git commit --amend --author="Erico Casarano <erico.casarano@exemplo.com>"`, so em commits ainda nao
  enviados ao GitHub)
