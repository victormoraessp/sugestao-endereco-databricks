# Valuation do Golden Record de Telefone Celular

Pacote de SQL (Databricks) que responde, sem teste A/B e com significância estatística, a pergunta:

> **Se o CRM Salesforce passasse a usar o telefone ranking 1 do Golden Record, os SMS chegariam mais?**
> E, em particular: **dos SMS que não foram entregues, quantos teriam ido para outro número se o Golden Record tivesse sido usado?**

O resultado é uma faixa de **entregas incrementais** (piso, número central, teto) e uma contagem de **clientes hoje inalcançáveis que ganhariam um telefone novo**, prontos para multiplicar por valor unitário na etapa de valuation.

---

## 1. A ideia em um parágrafo

Não dá para fazer A/B. Mas o Golden Record (GR) foi construído a partir de fontes que **não têm nada a ver com o CRM**. Então, quando o CRM disparou um SMS e, por coincidência, usou exatamente o telefone que o GR recomendaria, temos uma observação real de "o que acontece quando se envia para o telefone do GR". Quando usou outro número, temos o contrafactual. Ninguém escolheu esses grupos com base no resultado, o que faz disso um **experimento natural**. O trabalho estatístico é garantir que os dois grupos são comparáveis. Fazemos isso de três formas independentes (mesma campanha, mesmo cliente, recortes de robustez). Se as três apontarem na mesma direção, a conclusão é defensável.

---

## 2. Como rodar

| Passo | Arquivo | O que produz | Tempo típico |
|---|---|---|---|
| 0 | `00_setup_funcoes.sql` | Funções estatísticas (CDF Normal, p-valor, IC de Wilson) e parâmetros | segundos |
| 1 | `01_preparacao_bases.sql` | Base analítica: cada envio do CRM lado a lado com o telefone do GR | pesado (join de milhões) |
| 2 | `02_diagnostico_cobertura.sql` | Qualidade, cobertura, concordância, tamanho das campanhas, checagem de seleção | médio |
| 3 | `03_experimento_natural_concordancia.sql` | **Lente 1**: concordante x discordante, bruto e controlado por campanha (CMH) | médio |
| 4 | `04_pareado_intra_cpf.sql` | **Lente 2**: mesmo cliente, telefones diferentes (McNemar) | médio |
| 5 | `05_insucesso_e_se_golden_record.sql` | **Lente 3**: insucessos que teriam outro telefone; ganhos, perdas, saldo, tabela por campanha | médio |
| 6 | `06_robustez_por_campanha.sql` | Placar por campanha, teste do sinal, recortes de sensibilidade | médio |
| 7 | `07_resumo_executivo.sql` | Uma tabela com todos os números para o slide | segundos |

**Antes de rodar:**

1. Em `01_preparacao_bases.sql`, bloco 1.0, troque `temp_view_crm_sms` pelo nome real da tabela de campanhas de SMS. É o único lugar a ajustar. A view `temp_view_golden_record` é usada como está.
2. Rode os scripts **na ordem, na mesma sessão** (temp views e temp functions morrem com a sessão).
3. Em notebook, cada `SELECT * FROM vt_res_...` deve ficar em uma célula própria para exibir o resultado. No SQL Editor, o painel mostra o resultado do último comando; use as views `vt_res_*` para consultar qualquer resultado depois.
4. Com centenas de milhões de envios, materialize a base analítica como tabela Delta (bloco 1.8 do script 01). Tudo o que vem depois lê dela.
5. Se o workspace bloquear `CREATE TEMPORARY FUNCTION`, crie as funções do script 00 como funções permanentes em um schema e prefixe as chamadas.

**Convenções:** views intermediárias começam com `vt_`; views de resultado com `vt_res_NN_`; parâmetros ficam em `vt_parametros`.

---

## 3. O storytelling, capítulo a capítulo

Cada capítulo tem a pergunta, onde está a resposta, como ler e uma frase-modelo para o slide (preencha os `[...]` com os números da view).

### Capítulo 1. Em que chão estamos pisando (script 02)

**Pergunta:** o GR cobre quem o CRM tenta contatar? O CRM já usa o telefone do GR sem saber?

| Resultado | View | Como ler |
|---|---|---|
| Registros descartados por status ambíguo ou chave inválida | `vt_res_02_qualidade` | Reduz cobertura, não invalida o experimento |
| Cobertura do GR por envio e por CPF | `vt_res_02_cobertura` | Teto da oportunidade |
| Concordância atual (igual exato, igual só de formato, diferente) | `vt_res_02_concordancia` | `DIFERENTE` é onde o GR pode mudar algo |
| Campanhas por faixa de volume | `vt_res_02_faixas_campanha` | Justifica a análise estratificada |
| Entrega de quem tem GR x quem não tem | `vt_res_02_selecao` | Validade externa: para quem o resultado vale |

**Frase-modelo:** "O Golden Record tem telefone para `[X]%` dos disparos do CRM. Em `[Y]%` desses disparos o CRM já usa, sem saber, o mesmo telefone do GR; em `[Z]%` o GR apontaria outro número."

### Capítulo 2. Quando o CRM usou o telefone do GR, entregou mais? (script 03)

**Pergunta:** a taxa de entrega é maior no braço concordante?

| Resultado | View | Como ler |
|---|---|---|
| Comparação bruta com IC 95% e p-valor | `vt_res_03_bruto` | Primeira resposta; sujeita a confundimento |
| Comparação **dentro de cada campanha**, somada (CMH) | `vt_res_03_cmh` | **O número defensável.** Controla período, mensagem e público |
| Quantas campanhas entraram | `vt_res_03_estratos_diag` | Transparência |

**Frase-modelo:** "Controlando por campanha, disparos para o telefone do GR entregam `[D]` pontos percentuais a mais (odds ratio `[OR]`, IC 95% `[a ; b]`, p `[<0,001]`), em `[N]` campanhas e `[M]` milhões de envios."

### Capítulo 3. O mesmo cliente, dois telefones (script 04)

**Pergunta:** para clientes que receberam SMS nos dois telefones, qual chegou?

| Resultado | View | Como ler |
|---|---|---|
| Universo pareado | `vt_res_04_universo` | Quantos clientes permitem a comparação |
| McNemar, 1 envio por braço | `vt_res_04_mcnemar` | `b` (só GR chegou) contra `c` (só outro chegou) |
| Diferença média das taxas por CPF | `vt_res_04_diferenca_media` | Usa todos os envios |
| Mesma campanha, mesmo cliente | `vt_res_04_mcnemar_mesma_campanha` | Mais rigoroso, menor volume |

**Frase-modelo:** "Em `[N]` clientes contatados nos dois telefones, o do GR chegou e o outro não em `[b]` casos; o contrário aconteceu em `[c]`. A chance de isso ser acaso é `[p]`."

### Capítulo 4. E se tivéssemos usado o GR nos insucessos? (script 05)

Esta é a análise pedida explicitamente. A premissa "telefone diferente = sucesso" é apresentada como **cenário TETO** e nunca sozinha.

| Resultado | View | Como ler |
|---|---|---|
| Anatomia do insucesso (GR igual / diferente / sem GR), por envio e por CPF | `vt_res_05_anatomia_insucesso` | Quantos insucessos o GR poderia mudar |
| Evidência direta: o telefone do GR já foi testado e chegou? | `vt_res_05_evidencia_direta` | A prova mais forte sem A/B |
| Ganhos por cenário (TETO, CALIBRADO, EVIDÊNCIA DIRETA, PISO) | `vt_res_05_ganhos` | Do otimista ao conservador |
| Perdas por cenário (telefones que funcionam e seriam trocados) | `vt_res_05_perdas` | Honestidade obrigatória |
| **Saldo líquido por cenário** | `vt_res_05_saldo_liquido` | **Tabela principal do valuation** |
| Tabela por campanha | `vt_res_05_valuation_por_campanha` | Valor por campanha |
| Clientes hoje inalcançáveis com telefone novo no GR | `vt_res_05_cpfs_recuperaveis` | Ativo de cadastro |

**Frase-modelo:** "Dos `[N]` SMS não entregues, em `[X]%` o Golden Record apontaria um telefone diferente. No cenário teto isso equivale a `[T]` entregas recuperadas; aplicando a taxa real de entrega do telefone do GR na mesma campanha, `[C]` entregas líquidas (já descontadas `[P]` que seriam perdidas ao trocar telefones que funcionam). Para `[K]` desses clientes o telefone do GR já foi usado em outra campanha e chegou."

### Capítulo 5. Isso se repete em todo lugar? (script 06)

| Resultado | View | Como ler |
|---|---|---|
| Placar campanha a campanha | `vt_res_06_por_campanha` | Quem venceu em cada uma, com p-valor |
| Teste do sinal | `vt_res_06_teste_sinal` | "GR venceu em `[X]%` das campanhas" |
| Por faixa de volume | `vt_res_06_por_faixa_volume` | Não é só a campanha gigante |
| Sem a maior campanha | `vt_res_06_sem_maior_campanha` | Idem |
| Regra exata de comparação | `vt_res_06_regra_exata` | Não é artefato de formatação |
| Por frequência de contato | `vt_res_06_por_frequencia_cpf` | Não é só cliente engajado |

**Frase-modelo:** "O telefone do GR venceu em `[X]%` das `[N]` campanhas com volume suficiente (p `[...]`), em todas as faixas de volume e mesmo excluindo a maior campanha."

### Capítulo 6. A tabela do slide (script 07)

`vt_res_07_resumo_executivo` traz os blocos A (oportunidade), B (evidência), C (robustez) e D (valuation) com uma leitura por linha e a view de origem de cada número.

---

## 4. Para quem é cada explicação

**Analista júnior.** Comparar taxa de entrega de dois grupos: SMS que foram para o telefone do GR e SMS que foram para outro telefone. Se o primeiro grupo entrega mais e o p-valor é menor que 0,05, a diferença não é sorte. Depois checar que isso vale campanha a campanha e cliente a cliente. Por fim, contar quantos insucessos teriam outro telefone e multiplicar por uma taxa de sucesso realista.

**Analista sênior.** Desenho quase-experimental com alocação por coincidência de fontes independentes (sem vazamento de rótulo). Estimativa principal por Cochran-Mantel-Haenszel estratificado por campanha (OR e RD ponderados, IC pela variância de Robins-Breslow-Greenland). Triangulação com desenho pareado intra-CPF (McNemar com sorteio determinístico de exposição). Sensibilidade por faixa de volume, exclusão da maior campanha, regra de comparação e frequência de contato. Contrafactual do insucesso calibrado pela taxa do braço concordante na mesma campanha, com piso por evidência direta e desconto explícito das perdas por troca. Limitações declaradas em `METODOLOGIA.md`.

**Diretor.** Quatro perguntas. (A) O GR alcança `[X]%` dos disparos e discorda do telefone atual em `[Z]%`. (B) Quando usamos o telefone do GR, o SMS chega `[D]` p.p. a mais, com significância estatística e controlando por campanha. (C) Isso se repete em `[X]%` das campanhas. (D) Usar o GR renderia entre `[piso]` e `[teto]` entregas a mais, com número central `[C]`, e daria telefone novo a `[K]` clientes hoje inalcançáveis.

---

## 5. Premissas e limitações (e como cada uma foi tratada)

| Premissa / risco | Por que existe | Mitigação no pacote | O que ainda fica em aberto |
|---|---|---|---|
| Independência GR x CRM | O GR não usa fontes nem resultados do CRM | É a base do experimento natural; não há vazamento de rótulo | Confirmar por escrito com o time do GR |
| Concordância correlacionada com "cliente bom" | Telefones que coincidem entre fontes podem ser de cadastros mais saudáveis | Controle por campanha (03), por pessoa (04), por frequência (06.6) | Confundidores fora desses eixos |
| Seleção: só CPFs com GR são analisados | Sem GR não há contrafactual | `vt_res_02_selecao` mede se o grupo com GR já entrega diferente | Extrapolar para quem não tem GR é premissa declarada |
| Tempo: o GR de hoje x o envio de ontem | O telefone do GR pode ter mudado depois do disparo | Não há data de envio no layout informado | Se houver `data_envio`, filtrar envios após `data_ingestao_gr` |
| "Telefone diferente = sucesso" | Premissa pedida, otimista | Apresentada como TETO ao lado de CALIBRADO, EVIDÊNCIA DIRETA e PISO | Nenhuma: a faixa resolve o ataque |
| Trocar telefone que funciona | Usar o GR também substitui números bons | `vt_res_05_perdas` desconta isso em todos os cenários | Estratégia real pode ser "GR só onde o CRM falhou", o que elimina as perdas |
| Formatação (nono dígito, DDI) | Mesmo número escrito diferente | Regra tolerante + sensibilidade com regra exata (06.5) | DDI diferente de 55 só compara exato |
| Campanhas minúsculas | 10 a 100 envios geram ruído | CMH pesa por tamanho; tabela por campanha exige mínimo por braço | Nenhuma |

---

## 6. Ponte para o valuation

```
valor_entregas   = entregas_liquidas[cenário]  x  valor_por_SMS_entregue
valor_contatos   = inalcancaveis_com_gr_novo_nao_testado  x  taxa_calibracao  x  valor_por_cliente_reativado
```

- Use **CALIBRADO_CAMPANHA** como número central, **PISO_EVIDENCIA_DIRETA** como pior caso defensável e **TETO** como melhor caso.
- Se a estratégia de uso do GR for "substituir só onde o CRM falhou" (e não substituir tudo), as perdas de `vt_res_05_perdas` caem a zero e o saldo vira o próprio ganho.
- `vt_res_05_valuation_por_campanha` permite valorar por campanha, por faixa ou por período.
- O p.p. incremental de `vt_res_05_saldo_liquido` pode ser aplicado a volumes futuros de disparo para projetar o valor anual.

---

## 7. Template de resultados

| # | Indicador | Valor | Fonte |
|---|---|---|---|
| A1 | Envios válidos analisados | | `vt_res_07_resumo_executivo` |
| A2 | Cobertura do GR (envios) | % | |
| A4 | Envios em que o GR discorda do telefone usado | % | |
| A5 | Insucessos em que o GR discorda | % | |
| B12 | Diferença bruta (p.p., p-valor) | | |
| B13 | Diferença CMH por campanha (p.p., OR, IC, p-valor) | | |
| B14 | McNemar pareado (b, c, p-valor) | | |
| C20 | % campanhas em que o GR venceu (p-valor do sinal) | | |
| D31 | Entregas líquidas TETO | | |
| D33 | Entregas líquidas CALIBRADO_CAMPANHA | | |
| D35 | Entregas líquidas PISO | | |
| D40 | CPFs inalcançáveis com telefone novo no GR | | |

---

## 8. Glossário

- **Golden Record (GR):** base de telefones com ranking de qualidade por CPF; usamos só ranking 1, ingestão mais recente.
- **Concordante:** envio cujo telefone é o mesmo que o GR indicaria (exato ou tolerante).
- **Discordante:** envio cujo telefone é diferente do GR.
- **Experimento natural:** comparação em que a alocação aos grupos ocorreu por um mecanismo alheio ao resultado.
- **CMH (Cochran-Mantel-Haenszel):** teste que compara dois grupos dentro de cada estrato (campanha) e agrega, pesando pelo tamanho.
- **McNemar:** teste para pares (mesmo cliente, dois telefones) que só olha os pares em que os resultados discordam.
- **IC de Wilson:** intervalo de confiança de proporção que funciona bem em amostras pequenas e taxas perto de 0 ou 100%.
- **p-valor:** probabilidade de ver uma diferença tão grande quanto a observada se não houvesse diferença real. Menor que 0,05 = significante.
- **p.p.:** pontos percentuais.

---

## 9. Inventário de views

| View | Script | Conteúdo |
|---|---|---|
| `vt_parametros` | 00 | limiares |
| `vt_gr_rank1` | 01 | 1 telefone por CPF do GR |
| `vt_crm_envios_raw`, `vt_crm_envios_qualidade`, `vt_crm_envios` | 01 | CRM limpo, por etapa |
| `vt_base_analitica` | 01 | envio x GR, com classe de concordância |
| `vt_experimento` | 01 | só envios com GR |
| `vt_campanha_volume` | 01 | volumetria por campanha |
| `vt_estratos_campanha` | 03 | tabela 2x2 por campanha |
| `vt_taxa_concordante_campanha` | 03 | p1_k para calibração |
| `vt_pareado_cpf`, `vt_pareado_1por_braco` | 04 | universo pareado |
| `vt_gr_observado_no_crm`, `vt_envios_gr_diferente` | 05 | evidência direta e candidatos |
| `vt_res_*` | 02 a 07 | resultados |
