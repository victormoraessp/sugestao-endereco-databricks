/* =============================================================================
   VALUATION TELEFONE  |  01_preparacao_bases.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   Constrói a BASE ANALÍTICA: cada envio de SMS do CRM, com o telefone que o
   CRM usou, o resultado (entregue / não entregue) e, ao lado, o telefone que
   o Golden Record (GR) ranking 1 teria indicado para o mesmo CPF.
   A coluna central é CLASSE_CONCORDANCIA: o telefone usado pelo CRM era o
   mesmo do GR ou era diferente?

   POR QUE ESSA COLUNA É O CORAÇÃO DO EXPERIMENTO
   ----------------------------------------------
   Não temos A/B. Mas o CRM escolheu seus telefones SEM olhar para o GR (as
   fontes são independentes). Logo, quando por coincidência o CRM usou o
   mesmo número do GR, temos uma observação de "o que acontece quando se
   dispara para o telefone do GR"; quando usou outro, temos o contrafactual.
   Isso é um EXPERIMENTO NATURAL: a "alocação" ao braço concordante/discordante
   não foi decidida por ninguém com base no resultado.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   1) Pego 1 telefone por CPF no GR (ranking 1, ingestão mais recente).
              2) Limpo a base do CRM (só dígitos, status coerente, 1 linha por
                 cpf+campanha+telefone).
              3) Junto as duas por CPF e marco se o telefone bate ou não.
   [SÊNIOR]   Comparação em dois níveis: EXATA (string completa ddi+ddd+número)
              e TOLERANTE (DDD + últimos 8 dígitos), para não classificar como
              "telefone diferente" o que é só artefato de formatação (nono
              dígito, DDI com/sem zeros). Status ambíguos (entregue e não
              entregue ambos true, ou ambos false) saem do denominador e são
              reportados no script 02. Grão final = (cpf, campanha, telefone);
              se houver retentativas, vale max(entregue).
   [EXECUTIVO] Este passo prepara a "mesa de comparação": para cada SMS enviado
              sabemos se foi para o telefone que o GR recomendaria e se
              chegou. Tudo que vem depois deriva daqui.
   -----------------------------------------------------------------------------
   PERFORMANCE
   Com dezenas/centenas de milhões de envios, materialize vt_base_analitica
   como tabela Delta (bloco opcional 1.8) e aponte as views seguintes para
   ela. Temp views são recalculadas a cada consulta.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   1.0  FONTES  (ÚNICO lugar onde nomes de tabela precisam ser ajustados)
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_fonte_golden_record AS
SELECT * FROM temp_view_golden_record;            /* já existe na sessão */

CREATE OR REPLACE TEMP VIEW vt_fonte_crm_sms AS
SELECT * FROM temp_view_crm_sms;                  /* <<< AJUSTAR para a tabela real de campanhas SMS */


/* -----------------------------------------------------------------------------
   1.1  GOLDEN RECORD: 1 telefone por CPF (ranking 1, ingestão mais recente)
   -----------------------------------------------------------------------------
   Reproduz exatamente a query oficial do GR e adiciona chaves de comparação:
     telefone_gr : ddi+ddd+telefone, só dígitos (comparação EXATA)
     chave_gr    : ddd-últimos8dígitos            (comparação TOLERANTE)
   cpf é normalizado para 11 dígitos com zeros à esquerda (o mesmo é feito no CRM).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_rank1 AS
WITH gr AS (
  SELECT
    *,
    concat(cast(int(ddi) AS STRING), cast(int(ddd) AS STRING), telefone) AS telefone_normalizado
  FROM vt_fonte_golden_record
  WHERE ranking = 1
  QUALIFY row_number() OVER (PARTITION BY cpf, ranking ORDER BY data_ingestao DESC) = 1
)
SELECT
  lpad(regexp_replace(cast(cpf AS STRING), '[^0-9]', ''), 11, '0')               AS cpf,
  regexp_replace(telefone_normalizado, '[^0-9]', '')                             AS telefone_gr,
  cast(int(ddd) AS STRING)                                                       AS ddd_gr,
  concat(cast(int(ddd) AS STRING), '-',
         right(regexp_replace(cast(telefone AS STRING), '[^0-9]', ''), 8))       AS chave_gr,
  data_ingestao                                                                  AS data_ingestao_gr
FROM gr
;


/* -----------------------------------------------------------------------------
   1.2  CRM: limpeza de tipos e chaves
   -----------------------------------------------------------------------------
   telefone_crm : telefone_bruto só dígitos (comparação EXATA com telefone_gr)
   chave_crm    : ddd-últimos8dígitos. Regra: se tiver 12+ dígitos e começar
                  com 55, remove o DDI; os 2 primeiros dígitos restantes são o
                  DDD; os últimos 8 são o número sem o nono dígito.
                  (DDI diferente de 55 é raro; nesse caso só a comparação
                  exata vale.)
   flag_entregue / flag_nao_entregue: cast para boolean, NULL vira false.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios_raw AS
WITH base AS (
  SELECT
    lpad(regexp_replace(cast(cpf AS STRING), '[^0-9]', ''), 11, '0')  AS cpf,
    cast(campanha AS STRING)                                          AS campanha,
    regexp_replace(cast(telefone_bruto AS STRING), '[^0-9]', '')      AS telefone_crm,
    coalesce(cast(bol_entregue     AS BOOLEAN), false)                AS flag_entregue,
    coalesce(cast(bol_nao_entregue AS BOOLEAN), false)                AS flag_nao_entregue
  FROM vt_fonte_crm_sms
),
sem_ddi AS (
  SELECT
    *,
    CASE WHEN length(telefone_crm) >= 12 AND telefone_crm LIKE '55%'
         THEN substr(telefone_crm, 3)
         ELSE telefone_crm END AS telefone_crm_sem_ddi
  FROM base
)
SELECT
  cpf, campanha, telefone_crm, flag_entregue, flag_nao_entregue,
  left(telefone_crm_sem_ddi, 2)                                                AS ddd_crm,
  concat(left(telefone_crm_sem_ddi, 2), '-', right(telefone_crm_sem_ddi, 8))   AS chave_crm
FROM sem_ddi
;


/* -----------------------------------------------------------------------------
   1.3  CRM: classificação de QUALIDADE do registro e variável-resposta
   -----------------------------------------------------------------------------
   entregue = 1 (entregue), 0 (não entregue), NULL (status inválido).
   Só qualidade = 'OK' entra no experimento. O script 02 reporta o resto.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios_qualidade AS
SELECT
  *,
  CASE
    WHEN cpf IS NULL OR cpf = '00000000000' OR length(cpf) <> 11   THEN 'SEM_CPF'
    WHEN telefone_crm IS NULL OR length(telefone_crm) < 10         THEN 'SEM_TELEFONE'
    WHEN flag_entregue AND flag_nao_entregue                       THEN 'STATUS_INCONSISTENTE'
    WHEN NOT flag_entregue AND NOT flag_nao_entregue               THEN 'SEM_STATUS'
    ELSE 'OK'
  END AS qualidade,
  CASE
    WHEN flag_entregue AND NOT flag_nao_entregue THEN 1
    WHEN flag_nao_entregue AND NOT flag_entregue THEN 0
    ELSE NULL
  END AS entregue
FROM vt_crm_envios_raw
;


/* -----------------------------------------------------------------------------
   1.4  CRM: grão final = (cpf, campanha, telefone)
   -----------------------------------------------------------------------------
   Se o mesmo cpf+campanha+telefone aparecer mais de uma vez (retentativa,
   duplicidade de carga), consolidamos em 1 linha e consideramos entregue se
   QUALQUER tentativa entregou. n_registros_originais preserva a contagem.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios AS
SELECT
  cpf, campanha, telefone_crm, ddd_crm, chave_crm,
  max(entregue)  AS entregue,
  count(*)       AS n_registros_originais
FROM vt_crm_envios_qualidade
WHERE qualidade = 'OK'
GROUP BY cpf, campanha, telefone_crm, ddd_crm, chave_crm
;


/* -----------------------------------------------------------------------------
   1.5  BASE ANALÍTICA: envio do CRM  x  telefone do GR do mesmo CPF
   -----------------------------------------------------------------------------
   classe_concordancia:
     SEM_GR          : CPF não existe no GR ranking 1 (fora do experimento;
                       medido no script 02 como cobertura)
     IGUAL_EXATO     : CRM usou exatamente o telefone do GR
     IGUAL_TOLERANTE : mesmo DDD + mesmos 8 últimos dígitos (só formatação)
     DIFERENTE       : o GR indicaria OUTRO telefone
   concordante        = 1 se IGUAL_EXATO ou IGUAL_TOLERANTE, 0 se DIFERENTE
   concordante_exato  = 1 só se IGUAL_EXATO (usado na sensibilidade, script 06)
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_base_analitica AS
SELECT
  e.cpf,
  e.campanha,
  e.telefone_crm,
  e.chave_crm,
  e.entregue,
  e.n_registros_originais,
  g.telefone_gr,
  g.chave_gr,
  g.data_ingestao_gr,
  (g.cpf IS NOT NULL)                                                     AS tem_gr,
  CASE
    WHEN g.cpf IS NULL                     THEN 'SEM_GR'
    WHEN e.telefone_crm = g.telefone_gr    THEN 'IGUAL_EXATO'
    WHEN e.chave_crm    = g.chave_gr       THEN 'IGUAL_TOLERANTE'
    ELSE                                        'DIFERENTE'
  END                                                                     AS classe_concordancia,
  CASE
    WHEN g.cpf IS NULL THEN NULL
    WHEN e.telefone_crm = g.telefone_gr OR e.chave_crm = g.chave_gr THEN 1
    ELSE 0
  END                                                                     AS concordante,
  CASE
    WHEN g.cpf IS NULL THEN NULL
    WHEN e.telefone_crm = g.telefone_gr THEN 1
    ELSE 0
  END                                                                     AS concordante_exato
FROM vt_crm_envios e
LEFT JOIN vt_gr_rank1 g
  ON e.cpf = g.cpf
;


/* -----------------------------------------------------------------------------
   1.6  UNIVERSO DO EXPERIMENTO: só envios cujo CPF existe no GR
   -----------------------------------------------------------------------------
   É aqui que comparamos concordante x discordante. Envios SEM_GR não têm
   contrafactual e ficam de fora (cobertura reportada no script 02).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_experimento AS
SELECT *
FROM vt_base_analitica
WHERE tem_gr
;


/* -----------------------------------------------------------------------------
   1.7  VOLUMETRIA POR CAMPANHA (usada em 02, 03, 05 e 06)
   -----------------------------------------------------------------------------
   faixa_volume permite mostrar que o resultado não é puxado só pelas
   campanhas gigantes nem contaminado pelas minúsculas.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_campanha_volume AS
SELECT
  campanha,
  count(*)                                              AS n_envios,
  sum(entregue)                                         AS n_entregues,
  avg(entregue)                                         AS taxa_entrega,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)               AS n_com_gr,
  sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)      AS n_concordante,
  sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)      AS n_discordante,
  CASE
    WHEN count(*) <       100 THEN '1. < 100'
    WHEN count(*) <      1000 THEN '2. 100 a 1 mil'
    WHEN count(*) <     10000 THEN '3. 1 mil a 10 mil'
    WHEN count(*) <    100000 THEN '4. 10 mil a 100 mil'
    WHEN count(*) <   1000000 THEN '5. 100 mil a 1 milhão'
    ELSE                           '6. > 1 milhão'
  END                                                   AS faixa_volume
FROM vt_base_analitica
GROUP BY campanha
;


/* -----------------------------------------------------------------------------
   1.8  (OPCIONAL) MATERIALIZAÇÃO PARA PERFORMANCE
   -----------------------------------------------------------------------------
   Descomente, ajuste catálogo/schema, rode uma vez, e depois recrie
   vt_base_analitica apontando para a tabela:

   CREATE OR REPLACE TABLE <catalogo>.<schema>.valuation_telefone_base_analitica
   AS SELECT * FROM vt_base_analitica;

   CREATE OR REPLACE TEMP VIEW vt_base_analitica AS
   SELECT * FROM <catalogo>.<schema>.valuation_telefone_base_analitica;

   (e rode de novo os blocos 1.6 e 1.7)
----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   1.9  CHECAGEM RÁPIDA: a base analítica está de pé?
----------------------------------------------------------------------------- */
SELECT
  count(*)                                                    AS envios_validos,
  count(DISTINCT cpf)                                         AS cpfs_distintos,
  count(DISTINCT campanha)                                    AS campanhas,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)                     AS envios_com_gr,
  round(100.0 * avg(CASE WHEN tem_gr THEN 1 ELSE 0 END), 2)   AS pct_envios_com_gr,
  round(100.0 * avg(entregue), 2)                             AS taxa_entrega_geral_pct
FROM vt_base_analitica
;
