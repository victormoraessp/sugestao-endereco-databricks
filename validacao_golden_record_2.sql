-- =====================================================================
-- VALIDACAO QUASE-EXPERIMENTAL DA BASE GOLDEN RECORD (melhor telefone)
--
-- Ideia central: o proprio historico de campanhas ja contem um
-- experimento natural. Em parte das discagens o CRM usou, por acaso, o
-- mesmo numero que o Golden Record aponta como melhor (CONCORDANTE);
-- em outra parte usou um numero diferente (DISCORDANTE). Comparamos a
-- taxa de sucesso entre os dois grupos, estratificando por campanha.
--
-- Dialeto alvo: BigQuery / Snowflake (usa QUALIFY, POWER, REGEXP_REPLACE).
-- Em Redshift/Postgres: trocar QUALIFY por subquery com ROW_NUMBER e
-- SAFE_DIVIDE por NULLIF.
-- =====================================================================


-- =====================================================================
-- BLOCO 0 -- BASE ANALITICA
-- Normaliza telefone, faz o as-of join com o snapshot do GR ANTERIOR a
-- campanha (critico contra circularidade) e cria a flag de concordancia.
-- =====================================================================

CREATE OR REPLACE TABLE work.base_analitica AS

WITH crm AS (
  SELECT
      cpf,
      campanha,
      dt_disparo,
      telefone                 AS tel_bruto,
      resultado                            -- string bruta do CRM
  FROM prod.crm_campanhas
  WHERE dt_disparo BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
),

-- normalizacao BR: so digitos, remove DDI 55 e 0 de operadora.
-- chave = DDD + 8 ultimos digitos -> neutraliza o 9o digito de celular,
-- que e a maior fonte de falsa discordancia.
crm_d0 AS (
  SELECT c.*, REGEXP_REPLACE(tel_bruto, '[^0-9]', '') AS d0 FROM crm c
),
crm_d1 AS (
  SELECT *,
    CASE
      WHEN LENGTH(d0) >= 12 AND SUBSTR(d0,1,2) = '55' THEN SUBSTR(d0,3)
      WHEN LENGTH(d0) >= 11 AND SUBSTR(d0,1,1) = '0'  THEN SUBSTR(d0,2)
      ELSE d0
    END AS d1
  FROM crm_d0
),
crm_norm AS (
  SELECT *,
    CASE WHEN LENGTH(d1) IN (10,11)
         THEN CONCAT(SUBSTR(d1,1,2), SUBSTR(d1, LENGTH(d1)-7, 8))
    END AS tel_key_crm
  FROM crm_d1
),

-- MESMA normalizacao no Golden Record. Use a tabela HISTORICA de
-- snapshots. Se voce so tem a foto de hoje, o resultado fica
-- contaminado: pule para o BLOCO 4 (controle negativo) antes de
-- acreditar em qualquer numero deste script.
gr_d0 AS (
  SELECT cpf, dt_snapshot, REGEXP_REPLACE(telefone,'[^0-9]','') AS d0
  FROM prod.golden_record_hist
),
gr_d1 AS (
  SELECT *,
    CASE
      WHEN LENGTH(d0) >= 12 AND SUBSTR(d0,1,2) = '55' THEN SUBSTR(d0,3)
      WHEN LENGTH(d0) >= 11 AND SUBSTR(d0,1,1) = '0'  THEN SUBSTR(d0,2)
      ELSE d0
    END AS d1
  FROM gr_d0
),
gr_norm AS (
  SELECT cpf, dt_snapshot,
    CASE WHEN LENGTH(d1) IN (10,11)
         THEN CONCAT(SUBSTR(d1,1,2), SUBSTR(d1, LENGTH(d1)-7, 8))
    END AS tel_key_gr
  FROM gr_d1
),

-- as-of join: snapshot mais recente ANTERIOR ao disparo
joined AS (
  SELECT
      c.cpf, c.campanha, c.dt_disparo, c.resultado,
      c.tel_key_crm,
      g.tel_key_gr,
      g.dt_snapshot
  FROM crm_norm c
  LEFT JOIN gr_norm g
    ON g.cpf = c.cpf
   AND g.dt_snapshot <= c.dt_disparo
  QUALIFY ROW_NUMBER() OVER (
      PARTITION BY c.cpf, c.campanha, c.tel_key_crm
      ORDER BY g.dt_snapshot DESC
  ) = 1
)

SELECT
    cpf, campanha, dt_disparo, tel_key_crm, tel_key_gr,

    CASE WHEN tel_key_gr IS NOT NULL THEN 1 ELSE 0 END AS matched,

    CASE WHEN tel_key_gr IS NOT NULL AND tel_key_crm = tel_key_gr
         THEN 1 ELSE 0 END                              AS concordante,

    -- DESFECHO PRIMARIO: alcancabilidade. E o unico canal pelo qual um
    -- telefone melhor pode agir. Nao use "venda" aqui -- recusa nao se
    -- conserta com numero melhor, e isso so dilui o efeito.
    CASE
      WHEN UPPER(resultado) IN ('ATENDIDO','CONTATO EFETIVO','CPC','ALO')
        THEN 1
      WHEN UPPER(resultado) IN ('NAO ATENDE','CAIXA POSTAL','INEXISTENTE',
                                'FORA DE SERVICO','INVALIDO','NUMERO ERRADO',
                                'RECUSA','OCUPADO')
        THEN 0
    END                                                 AS sucesso,

    -- desfecho secundario: falha DURA de numero (o que o GR mais deveria
    -- corrigir). O lift aqui deve ser MAIOR que no desfecho primario.
    -- Se nao for, sua historia causal esta errada.
    CASE WHEN UPPER(resultado) IN ('INEXISTENTE','FORA DE SERVICO',
                                   'INVALIDO','NUMERO ERRADO')
         THEN 1 ELSE 0 END                              AS falha_dura

FROM joined
WHERE tel_key_crm IS NOT NULL;


-- =====================================================================
-- BLOCO 1 -- DIAGNOSTICO DE COBERTURA E SELECAO
-- Responde a sua preocupacao com o match parcial: se matched e
-- nao-matched tem taxa de sucesso parecida, a selecao e leve.
-- =====================================================================

SELECT
    campanha,
    COUNT(*)                                              AS contatos,
    AVG(matched * 1.0)                                    AS taxa_match_gr,
    AVG(CASE WHEN matched = 1 THEN sucesso END)           AS suc_matched,
    AVG(CASE WHEN matched = 0 THEN sucesso END)           AS suc_nao_matched,
    AVG(CASE WHEN matched = 1 THEN concordante * 1.0 END) AS taxa_concordancia
FROM work.base_analitica
WHERE sucesso IS NOT NULL
GROUP BY campanha
ORDER BY contatos DESC;


-- =====================================================================
-- BLOCO 2 -- ESTIMATIVA PRINCIPAL
-- Mantel-Haenszel estratificado por campanha: odds ratio comum,
-- IC95% (variancia Robins-Breslow-Greenland) e diferenca de risco
-- padronizada. E o teste desenhado exatamente para isto -- combinar
-- tabelas 2x2 de estratos com prevalencias muito diferentes.
-- =====================================================================

WITH strata AS (
  SELECT
    campanha,
    CAST(SUM(CASE WHEN concordante=1 AND sucesso=1 THEN 1 ELSE 0 END) AS FLOAT64) AS a,
    CAST(SUM(CASE WHEN concordante=1 AND sucesso=0 THEN 1 ELSE 0 END) AS FLOAT64) AS b,
    CAST(SUM(CASE WHEN concordante=0 AND sucesso=1 THEN 1 ELSE 0 END) AS FLOAT64) AS c,
    CAST(SUM(CASE WHEN concordante=0 AND sucesso=0 THEN 1 ELSE 0 END) AS FLOAT64) AS d
  FROM work.base_analitica
  WHERE matched = 1 AND sucesso IS NOT NULL
  GROUP BY campanha
  -- estrato so entra se tiver os DOIS bracos com massa minima
  HAVING SUM(CASE WHEN concordante=1 THEN 1 ELSE 0 END) >= 100
     AND SUM(CASE WHEN concordante=0 THEN 1 ELSE 0 END) >= 100
),
comp AS (
  SELECT *,
    (a+b+c+d)                                    AS n,
    a*d/(a+b+c+d)                                AS R,
    b*c/(a+b+c+d)                                AS S,
    (a+d)/(a+b+c+d)                              AS P,
    (b+c)/(a+b+c+d)                              AS Q,
    (a+b)*(a+c)/(a+b+c+d)                        AS E,
    (a+b)*(c+d)*(a+c)*(b+d)
      / (POWER(a+b+c+d,2)*(a+b+c+d-1))           AS V,
    a/NULLIF(a+b,0) - c/NULLIF(c+d,0)            AS rd,       -- risk diff
    (a*b/POWER(NULLIF(a+b,0),3)) + (c*d/POWER(NULLIF(c+d,0),3)) AS var_rd
  FROM strata
),
agg AS (
  SELECT
    SUM(R) AS R, SUM(S) AS S, SUM(a) AS A, SUM(E) AS E, SUM(V) AS V,
    SUM(P*R) AS PR, SUM(P*S + Q*R) AS PSQR, SUM(Q*S) AS QS,
    SUM(n*rd)/SUM(n)               AS rd_pad,
    SQRT(SUM(POWER(n,2)*var_rd))/SUM(n) AS se_rd,
    COUNT(*) AS n_estratos, SUM(n) AS n_total
  FROM comp
),
fim AS (
  SELECT *, PR/(2*R*R) + PSQR/(2*R*S) + QS/(2*S*S) AS var_ln FROM agg
)
SELECT
    n_estratos,
    n_total,
    R/S                                            AS odds_ratio_mh,
    EXP(LN(R/S) - 1.96*SQRT(var_ln))               AS or_ic95_inf,
    EXP(LN(R/S) + 1.96*SQRT(var_ln))               AS or_ic95_sup,
    rd_pad                                         AS lift_absoluto_pp,
    rd_pad - 1.96*se_rd                            AS lift_ic95_inf,
    rd_pad + 1.96*se_rd                            AS lift_ic95_sup,
    POWER(ABS(A-E)-0.5, 2)/V                       AS qui2_cmh   -- gl=1
FROM fim;

-- Leitura: odds_ratio_mh > 1 e IC95% inteiro acima de 1 => concordar com
-- o GR eleva a chance de contato. Reporte lift_absoluto_pp como numero
-- de negocio; o qui2 e formalidade (com milhoes de linhas ele sempre
-- estoura). Rode este bloco de novo trocando `sucesso` por
-- `1 - falha_dura` para o desfecho secundario.


-- =====================================================================
-- BLOCO 3 -- DESENHO INTRA-CPF (McNemar) -- O ARGUMENTO MAIS FORTE
-- Usa somente CPFs que foram discados MAIS DE UMA VEZ, umas com numero
-- concordante e outras com discordante. Compara a pessoa com ela mesma:
-- elimina todo confundimento por perfil, renda, engajamento, produto.
-- Se este bloco tiver massa, e ele que voce leva para a diretoria.
-- =====================================================================

WITH pares AS (
  SELECT cpf,
    SUM(CASE WHEN concordante=1 AND sucesso=1 THEN 1 ELSE 0 END) AS conc_suc,
    SUM(CASE WHEN concordante=0 AND sucesso=1 THEN 1 ELSE 0 END) AS disc_suc
  FROM work.base_analitica
  WHERE matched = 1 AND sucesso IS NOT NULL
  GROUP BY cpf
  HAVING SUM(CASE WHEN concordante=1 THEN 1 ELSE 0 END) > 0
     AND SUM(CASE WHEN concordante=0 THEN 1 ELSE 0 END) > 0
),
disc AS (
  SELECT
    CAST(SUM(CASE WHEN conc_suc>0 AND disc_suc=0 THEN 1 ELSE 0 END) AS FLOAT64) AS b,
    CAST(SUM(CASE WHEN conc_suc=0 AND disc_suc>0 THEN 1 ELSE 0 END) AS FLOAT64) AS c,
    COUNT(*) AS cpfs_elegiveis
  FROM pares
)
SELECT
    cpfs_elegiveis,
    b AS so_o_numero_do_gr_funcionou,
    c AS so_o_outro_numero_funcionou,
    b/NULLIF(c,0)                          AS odds_ratio_pareado,
    POWER(ABS(b-c)-1, 2)/NULLIF(b+c,0)     AS qui2_mcnemar,   -- gl=1
    -- IC95% do OR pareado (aprox. log)
    EXP(LN(b/NULLIF(c,0)) - 1.96*SQRT(1/NULLIF(b,0) + 1/NULLIF(c,0))) AS ic95_inf,
    EXP(LN(b/NULLIF(c,0)) + 1.96*SQRT(1/NULLIF(b,0) + 1/NULLIF(c,0))) AS ic95_sup
FROM disc;

-- Ressalva honesta: pares intra-CPF vem de campanhas diferentes, entao
-- resta confundimento por campanha e por ordem temporal. Restrinja a
-- pares dentro da MESMA campanha, ou a pares com menos de 60 dias de
-- distancia, para apertar.


-- =====================================================================
-- BLOCO 4 -- CONTROLE NEGATIVO (teste de falseamento)
-- Entre quem FOI ALCANCADO, a concordancia com o GR nao deveria
-- prever conversao -- o telefone ja cumpriu seu papel. Se prever
-- com forca parecida, o que voce mediu no Bloco 2 foi qualidade de
-- cliente, nao qualidade de telefone. Este bloco pode matar sua tese.
-- Rode antes de escrever a apresentacao.
-- =====================================================================

SELECT
    concordante,
    COUNT(*)               AS alcancados,
    AVG(converteu * 1.0)   AS taxa_conversao
FROM work.base_analitica b
JOIN prod.crm_conversao v USING (cpf, campanha)
WHERE b.matched = 1 AND b.sucesso = 1
GROUP BY concordante;


-- =====================================================================
-- BLOCO 5 -- ESTABILIDADE POR FAIXA DE COBERTURA
-- Responde diretamente ao seu receio do match parcial: se o lift for
-- parecido nas campanhas de match alto e de match baixo, a cobertura
-- nao esta dirigindo o resultado.
-- =====================================================================

WITH cob AS (
  SELECT campanha, AVG(matched*1.0) AS taxa_match
  FROM work.base_analitica GROUP BY campanha
),
faixas AS (
  SELECT b.*,
    CASE WHEN c.taxa_match >= 0.95 THEN '1. >=95%'
         WHEN c.taxa_match >= 0.80 THEN '2. 80-95%'
         WHEN c.taxa_match >= 0.60 THEN '3. 60-80%'
         ELSE '4. <60%' END AS faixa_cobertura
  FROM work.base_analitica b JOIN cob c USING (campanha)
)
SELECT
    faixa_cobertura,
    COUNT(*) AS n,
    AVG(CASE WHEN concordante=1 THEN sucesso END) AS suc_concordante,
    AVG(CASE WHEN concordante=0 THEN sucesso END) AS suc_discordante,
    AVG(CASE WHEN concordante=1 THEN sucesso END)
      - AVG(CASE WHEN concordante=0 THEN sucesso END) AS lift_pp
FROM faixas
WHERE matched = 1 AND sucesso IS NOT NULL
GROUP BY faixa_cobertura
ORDER BY faixa_cobertura;


-- =====================================================================
-- BLOCO 6 -- TRADUCAO PARA NEGOCIO
-- A versao honesta da sua pergunta original. Em vez de assumir que todo
-- telefone diferente teria dado certo, aplica o LIFT ESTIMADO no
-- Bloco 2 (ou 3) sobre o volume de insucessos corrigiveis.
-- Substitua :lift, :lift_inf, :lift_sup pelos valores estimados.
-- =====================================================================

SELECT
    campanha,
    COUNT(*)                                    AS insucessos,
    SUM(CASE WHEN matched=1 AND concordante=0
             THEN 1 ELSE 0 END)                 AS insucessos_corrigiveis,
    SUM(CASE WHEN matched=1 AND concordante=0
             THEN 1 ELSE 0 END) * :lift         AS contatos_recuperados_est,
    SUM(CASE WHEN matched=1 AND concordante=0
             THEN 1 ELSE 0 END) * :lift_inf     AS cenario_conservador,
    SUM(CASE WHEN matched=1 AND concordante=0
             THEN 1 ELSE 0 END) * :lift_sup     AS cenario_otimista
FROM work.base_analitica
WHERE sucesso = 0
GROUP BY campanha
ORDER BY insucessos_corrigiveis DESC;
