/* =============================================================================
   VALUATION TELEFONE  |  05_insucesso_e_se_golden_record.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   LENTE 3, a pergunta de negócio pedida explicitamente:
     "Dado um SMS que NÃO foi entregue, se eu tivesse usado o telefone do
      Golden Record, ele seria DIFERENTE do que foi usado? E se sim, quantas
      entregas eu teria recuperado?"
   Entrega cinco cenários, do mais otimista ao mais conservador, e o saldo
   líquido (ganhos - perdas) de trocar para o telefone do GR:
     5.1 anatomia do insucesso (GR igual x GR diferente), por envio e por CPF
     5.2 evidência direta: o telefone do GR já foi testado em outra campanha?
     5.3 GANHOS: entregas recuperadas por cenário
     5.4 PERDAS: entregas que seriam perdidas ao trocar um telefone que funciona
     5.5 SALDO LÍQUIDO por cenário
     5.6 tabela por campanha (insumo do valuation)
     5.7 visão por CPF: clientes hoje inalcançáveis para os quais o GR tem
         outro telefone

   SOBRE A PREMISSA "TELEFONE DIFERENTE = SUCESSO"
   ----------------------------------------------
   Essa premissa é o cenário TETO (ordem 1). Ela é deliberadamente otimista e
   está aqui porque foi pedida e porque define o limite superior. Para que
   ninguém a ataque como "falácia", ela NUNCA é apresentada sozinha: ao lado
   dela vêm o cenário CALIBRADO (aplica a taxa de entrega que o telefone do
   GR de fato tem quando é usado, medida no script 03) e o cenário de
   EVIDÊNCIA DIRETA (para o mesmo CPF, o CRM já disparou para o telefone do
   GR em outra campanha: chegou ou não?). O intervalo PISO..TETO é o
   argumento; o CALIBRADO é o número central para o valuation.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   Filtramos só SMS não entregues. Para cada um, olhamos se o GR
              indicaria outro telefone. Os que indicariam outro telefone são
              "candidatos a recuperação". Depois multiplicamos os candidatos
              por uma taxa de sucesso: 100% (teto), a taxa real do telefone
              do GR (calibrado) ou o que já foi observado (evidência direta).
   [SÊNIOR]   O contrafactual correto para um insucesso na campanha k é a
              taxa de entrega do telefone do GR NA MESMA campanha k (p1_k),
              com fallback para a taxa global quando a campanha não tem
              braço concordante. Isso ancora a estimativa na mesma janela e
              mensagem. A evidência direta usa o CPF como controle e é o
              cenário menos atacável, mas cobre só quem já teve o telefone do
              GR usado. As perdas (5.4) são obrigatórias para honestidade: o
              GR também substituiria telefones que estão funcionando.
   [EXECUTIVO] Leia a tabela 5.5: para cada cenário, quantas entregas a mais
              (ou a menos) teríamos se o CRM usasse o telefone do GR. O
              valuation multiplica ENTREGAS_LIQUIDAS do cenário CALIBRADO
              pelo valor de uma entrega de SMS. O TETO serve como
              "melhor caso" e o PISO como "pior caso defensável".
   ============================================================================= */


/* -----------------------------------------------------------------------------
   5.0  INSUMOS
   -----------------------------------------------------------------------------
   vt_gr_observado_no_crm      : por CPF, o CRM já usou o telefone do GR?
                                 (concordante = 1 em algum envio) e com que
                                 resultado.
   vt_taxa_concordante_global  : taxa de entrega do telefone do GR (p1), toda
                                 a base.
   vt_envios_gr_diferente      : todos os envios em que o GR indicaria OUTRO
                                 telefone (sucessos e insucessos), já com a
                                 taxa de calibração p1_k e a evidência direta.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_observado_no_crm AS
SELECT
  cpf,
  count(*)        AS gr_n_envios,
  max(entregue)   AS gr_alguma_entrega,
  avg(entregue)   AS gr_taxa_entrega
FROM vt_experimento
WHERE concordante = 1
GROUP BY cpf
;

CREATE OR REPLACE TEMP VIEW vt_taxa_concordante_global AS
SELECT
  avg(CASE WHEN concordante = 1 THEN entregue END) AS p1_global,
  avg(CASE WHEN concordante = 0 THEN entregue END) AS p0_global
FROM vt_experimento
;

CREATE OR REPLACE TEMP VIEW vt_envios_gr_diferente AS
SELECT
  e.cpf,
  e.campanha,
  e.telefone_crm,
  e.telefone_gr,
  e.entregue,
  o.gr_n_envios,
  o.gr_alguma_entrega,
  o.gr_taxa_entrega,
  CASE
    WHEN o.cpf IS NULL             THEN 'GR_NUNCA_TESTADO'
    WHEN o.gr_alguma_entrega = 1   THEN 'GR_TESTADO_ENTREGOU'
    ELSE                                'GR_TESTADO_NAO_ENTREGOU'
  END                                                AS evidencia_direta,
  coalesce(t.taxa_concordante_k, g.p1_global)        AS p1_k,
  g.p1_global
FROM vt_experimento e
LEFT JOIN vt_gr_observado_no_crm o        ON e.cpf = o.cpf
LEFT JOIN vt_taxa_concordante_campanha t  ON e.campanha = t.campanha
CROSS JOIN vt_taxa_concordante_global g
WHERE e.classe_concordancia = 'DIFERENTE'
;


/* -----------------------------------------------------------------------------
   5.1  ANATOMIA DO INSUCESSO
   -----------------------------------------------------------------------------
   Pergunta: dos SMS não entregues, em quantos o GR indicaria outro telefone?
   GR_IGUAL     : o GR teria usado o MESMO telefone -> o GR não muda nada aqui
   GR_DIFERENTE : o GR teria usado OUTRO telefone   -> candidato a recuperação
   SEM_GR       : CPF não está no GR                -> fora do alcance do GR
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_anatomia_insucesso AS
SELECT
  'ENVIO' AS grao,
  count(*)                                                                    AS insucessos_total,
  sum(CASE WHEN NOT tem_gr THEN 1 ELSE 0 END)                                 AS sem_gr,
  sum(CASE WHEN classe_concordancia IN ('IGUAL_EXATO','IGUAL_TOLERANTE') THEN 1 ELSE 0 END) AS gr_igual,
  sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)          AS gr_diferente,
  round(100.0 * sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END) / count(*), 4)
                                                                              AS pct_gr_diferente_sobre_total,
  round(100.0 * sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)
              / nullif(sum(CASE WHEN tem_gr THEN 1 ELSE 0 END), 0), 4)        AS pct_gr_diferente_sobre_com_gr
FROM vt_base_analitica
WHERE entregue = 0
UNION ALL
SELECT
  'CPF' AS grao,
  count(DISTINCT cpf)                                                         AS insucessos_total,
  count(DISTINCT CASE WHEN NOT tem_gr THEN cpf END)                           AS sem_gr,
  count(DISTINCT CASE WHEN classe_concordancia IN ('IGUAL_EXATO','IGUAL_TOLERANTE') THEN cpf END) AS gr_igual,
  count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END)    AS gr_diferente,
  round(100.0 * count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END)
              / count(DISTINCT cpf), 4)                                       AS pct_gr_diferente_sobre_total,
  round(100.0 * count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END)
              / nullif(count(DISTINCT CASE WHEN tem_gr THEN cpf END), 0), 4)  AS pct_gr_diferente_sobre_com_gr
FROM vt_base_analitica
WHERE entregue = 0
;
SELECT * FROM vt_res_05_anatomia_insucesso;


/* -----------------------------------------------------------------------------
   5.2  EVIDÊNCIA DIRETA sobre os candidatos a recuperação
   -----------------------------------------------------------------------------
   Pergunta: para os insucessos em que o GR indicaria outro telefone, esse
   telefone do GR já foi usado pelo CRM (em outra campanha) para o mesmo CPF?
   Se sim, chegou?
   Leitura: GR_TESTADO_ENTREGOU é a prova mais forte possível sem A/B:
   "para este cliente, o telefone que falhou não é o do GR, e o do GR já
   provou que chega".
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_evidencia_direta AS
SELECT
  evidencia_direta,
  count(*)                                                AS insucessos_gr_diferente,
  round(100.0 * count(*) / sum(count(*)) OVER (), 4)      AS pct,
  count(DISTINCT cpf)                                     AS cpfs,
  round(100.0 * avg(gr_taxa_entrega), 4)                  AS taxa_entrega_media_do_telefone_gr_pct
FROM vt_envios_gr_diferente
WHERE entregue = 0
GROUP BY evidencia_direta
ORDER BY insucessos_gr_diferente DESC
;
SELECT * FROM vt_res_05_evidencia_direta;


/* -----------------------------------------------------------------------------
   5.3  GANHOS: entregas recuperadas por cenário
   -----------------------------------------------------------------------------
   ordem 1  TETO                 : 100% dos candidatos viram entrega (premissa
                                   pedida; limite superior).
   ordem 2  CALIBRADO_GLOBAL     : candidatos x p1 (taxa global de entrega do
                                   telefone do GR, script 03).
   ordem 3  CALIBRADO_CAMPANHA   : Σ candidatos_k x p1_k (taxa do telefone do
                                   GR na MESMA campanha). NÚMERO CENTRAL.
   ordem 4  EVIDENCIA_DIRETA_EXTRAPOLADA : candidatos x taxa observada do
                                   telefone do GR nos CPFs em que ele já foi
                                   testado (extrapola para os não testados).
   ordem 5  PISO_EVIDENCIA_DIRETA: só candidatos cujo telefone do GR JÁ
                                   provou entregar. Nada é extrapolado.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_ganhos AS
WITH base AS (
  SELECT
    count(*)                                                                      AS n_candidatos,
    max(p1_global)                                                                AS p1_global,
    sum(p1_k)                                                                     AS recup_calib_campanha,
    sum(CASE WHEN evidencia_direta <> 'GR_NUNCA_TESTADO' THEN 1 ELSE 0 END)       AS n_gr_testado,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_TESTADO' THEN gr_taxa_entrega END) AS taxa_gr_observada,
    sum(CASE WHEN evidencia_direta = 'GR_TESTADO_ENTREGOU' THEN 1 ELSE 0 END)     AS n_gr_testado_entregou
  FROM vt_envios_gr_diferente
  WHERE entregue = 0
)
SELECT 1 AS ordem, 'TETO' AS cenario,
       'Todo insucesso com GR diferente vira entrega (premissa otimista, limite superior).' AS premissa,
       n_candidatos AS candidatos, 1.0 AS taxa_sucesso_aplicada,
       CAST(n_candidatos AS DOUBLE) AS entregas_recuperadas
FROM base
UNION ALL
SELECT 2, 'CALIBRADO_GLOBAL',
       'Candidatos x taxa global de entrega do telefone do GR (p1, script 03).',
       n_candidatos, p1_global, n_candidatos * p1_global
FROM base
UNION ALL
SELECT 3, 'CALIBRADO_CAMPANHA',
       'Σ candidatos_k x taxa do telefone do GR na mesma campanha k (fallback p1 global). NÚMERO CENTRAL.',
       n_candidatos, recup_calib_campanha / nullif(n_candidatos, 0), recup_calib_campanha
FROM base
UNION ALL
SELECT 4, 'EVIDENCIA_DIRETA_EXTRAPOLADA',
       'Candidatos x taxa observada do telefone do GR nos CPFs em que ele já foi usado pelo CRM.',
       n_candidatos, taxa_gr_observada, n_candidatos * taxa_gr_observada
FROM base
UNION ALL
SELECT 5, 'PISO_EVIDENCIA_DIRETA',
       'Só candidatos cujo telefone do GR já foi usado pelo CRM e entregou. Sem extrapolação.',
       n_gr_testado, CASE WHEN n_gr_testado > 0 THEN n_gr_testado_entregou / n_gr_testado END,
       CAST(n_gr_testado_entregou AS DOUBLE)
FROM base
;
SELECT * FROM vt_res_05_ganhos ORDER BY ordem;


/* -----------------------------------------------------------------------------
   5.4  PERDAS: entregas que seriam perdidas ao trocar um telefone que funciona
   -----------------------------------------------------------------------------
   Universo: SMS ENTREGUES em que o GR indicaria outro telefone. Se o CRM
   passar a usar o GR, esses disparos vão para um número diferente do que
   comprovadamente funciona. Perda esperada por cenário:
     TETO                : 0 (coerente com a premissa de que o GR sempre chega)
     CALIBRADO_GLOBAL    : sucessos_gr_dif x (1 - p1)
     CALIBRADO_CAMPANHA  : Σ sucessos_gr_dif_k x (1 - p1_k)
     EVIDENCIA_DIRETA_EXTRAPOLADA : sucessos_gr_dif x (1 - taxa observada do GR)
     PISO_EVIDENCIA_DIRETA: sucessos cujo telefone do GR já foi testado e
                            NUNCA entregou (perda comprovada).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_perdas AS
WITH base AS (
  SELECT
    count(*)                                                                      AS n_sucessos_gr_dif,
    max(p1_global)                                                                AS p1_global,
    sum(1 - p1_k)                                                                 AS perda_calib_campanha,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_TESTADO' THEN gr_taxa_entrega END) AS taxa_gr_observada,
    sum(CASE WHEN evidencia_direta = 'GR_TESTADO_NAO_ENTREGOU' THEN 1 ELSE 0 END) AS n_gr_testado_nao_entregou
  FROM vt_envios_gr_diferente
  WHERE entregue = 1
)
SELECT 1 AS ordem, 'TETO' AS cenario, n_sucessos_gr_dif AS sucessos_em_risco,
       0.0 AS taxa_perda_aplicada, 0.0 AS entregas_perdidas
FROM base
UNION ALL
SELECT 2, 'CALIBRADO_GLOBAL', n_sucessos_gr_dif, 1 - p1_global, n_sucessos_gr_dif * (1 - p1_global)
FROM base
UNION ALL
SELECT 3, 'CALIBRADO_CAMPANHA', n_sucessos_gr_dif, perda_calib_campanha / nullif(n_sucessos_gr_dif, 0), perda_calib_campanha
FROM base
UNION ALL
SELECT 4, 'EVIDENCIA_DIRETA_EXTRAPOLADA', n_sucessos_gr_dif, 1 - taxa_gr_observada, n_sucessos_gr_dif * (1 - taxa_gr_observada)
FROM base
UNION ALL
SELECT 5, 'PISO_EVIDENCIA_DIRETA', n_sucessos_gr_dif,
       n_gr_testado_nao_entregou / nullif(n_sucessos_gr_dif, 0), CAST(n_gr_testado_nao_entregou AS DOUBLE)
FROM base
;
SELECT * FROM vt_res_05_perdas ORDER BY ordem;


/* -----------------------------------------------------------------------------
   5.5  SALDO LÍQUIDO por cenário  (TABELA PRINCIPAL PARA O VALUATION)
   -----------------------------------------------------------------------------
   entregas_liquidas = recuperadas - perdidas
   pp_incremental    = entregas_liquidas / envios com GR (ganho de taxa de
                       entrega, em pontos percentuais, se o CRM usasse o GR)
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_saldo_liquido AS
SELECT
  g.ordem,
  g.cenario,
  g.premissa,
  g.candidatos                                             AS insucessos_candidatos,
  round(100.0 * g.taxa_sucesso_aplicada, 4)                AS taxa_sucesso_aplicada_pct,
  round(g.entregas_recuperadas, 0)                         AS entregas_recuperadas,
  p.sucessos_em_risco,
  round(p.entregas_perdidas, 0)                            AS entregas_perdidas,
  round(g.entregas_recuperadas - p.entregas_perdidas, 0)   AS entregas_liquidas,
  round(100.0 * (g.entregas_recuperadas - p.entregas_perdidas)
        / (SELECT count(*) FROM vt_experimento), 4)        AS pp_incremental_taxa_entrega,
  (SELECT count(*) FROM vt_experimento)                    AS envios_com_gr_base
FROM vt_res_05_ganhos g
JOIN vt_res_05_perdas p ON g.ordem = p.ordem
ORDER BY g.ordem
;
SELECT * FROM vt_res_05_saldo_liquido;


/* -----------------------------------------------------------------------------
   5.6  TABELA POR CAMPANHA (insumo do valuation)
   -----------------------------------------------------------------------------
   Uma linha por campanha com: volume, insucessos, quantos teriam telefone
   diferente no GR, taxa de calibração p1_k, recuperadas (teto e calibrado),
   perdidas (calibrado) e saldo. Multiplique saldo_calibrado pelo valor de
   uma entrega para chegar ao valor por campanha.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_valuation_por_campanha AS
WITH d AS (
  SELECT
    campanha,
    sum(CASE WHEN entregue = 0 THEN 1 ELSE 0 END)                AS n_insucesso_gr_dif,
    sum(CASE WHEN entregue = 1 THEN 1 ELSE 0 END)                AS n_sucesso_gr_dif,
    max(p1_k)                                                    AS p1_k,
    sum(CASE WHEN entregue = 0 AND evidencia_direta = 'GR_TESTADO_ENTREGOU' THEN 1 ELSE 0 END)
                                                                 AS n_insucesso_gr_provado
  FROM vt_envios_gr_diferente
  GROUP BY campanha
)
SELECT
  v.campanha,
  v.faixa_volume,
  v.n_envios,
  v.n_com_gr,
  round(100.0 * v.taxa_entrega, 4)                                   AS taxa_entrega_pct,
  v.n_envios - v.n_entregues                                         AS n_insucesso,
  coalesce(d.n_insucesso_gr_dif, 0)                                  AS n_insucesso_gr_diferente,
  round(100.0 * coalesce(d.n_insucesso_gr_dif, 0)
        / nullif(v.n_envios - v.n_entregues, 0), 4)                  AS pct_insucesso_gr_diferente,
  round(100.0 * d.p1_k, 4)                                           AS taxa_calibracao_p1_k_pct,
  coalesce(d.n_insucesso_gr_dif, 0)                                  AS recuperadas_teto,
  round(coalesce(d.n_insucesso_gr_dif, 0) * d.p1_k, 1)               AS recuperadas_calibrado,
  coalesce(d.n_insucesso_gr_provado, 0)                              AS recuperadas_piso,
  coalesce(d.n_sucesso_gr_dif, 0)                                    AS sucessos_em_risco,
  round(coalesce(d.n_sucesso_gr_dif, 0) * (1 - d.p1_k), 1)           AS perdidas_calibrado,
  round(coalesce(d.n_insucesso_gr_dif, 0) * d.p1_k
        - coalesce(d.n_sucesso_gr_dif, 0) * (1 - d.p1_k), 1)         AS saldo_calibrado,
  round(100.0 * (coalesce(d.n_insucesso_gr_dif, 0) * d.p1_k
        - coalesce(d.n_sucesso_gr_dif, 0) * (1 - d.p1_k)) / v.n_envios, 4) AS saldo_calibrado_pp
FROM vt_campanha_volume v
LEFT JOIN d ON v.campanha = d.campanha
ORDER BY v.n_envios DESC
;
SELECT * FROM vt_res_05_valuation_por_campanha;


/* -----------------------------------------------------------------------------
   5.7  VISÃO POR CPF: clientes hoje inalcançáveis para os quais o GR tem
        outro telefone
   -----------------------------------------------------------------------------
   Para valuation de "contatos recuperados" (ativo de cadastro, não só de
   volume de SMS). Um CPF é INALCANÇÁVEL HOJE se nenhum envio, em nenhum
   telefone, foi entregue. Entre esses, o GR só ajuda se apontar um telefone
   que ainda NÃO foi testado (se já foi testado e falhou, o GR não resolve).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_cpfs_recuperaveis AS
WITH cpf_status AS (
  SELECT
    cpf,
    max(entregue)                                                                 AS alguma_entrega,
    max(CASE WHEN entregue = 0 AND classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END) AS tem_insucesso_gr_dif,
    max(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)                              AS gr_testado,
    max(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)                       AS gr_entregou
  FROM vt_experimento
  GROUP BY cpf
)
SELECT
  count(*)                                                                        AS cpfs_com_gr,
  sum(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END)                             AS cpfs_inalcancaveis_hoje,
  round(100.0 * avg(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END), 4)           AS pct_inalcancaveis_hoje,
  sum(CASE WHEN alguma_entrega = 0 AND tem_insucesso_gr_dif = 1 AND gr_testado = 0 THEN 1 ELSE 0 END)
                                                                                  AS inalcancaveis_com_gr_novo_nao_testado,
  sum(CASE WHEN alguma_entrega = 0 AND tem_insucesso_gr_dif = 1 AND gr_testado = 1 THEN 1 ELSE 0 END)
                                                                                  AS inalcancaveis_com_gr_testado_e_falhou,
  sum(CASE WHEN alguma_entrega = 0 AND tem_insucesso_gr_dif = 0 THEN 1 ELSE 0 END)
                                                                                  AS inalcancaveis_gr_igual_ao_crm,
  sum(CASE WHEN alguma_entrega = 1 AND tem_insucesso_gr_dif = 1 AND gr_entregou = 1 THEN 1 ELSE 0 END)
                                                                                  AS alcancaveis_gr_provado_entrega
FROM cpf_status
;
SELECT * FROM vt_res_05_cpfs_recuperaveis;
