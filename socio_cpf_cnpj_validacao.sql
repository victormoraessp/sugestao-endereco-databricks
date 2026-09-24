-- =====================================================================================
-- RECONSTRUÇÃO E VALIDAÇÃO DO CPF/CNPJ DOS SÓCIOS (ccpf_cnpj + cflial_cpf_cnpj + cctrl_cpf_cnpj)
-- Databricks SQL (SQL warehouse serverless ou notebook %sql). Rodar as células em ordem.
--
-- Ideia:
--   1) Normaliza os 3 pedaços (tira lixo e zeros à esquerda; depois recompõe com LPAD).
--   2) Gera TODAS as hipóteses de concatenação (CPF e CNPJ) por sócio, sem confiar na
--      presença da filial para decidir o tipo.
--   3) Valida o DV (mod 11) de cada hipótese; quando o controle está ausente/errado,
--      também gera a hipótese com DV recalculado (marcada como "reconstruída").
--   4) Cruza com a RF: PF (table_vmmp_vw_rbrf) e PJ (estabelecimento_anomesdia).
--   5) Compara nomes (normalização + fonética PT-BR + Levenshtein + Jaccard de tokens).
--   6) Pontua, escolhe o melhor candidato por sócio e trata ambiguidades.
--   7) Repescagem: CPF não resolvido -> dígitos 4-9 (máscara LGPD) + nome quase idêntico.
--
-- AJUSTE ANTES DE RODAR (procure por  <<AJUSTE>>):
--   * schema de trabalho (USE abaixo)
--   * tabela do quadro societário e seus filtros (vw_socio_src)
--   * nomes das tabelas da RF, se o OCR do print tiver errado alguma letra
-- =====================================================================================

-- <<AJUSTE>> onde as tabelas de trabalho serão gravadas
USE <seu_catalogo>.<seu_schema_trabalho>;


-- =====================================================================================
-- 0. FUNÇÕES (temporárias, valem para a sessão)
-- =====================================================================================

-- Limpa documento: maiúsculas, só [0-9A-Z] (A-Z por causa do CNPJ alfanumérico, jul/2026)
CREATE OR REPLACE TEMPORARY FUNCTION fn_limpa_doc(x STRING)
RETURNS STRING
RETURN NULLIF(regexp_replace(upper(trim(x)), '[^0-9A-Z]', ''), '');

-- Remove zeros à esquerda (mantém ao menos 1 caractere). Depois recompomos com LPAD.
CREATE OR REPLACE TEMPORARY FUNCTION fn_sem_zeros(x STRING)
RETURNS STRING
RETURN regexp_replace(x, '^0+(?=.)', '');

-- ---------- CPF ----------
-- Um dígito verificador: pesos n+1..2 ; dv = (soma*10 mod 11) mod 10
CREATE OR REPLACE TEMPORARY FUNCTION fn_dv_cpf_digito(s STRING)
RETURNS INT
RETURN aggregate(
  sequence(1, length(s)), 0,
  (acc, i) -> acc + (ascii(substr(s, i, 1)) - 48) * (length(s) + 2 - i),
  acc -> pmod(acc * 10, 11) % 10
);

-- Os 2 DVs a partir da base de 9 dígitos
CREATE OR REPLACE TEMPORARY FUNCTION fn_cpf_dv(b9 STRING)
RETURNS STRING
RETURN CASE WHEN b9 RLIKE '^[0-9]{9}$' THEN
  concat(
    CAST(fn_dv_cpf_digito(b9) AS STRING),
    CAST(fn_dv_cpf_digito(concat(b9, CAST(fn_dv_cpf_digito(b9) AS STRING))) AS STRING)
  )
END;

CREATE OR REPLACE TEMPORARY FUNCTION fn_cpf_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9]{11}$'
  AND c <> repeat(substr(c, 1, 1), 11)             -- 000..., 111..., 999...
  AND substr(c, 10, 2) = fn_cpf_dv(substr(c, 1, 9)),
  false
);

-- ---------- CNPJ (numérico e alfanumérico) ----------
-- Pesos 2..9 ciclando da direita p/ esquerda; valor do caractere = ASCII - 48
-- dv = 0 se (soma mod 11) < 2, senão 11 - (soma mod 11)
CREATE OR REPLACE TEMPORARY FUNCTION fn_dv_cnpj_digito(s STRING)
RETURNS INT
RETURN aggregate(
  sequence(1, length(s)), 0,
  (acc, i) -> acc + (ascii(substr(s, i, 1)) - 48) * (2 + pmod(length(s) - i, 8)),
  acc -> CASE WHEN pmod(acc, 11) < 2 THEN 0 ELSE 11 - pmod(acc, 11) END
);

CREATE OR REPLACE TEMPORARY FUNCTION fn_cnpj_dv(b12 STRING)
RETURNS STRING
RETURN CASE WHEN b12 RLIKE '^[0-9A-Z]{12}$' THEN
  concat(
    CAST(fn_dv_cnpj_digito(b12) AS STRING),
    CAST(fn_dv_cnpj_digito(concat(b12, CAST(fn_dv_cnpj_digito(b12) AS STRING))) AS STRING)
  )
END;

CREATE OR REPLACE TEMPORARY FUNCTION fn_cnpj_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9A-Z]{12}[0-9]{2}$'
  AND c <> repeat(substr(c, 1, 1), 14)
  AND substr(c, 9, 4) <> '0000'                    -- filial 0000 não existe
  AND substr(c, 13, 2) = fn_cnpj_dv(substr(c, 1, 12)),
  false
);

-- ---------- NOMES ----------
-- Limpeza base: maiúsculas, sem acento, só letras/dígitos, espaços colapsados
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_limpo(x STRING)
RETURNS STRING
RETURN CASE
  WHEN trim(regexp_replace(regexp_replace(
         translate(upper(x), 'ÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝŸ', 'AAAAAAEEEEIIIIOOOOOUUUUCNYY'),
         '[^A-Z0-9 ]', ' '), ' +', ' '))
       IN ('', 'NULL', 'NAO INFORMADO', 'NAO CONSTA', 'SEM NOME', 'NI', 'NA')
  THEN NULL
  ELSE trim(regexp_replace(regexp_replace(
         translate(upper(x), 'ÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝŸ', 'AAAAAAEEEEIIIIOOOOOUUUUCNYY'),
         '[^A-Z0-9 ]', ' '), ' +', ' '))
END;

-- Chave PF: sem dígitos, sem partículas (DE/DA/DOS...), sem títulos e sem "ESPOLIO"
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_chave_pf(x STRING)
RETURNS STRING
RETURN NULLIF(trim(regexp_replace(
  regexp_replace(
    concat(' ', regexp_replace(fn_nome_limpo(x), '[0-9]', ' '), ' '),
    '(?<= )(DE|DA|DO|DAS|DOS|DI|DU|D|E|DEL|DELLA|VAN|VON|DR|DRA|SR|SRA|ESPOLIO)(?= )', ''),
  ' +', ' ')), '');

-- Chave PJ: sem natureza jurídica / porte (LTDA, S A, ME, EPP, EIRELI...) e partículas
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_chave_pj(x STRING)
RETURNS STRING
RETURN NULLIF(trim(regexp_replace(
  regexp_replace(
    regexp_replace(
      concat(' ', fn_nome_limpo(x), ' '),
      ' (EM RECUPERACAO JUDICIAL|EM LIQUIDACAO( EXTRAJUDICIAL)?|SOCIEDADE ANONIMA|SOCIEDADE SIMPLES|MICRO ?EMPRESA|EMPRESA INDIVIDUAL|S ?A|S ?S) ', ' '),
    '(?<= )(LTDA|LIMITADA|ME|EPP|MEI|EIRELI|SLU|CIA|COMPANHIA|DE|DA|DO|DAS|DOS|E)(?= )', ''),
  ' +', ' ')), '');

-- Fonética PT-BR simplificada (SOUZA=SOUSA, WALDIR=VALDIR, THIAGO=TIAGO, CAMILLA=KAMILA...)
CREATE OR REPLACE TEMPORARY FUNCTION fn_fonetica(k STRING)
RETURNS STRING
RETURN regexp_replace(                                        -- letras repetidas -> 1
  regexp_replace(                                             -- L antes de consoante -> U
  regexp_replace(                                             -- N antes de consoante/fim -> M
  regexp_replace(                                             -- H mudo
  regexp_replace(                                             -- Z -> S
  regexp_replace(                                             -- C/Q duros -> K
  regexp_replace(                                             -- GE/GI -> J
  regexp_replace(                                             -- CE/CI -> S
  regexp_replace(                                             -- SCE/SCI -> S
  regexp_replace(                                             -- GUE/GUI -> G
  regexp_replace(                                             -- QUE/QUI -> K
  regexp_replace(                                             -- NH -> N
  regexp_replace(                                             -- LH -> L
  regexp_replace(                                             -- CH/SH/SCH -> X
  translate(                                                  -- Y->I, W->V
  regexp_replace(regexp_replace(regexp_replace(k, '([A-Z])\\1+', '$1'), 'PH', 'F'), 'TH', 'T'),
  'YW', 'IV'),
  'SCH|CH|SH', 'X'),
  'LH', 'L'),
  'NH', 'N'),
  'QU(?=[EI])', 'K'),
  'GU(?=[EI])', 'GH'),                                        -- GH protege do GE/GI->J; o H cai depois
  'SC(?=[EI])', 'S'),
  'C(?=[EI])', 'S'),
  'G(?=[EI])', 'J'),
  '[CQ]', 'K'),
  'Z', 'S'),
  'H', ''),
  'N(?=[^AEIOU]|$)', 'M'),
  'L(?=[^AEIOU ])', 'U'),
  '([A-Z])\\1+', '$1');

-- Similaridade 0..1 entre duas CHAVES de nome (já normalizadas). NULL se faltar um lado.
CREATE OR REPLACE TEMPORARY FUNCTION fn_sim_nome(a STRING, b STRING)
RETURNS DOUBLE
RETURN CASE
  WHEN a IS NULL OR b IS NULL THEN CAST(NULL AS DOUBLE)
  WHEN a = b THEN 1.0D
  WHEN fn_fonetica(a) = fn_fonetica(b) THEN 0.97D
  WHEN array_join(array_sort(split(a, ' ')), ' ') = array_join(array_sort(split(b, ' ')), ' ') THEN 0.96D   -- ordem trocada
  ELSE greatest(
    1.0D - levenshtein(a, b) / greatest(length(a), length(b)),
    0.98D * (1.0D - levenshtein(fn_fonetica(a), fn_fonetica(b))
                    / greatest(length(fn_fonetica(a)), length(fn_fonetica(b)))),
    size(array_intersect(split(fn_fonetica(a), ' '), split(fn_fonetica(b), ' ')))
      / size(array_union(split(fn_fonetica(a), ' '), split(fn_fonetica(b), ' '))),
    -- nome abreviado: mesmo 1º nome e todos os tokens de um contidos no outro
    CASE WHEN split(a, ' ')[0] = split(b, ' ')[0]
          AND (size(array_except(split(a, ' '), split(b, ' '))) = 0
               OR size(array_except(split(b, ' '), split(a, ' '))) = 0)
         THEN 0.90D END,
    -- mesmo primeiro e último nome (ex.: "JOSE C SILVA" x "JOSE CARLOS SILVA")
    CASE WHEN split(a, ' ')[0] = split(b, ' ')[0]
          AND element_at(split(a, ' '), -1) = element_at(split(b, ' '), -1)
         THEN 0.86D END
  )
END;

-- Máscara visual
CREATE OR REPLACE TEMPORARY FUNCTION fn_formata_doc(d STRING)
RETURNS STRING
RETURN CASE length(d)
  WHEN 11 THEN concat(substr(d,1,3),'.',substr(d,4,3),'.',substr(d,7,3),'-',substr(d,10,2))
  WHEN 14 THEN concat(substr(d,1,2),'.',substr(d,3,3),'.',substr(d,6,3),'/',substr(d,9,4),'-',substr(d,13,2))
END;

-- Testes rápidos das funções (devem voltar todos TRUE)
SELECT
  fn_cpf_valido('52998224725')          AS cpf_ok,
  NOT fn_cpf_valido('52998224724')      AS cpf_dv_errado,
  NOT fn_cpf_valido('11111111111')      AS cpf_repetido,
  fn_cpf_dv('529982247') = '25'         AS cpf_dv_calc,
  fn_cnpj_valido('11222333000181')      AS cnpj_ok,
  fn_cnpj_valido('12ABC34501DE35')      AS cnpj_alfanum_ok,
  NOT fn_cnpj_valido('11222333000182')  AS cnpj_dv_errado,
  fn_fonetica(fn_nome_chave_pf('Thiago de Souza')) = fn_fonetica(fn_nome_chave_pf('TIAGO SOUSA')) AS fon_ok,
  fn_sim_nome(fn_nome_chave_pf('JOSE C DA SILVA'), fn_nome_chave_pf('José Carlos da Silva')) >= 0.85 AS sim_ok;


-- =====================================================================================
-- 1. FONTES
-- =====================================================================================

-- <<AJUSTE>> tabela do quadro societário + os mesmos filtros que você já usa
CREATE OR REPLACE TEMPORARY VIEW vw_socio_src AS
SELECT
  q_socio.cclub,
  q_socio.cseq_quadr_empr,
  CAST(q_socio.ccpf_cnpj        AS STRING) AS ccpf_cnpj,
  CAST(q_socio.cflial_cpf_cnpj  AS STRING) AS cflial_cpf_cnpj,
  CAST(q_socio.cctrl_cpf_cnpj   AS STRING) AS cctrl_cpf_cnpj,
  q_socio.nome_socio                                        -- (no seu SELECT aparece ipartc_empr)
FROM <catalogo>.<schema>.<tabela_quadro_societario> q_socio
WHERE q_socio.catulz_reg != 'D'
  AND q_socio.cindcd_quadr_scial = 'S'
  AND q_socio.dfim_prtcp_scial IS NULL
-- QUALIFY ROW_NUMBER() OVER (PARTITION BY q_socio.cclub, q_socio.cseq_quadr_empr ORDER BY <sua_ordem>) = 1
;

-- RF Pessoa Física (CPF completo em documento_pessoa)
CREATE OR REPLACE TEMPORARY VIEW vw_rf_pf AS
SELECT
  lpad(regexp_replace(CAST(documento_pessoa AS STRING), '[^0-9]', ''), 11, '0') AS cpf,
  coalesce(nome_pessoa_normalizado, nome_pessoa)                            AS nome_rf
FROM pr_explo.d4852s185_imdm.table_vmmp_vw_rbrf          -- <<AJUSTE>> confira o nome
WHERE documento_pessoa IS NOT NULL;

-- RF Estabelecimentos (CNPJ em 3 pedaços, zeros à esquerda perdidos)
-- <<AJUSTE>> se a tabela tiver várias fotos (anomesdia), filtre só a mais recente aqui.
-- <<OPCIONAL>> se tiver a razão social (tabela de empresas), traga-a como nome_rf_razao:
--   o casamento de nome PJ fica muito melhor que só com o nome fantasia.
CREATE OR REPLACE TEMPORARY VIEW vw_rf_pj AS
SELECT
  concat(
    lpad(fn_sem_zeros(fn_limpa_doc(CAST(e.ccpf_cnpj       AS STRING))), 8, '0'),
    lpad(fn_sem_zeros(fn_limpa_doc(CAST(e.cflial_cpf_cnpj AS STRING))), 4, '0'),
    lpad(fn_sem_zeros(fn_limpa_doc(CAST(e.cctrl_cpf_cnpj  AS STRING))), 2, '0')
  )                              AS cnpj,
  e.cidtfd_mtriz,
  e.csit_recta_fedrl             AS situacao_rf,          -- 2 = ativa
  e.ifants_estbl                 AS nome_rf_fantasia,
  CAST(NULL AS STRING)           AS nome_rf_razao         -- <<OPCIONAL>> emp.<coluna_razao_social>
FROM pr_platfun.aadg_ing.estabelecimento_anomesdia e
-- LEFT JOIN pr_platfun.aadg_ing.empresa_anomesdia emp ON emp.ccpf_cnpj = e.ccpf_cnpj
WHERE e.ccpf_cnpj IS NOT NULL AND e.cctrl_cpf_cnpj IS NOT NULL;


-- =====================================================================================
-- 2. SÓCIOS NORMALIZADOS
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_01_base AS
SELECT
  x.*,
  length(b)                                   AS len_b,
  b RLIKE '^[0-9]+$'                          AS b_num,
  (f IS NULL OR f = '0')                      AS f_zero,
  fn_nome_chave_pf(nome_socio)                AS nome_chave_pf,
  fn_nome_chave_pj(nome_socio)                AS nome_chave_pj
FROM (
  SELECT
    s.*,
    fn_limpa_doc(ccpf_cnpj)                   AS b_raw,     -- como veio (limpo)
    fn_limpa_doc(cflial_cpf_cnpj)             AS f_raw,
    fn_limpa_doc(cctrl_cpf_cnpj)              AS c_raw,
    fn_sem_zeros(fn_limpa_doc(ccpf_cnpj))       AS b,       -- sem zeros à esquerda
    fn_sem_zeros(fn_limpa_doc(cflial_cpf_cnpj)) AS f,
    fn_sem_zeros(fn_limpa_doc(cctrl_cpf_cnpj))  AS c
  FROM vw_socio_src s
) x;


-- =====================================================================================
-- 3. TODAS AS HIPÓTESES DE CONCATENAÇÃO + VALIDAÇÃO DE DV
--    prior = plausibilidade estrutural (0-10), só serve de desempate
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_02_candidatos AS
WITH h AS (
  SELECT s.cclub, s.cseq_quadr_empr, s.nome_chave_pf, s.nome_chave_pj, t.*
  FROM socio_doc_01_base s
  LATERAL VIEW inline(array(

    -- CPF = base(9) + controle(2). Filial vazia/zero é o caso esperado.
    named_struct('hipotese', 'CPF_BASE_CTRL', 'tipo', 'CPF',
      'doc', CASE WHEN s.b_num AND s.len_b <= 9 AND s.c RLIKE '^[0-9]{1,2}$'
                  THEN concat(lpad(s.b, 9, '0'), lpad(s.c, 2, '0')) END,
      'dv_reconstruido', false, 'prior', CASE WHEN s.f_zero THEN 10 ELSE 4 END),

    -- CPF com DV recalculado (controle nulo ou digitado errado)
    named_struct('hipotese', 'CPF_BASE_DVCALC', 'tipo', 'CPF',
      'doc', CASE WHEN s.b_num AND s.len_b <= 9
                  THEN concat(lpad(s.b, 9, '0'), fn_cpf_dv(lpad(s.b, 9, '0'))) END,
      'dv_reconstruido', true, 'prior', CASE WHEN s.c IS NULL AND s.f_zero THEN 6 ELSE 1 END),

    -- CPF inteiro dentro do campo base
    named_struct('hipotese', 'CPF_BASE_COMPLETO', 'tipo', 'CPF',
      'doc', CASE WHEN s.b_num AND s.len_b BETWEEN 10 AND 11 THEN lpad(s.b, 11, '0') END,
      'dv_reconstruido', false, 'prior', 5),

    -- CNPJ = raiz(8) + filial(4) + controle(2)
    named_struct('hipotese', 'CNPJ_RAIZ_FILIAL_CTRL', 'tipo', 'CNPJ',
      'doc', CASE WHEN s.len_b <= 8 AND length(s.f) <= 4 AND s.c RLIKE '^[0-9]{1,2}$'
                  THEN concat(lpad(s.b, 8, '0'), lpad(s.f, 4, '0'), lpad(s.c, 2, '0')) END,
      'dv_reconstruido', false, 'prior', CASE WHEN s.f_zero THEN 3 ELSE 10 END),

    -- CNPJ matriz (filial ausente -> 0001) + controle
    named_struct('hipotese', 'CNPJ_RAIZ_0001_CTRL', 'tipo', 'CNPJ',
      'doc', CASE WHEN s.len_b <= 8 AND s.f_zero AND s.c RLIKE '^[0-9]{1,2}$'
                  THEN concat(lpad(s.b, 8, '0'), '0001', lpad(s.c, 2, '0')) END,
      'dv_reconstruido', false, 'prior', 5),

    -- CNPJ com DV recalculado (filial informada ou 0001)
    named_struct('hipotese', 'CNPJ_RAIZ_FILIAL_DVCALC', 'tipo', 'CNPJ',
      'doc', CASE WHEN s.len_b <= 8 AND coalesce(length(s.f), 0) <= 4
                  THEN concat(lpad(s.b, 8, '0'), lpad(CASE WHEN s.f_zero THEN '1' ELSE s.f END, 4, '0'),
                              fn_cnpj_dv(concat(lpad(s.b, 8, '0'), lpad(CASE WHEN s.f_zero THEN '1' ELSE s.f END, 4, '0')))) END,
      'dv_reconstruido', true, 'prior', CASE WHEN s.c IS NULL THEN 5 ELSE 1 END),

    -- CNPJ com base de 9 dígitos significativos (descarta o 1º) - improvável, baixa prioridade
    named_struct('hipotese', 'CNPJ_BASE9_TRUNC', 'tipo', 'CNPJ',
      'doc', CASE WHEN s.len_b = 9 AND length(s.f) <= 4 AND s.c RLIKE '^[0-9]{1,2}$'
                  THEN concat(right(s.b, 8), lpad(s.f, 4, '0'), lpad(s.c, 2, '0')) END,
      'dv_reconstruido', false, 'prior', 2),

    -- CNPJ inteiro dentro do campo base
    named_struct('hipotese', 'CNPJ_BASE_COMPLETO', 'tipo', 'CNPJ',
      'doc', CASE WHEN s.len_b BETWEEN 12 AND 14 THEN lpad(s.b, 14, '0') END,
      'dv_reconstruido', false, 'prior', 5),

    -- Concatenação crua dos 3 campos, do jeito que vieram
    named_struct('hipotese', 'RAW_CONCAT', 'tipo',
      CASE length(concat(coalesce(s.b_raw,''), coalesce(s.f_raw,''), coalesce(s.c_raw,'')))
        WHEN 11 THEN 'CPF' WHEN 14 THEN 'CNPJ' END,
      'doc', CASE WHEN length(concat(coalesce(s.b_raw,''), coalesce(s.f_raw,''), coalesce(s.c_raw,''))) IN (11, 14)
                  THEN concat(coalesce(s.b_raw,''), coalesce(s.f_raw,''), coalesce(s.c_raw,'')) END,
      'dv_reconstruido', false, 'prior', 3)

  )) t
)
SELECT
  cclub, cseq_quadr_empr, tipo, doc,
  first(nome_chave_pf)                                  AS nome_chave_pf,
  first(nome_chave_pj)                                  AS nome_chave_pj,
  bool_and(dv_reconstruido)                             AS dv_reconstruido,  -- só é "reconstruído" se nenhuma hipótese com DV informado gerou o mesmo doc
  max(prior)                                            AS prior,
  array_join(array_sort(collect_set(hipotese)), '|')    AS hipoteses,
  CASE WHEN tipo = 'CPF' THEN fn_cpf_valido(doc) ELSE fn_cnpj_valido(doc) END AS dv_valido
FROM h
WHERE doc IS NOT NULL AND tipo IS NOT NULL
GROUP BY cclub, cseq_quadr_empr, tipo, doc;


-- =====================================================================================
-- 4. CRUZAMENTO COM A RF + SIMILARIDADE DE NOME + SCORE
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_03_match AS
WITH cand AS (
  SELECT * FROM socio_doc_02_candidatos WHERE dv_valido      -- DV inválido nunca existe na RF
),
m_pf AS (
  SELECT c.*,
         p.cpf IS NOT NULL                                            AS encontrado_rf,
         false                                                        AS raiz_encontrada,
         p.nome_rf,
         CAST(NULL AS INT)                                            AS situacao_rf,
         fn_sim_nome(c.nome_chave_pf, fn_nome_chave_pf(p.nome_rf))    AS sim_nome
  FROM cand c
  LEFT JOIN vw_rf_pf p ON p.cpf = c.doc
  WHERE c.tipo = 'CPF'
),
pj_raiz AS (
  SELECT DISTINCT left(cnpj, 8) AS raiz FROM vw_rf_pj
),
m_pj AS (
  SELECT c.*,
         j.cnpj IS NOT NULL                                           AS encontrado_rf,
         r.raiz IS NOT NULL                                           AS raiz_encontrada,
         coalesce(j.nome_rf_razao, j.nome_rf_fantasia)                AS nome_rf,
         CAST(j.situacao_rf AS INT)                                   AS situacao_rf,
         greatest(fn_sim_nome(c.nome_chave_pj, fn_nome_chave_pj(j.nome_rf_razao)),
                  fn_sim_nome(c.nome_chave_pj, fn_nome_chave_pj(j.nome_rf_fantasia))) AS sim_nome
  FROM cand c
  LEFT JOIN vw_rf_pj j ON j.cnpj = c.doc
  LEFT JOIN pj_raiz  r ON r.raiz = left(c.doc, 8)
  WHERE c.tipo = 'CNPJ'
),
m AS (
  -- se a RF tiver o mesmo doc repetido, fica a linha de melhor nome
  SELECT * FROM (SELECT * FROM m_pf UNION ALL SELECT * FROM m_pj)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cclub, cseq_quadr_empr, tipo, doc
                             ORDER BY sim_nome DESC NULLS LAST, situacao_rf = 2 DESC) = 1
),
classif AS (
  SELECT m.*,
    CASE
      -- CPF
      WHEN tipo = 'CPF'  AND encontrado_rf AND NOT dv_reconstruido AND sim_nome >= 0.85 THEN 'VALIDADO_RF_NOME'
      WHEN tipo = 'CPF'  AND encontrado_rf AND NOT dv_reconstruido AND sim_nome >= 0.70 THEN 'VALIDADO_RF_NOME_PARCIAL'
      WHEN tipo = 'CPF'  AND encontrado_rf AND NOT dv_reconstruido AND sim_nome IS NULL THEN 'VALIDADO_RF_SEM_NOME'
      WHEN tipo = 'CPF'  AND encontrado_rf AND dv_reconstruido     AND sim_nome >= 0.85 THEN 'VALIDADO_RF_NOME_DV_RECONSTRUIDO'
      WHEN tipo = 'CPF'  AND encontrado_rf                                              THEN 'REJEITADO_RF_NOME_DIVERGENTE'
      -- CNPJ (nome fantasia costuma diferir da razão social -> nome pesa menos)
      WHEN tipo = 'CNPJ' AND encontrado_rf AND NOT dv_reconstruido AND sim_nome >= 0.70 THEN 'VALIDADO_RF_NOME'
      WHEN tipo = 'CNPJ' AND encontrado_rf AND NOT dv_reconstruido AND sim_nome IS NULL THEN 'VALIDADO_RF_SEM_NOME'
      WHEN tipo = 'CNPJ' AND encontrado_rf AND NOT dv_reconstruido                      THEN 'VALIDADO_RF_NOME_DIVERGENTE_PJ'
      WHEN tipo = 'CNPJ' AND encontrado_rf AND dv_reconstruido     AND sim_nome >= 0.85 THEN 'VALIDADO_RF_NOME_DV_RECONSTRUIDO'
      WHEN tipo = 'CNPJ' AND encontrado_rf                                              THEN 'REJEITADO_DV_RECONSTRUIDO_SEM_NOME'
      -- fora da RF
      WHEN raiz_encontrada AND NOT dv_reconstruido THEN 'NAO_ENCONTRADO_RF_RAIZ_EXISTE'
      WHEN NOT dv_reconstruido                     THEN 'NAO_ENCONTRADO_RF_DV_VALIDO'
      ELSE                                              'NAO_ENCONTRADO_RF_DV_RECONSTRUIDO'
    END AS status_candidato
  FROM m
)
SELECT c.*,
  status_candidato LIKE 'VALIDADO%' AS aceito,
  CASE
    WHEN status_candidato = 'VALIDADO_RF_NOME' AND tipo = 'CPF' THEN 'ALTA'
    WHEN status_candidato IN ('VALIDADO_RF_NOME', 'VALIDADO_RF_SEM_NOME', 'VALIDADO_RF_NOME_PARCIAL',
                              'VALIDADO_RF_NOME_DIVERGENTE_PJ', 'VALIDADO_RF_NOME_DV_RECONSTRUIDO') THEN 'MEDIA'
    ELSE 'BAIXA'
  END AS nivel_confianca,
  -- score 0..~110: existência na RF + DV informado bater + nome + plausibilidade estrutural
    CASE WHEN encontrado_rf THEN 50 WHEN raiz_encontrada THEN 15 ELSE 0 END
  + CASE WHEN NOT dv_reconstruido THEN 20 ELSE 0 END
  + CASE WHEN sim_nome IS NULL THEN 10 ELSE round(25 * sim_nome) END
  - CASE WHEN tipo = 'CPF' AND encontrado_rf AND sim_nome < 0.70 THEN 30 ELSE 0 END
  + CASE WHEN tipo = 'CNPJ' AND situacao_rf = 2 THEN 2 ELSE 0 END
  + prior AS score
FROM classif c;


-- =====================================================================================
-- 5. MELHOR CANDIDATO POR SÓCIO + AMBIGUIDADE
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_04_vencedor AS
SELECT * FROM (
  SELECT m.*,
    ROW_NUMBER() OVER w                                                   AS rk,
    LEAD(score)   OVER w                                                  AS score_2o,
    LEAD(aceito)  OVER w                                                  AS aceito_2o,
    count_if(aceito) OVER (PARTITION BY cclub, cseq_quadr_empr)           AS qtd_docs_aceitos
  FROM socio_doc_03_match m
  WINDOW w AS (PARTITION BY cclub, cseq_quadr_empr ORDER BY aceito DESC, score DESC, prior DESC, doc)
) WHERE rk = 1;


-- =====================================================================================
-- 6. REPESCAGEM: CPF não resolvido -> dígitos 4-9 (máscara ***.XXX.XXX-**) + nome
--    Cobre erro de digitação nos 3 primeiros dígitos / no controle, e bases já mascaradas (len 6).
--    Só aceita se houver UMA única pessoa na RF com essa máscara e nome ~idêntico.
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_05_repescagem AS
WITH pend AS (
  SELECT s.cclub, s.cseq_quadr_empr, s.nome_chave_pf,
         substr(lpad(s.b, 9, '0'), 4, 6) AS mascara
  FROM socio_doc_01_base s
  LEFT JOIN socio_doc_04_vencedor v
    ON v.cclub = s.cclub AND v.cseq_quadr_empr = s.cseq_quadr_empr AND v.aceito
  WHERE v.cclub IS NULL
    AND s.b_num AND s.len_b BETWEEN 6 AND 9 AND s.f_zero
    AND s.nome_chave_pf IS NOT NULL AND size(split(s.nome_chave_pf, ' ')) >= 2   -- nome com 1 token é arriscado
),
hits AS (
  SELECT d.cclub, d.cseq_quadr_empr, p.cpf, p.nome_rf,
         fn_sim_nome(d.nome_chave_pf, fn_nome_chave_pf(p.nome_rf)) AS sim_nome
  FROM pend d
  JOIN vw_rf_pf p ON substr(p.cpf, 4, 6) = d.mascara
  WHERE split(fn_nome_limpo(p.nome_rf), ' ')[0] = split(d.nome_chave_pf, ' ')[0]  -- filtro barato antes do fuzzy
)
SELECT cclub, cseq_quadr_empr,
       max(cpf) AS cpf, max(nome_rf) AS nome_rf, max(sim_nome) AS sim_nome
FROM hits
WHERE sim_nome >= 0.95
GROUP BY cclub, cseq_quadr_empr
HAVING count(DISTINCT cpf) = 1;


-- =====================================================================================
-- 7. RESULTADO FINAL (1 linha por sócio)
-- =====================================================================================
CREATE OR REPLACE TABLE socio_doc_final AS
WITH j AS (
  SELECT
    s.cclub, s.cseq_quadr_empr,
    s.ccpf_cnpj, s.cflial_cpf_cnpj, s.cctrl_cpf_cnpj, s.nome_socio,
    v.tipo, v.doc, v.aceito, v.status_candidato, v.nivel_confianca, v.score, v.score_2o, v.aceito_2o,
    v.qtd_docs_aceitos, v.hipoteses, v.dv_reconstruido, v.sim_nome, v.nome_rf, v.situacao_rf,
    r.cpf AS cpf_rep, r.nome_rf AS nome_rf_rep, r.sim_nome AS sim_rep
  FROM socio_doc_01_base s
  LEFT JOIN socio_doc_04_vencedor  v ON v.cclub = s.cclub AND v.cseq_quadr_empr = s.cseq_quadr_empr
  LEFT JOIN socio_doc_05_repescagem r ON r.cclub = s.cclub AND r.cseq_quadr_empr = s.cseq_quadr_empr
),
k AS (
  SELECT j.*,
    -- ambíguo: 2+ docs aceitos e o 2º muito perto do 1º
    (coalesce(qtd_docs_aceitos, 0) > 1 AND coalesce(aceito_2o, false) AND score - score_2o < 10) AS ambiguo
  FROM j
)
SELECT
  cclub, cseq_quadr_empr, ccpf_cnpj, cflial_cpf_cnpj, cctrl_cpf_cnpj, nome_socio,

  -- >>> CAMPO PRINCIPAL <<<
  CASE WHEN aceito AND NOT ambiguo THEN doc
       WHEN NOT coalesce(aceito, false) AND cpf_rep IS NOT NULL THEN cpf_rep END             AS doc_socio_final,
  CASE WHEN aceito AND NOT ambiguo THEN tipo
       WHEN NOT coalesce(aceito, false) AND cpf_rep IS NOT NULL THEN 'CPF' END               AS tipo_doc_final,
  fn_formata_doc(CASE WHEN aceito AND NOT ambiguo THEN doc
                      WHEN NOT coalesce(aceito, false) AND cpf_rep IS NOT NULL THEN cpf_rep END) AS doc_socio_final_formatado,

  -- >>> FLAG <<<  1 = encontrado/validado, 0 = não encontrado
  CASE WHEN (aceito AND NOT ambiguo) OR (NOT coalesce(aceito, false) AND cpf_rep IS NOT NULL)
       THEN 1 ELSE 0 END                                                                    AS flag_doc_encontrado,

  CASE WHEN aceito AND ambiguo                         THEN 'AMBIGUO_MULTIPLOS_DOCS'
       WHEN aceito                                     THEN status_candidato
       WHEN cpf_rep IS NOT NULL                        THEN 'RECUPERADO_MASCARA_NOME'
       WHEN doc IS NOT NULL                            THEN status_candidato      -- rejeitado / fora da RF
       WHEN ccpf_cnpj IS NULL                          THEN 'SEM_DOCUMENTO'
       ELSE                                                 'NENHUMA_HIPOTESE_DV_VALIDA'
  END                                                                                       AS status_validacao,

  CASE WHEN aceito AND ambiguo THEN 'BAIXA'
       WHEN aceito             THEN nivel_confianca
       WHEN cpf_rep IS NOT NULL THEN 'MEDIA'
       ELSE 'BAIXA' END                                                                     AS nivel_confianca,

  -- rastreabilidade
  doc                                                  AS doc_melhor_tentativa,  -- mesmo quando rejeitado
  tipo                                                 AS tipo_melhor_tentativa,
  hipoteses                                            AS hipotese_vencedora,
  dv_reconstruido,
  score,
  coalesce(CASE WHEN aceito THEN sim_nome END, sim_rep, sim_nome)      AS similaridade_nome,
  coalesce(CASE WHEN aceito THEN nome_rf  END, nome_rf_rep, nome_rf)   AS nome_rf,
  situacao_rf,
  ambiguo                                              AS flag_ambiguo
FROM k;


-- =====================================================================================
-- 8. DIAGNÓSTICO
-- =====================================================================================

-- 8.1 Resultado geral
SELECT status_validacao, nivel_confianca, tipo_doc_final, flag_doc_encontrado,
       count(*) AS qtd, round(100 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM socio_doc_final
GROUP BY ALL
ORDER BY qtd DESC;

-- 8.2 Mesma quebra do seu anexo (lengths dos 3 pedaços) x resultado -> mostra qual regra vale em cada padrão
SELECT length(ccpf_cnpj) AS len_base, length(cflial_cpf_cnpj) AS len_filial, length(cctrl_cpf_cnpj) AS len_ctrl,
       tipo_doc_final, hipotese_vencedora, flag_doc_encontrado, count(*) AS qtd
FROM socio_doc_final
GROUP BY ALL
ORDER BY len_base, len_filial, len_ctrl, qtd DESC;

-- 8.3 Amostra para conferência manual dos casos de menor confiança
SELECT * FROM socio_doc_final
WHERE status_validacao IN ('VALIDADO_RF_NOME_PARCIAL', 'REJEITADO_RF_NOME_DIVERGENTE',
                           'RECUPERADO_MASCARA_NOME', 'AMBIGUO_MULTIPLOS_DOCS', 'VALIDADO_RF_NOME_DV_RECONSTRUIDO')
ORDER BY rand() LIMIT 200;
