-- =====================================================================================
-- RECONSTRUÇÃO E VALIDAÇÃO DO CPF/CNPJ DOS SÓCIOS (ccpf_cnpj + cflial_cpf_cnpj + cctrl_cpf_cnpj)
-- Databricks SQL (SQL warehouse serverless ou notebook %sql). Rodar as células em ordem,
-- na MESMA sessão (funções e views são temporárias). Nada é gravado em tabela.
--
-- Fluxo (linear, cada fonte grande é lida uma vez no fluxo principal):
--   vw_socio_src -> 01_base (normaliza, calcula DVs e monta as hipóteses válidas num array)
--                -> 02_candidatos (explode o array; sócio sem hipótese válida continua com 1 linha)
--                -> 03_match (2 LEFT JOINs com a RF no mesmo shuffle + nome + classe de evidência)
--                -> 04_vencedor (1 janela por sócio)
--                -> 05_repescagem (só pendentes: dígitos 4-9 + 1º nome como chave de join)
--                -> vw_socio_doc_final
--
-- Performance (v2):
--   * DV calculado com aritmética explícita (sem sequence/aggregate/lambda) e UMA vez por sócio;
--     a validade de cada hipótese vira comparação de strings.
--   * Só hipóteses com DV válido saem do explode; nada de GROUP BY para deduplicar.
--   * RF PF/PJ agregadas por documento na própria chave do join (sem shuffle extra).
--   * Nome: chave "suave" (sem acento, partícula, H, letra dobrada, Y/W/Z/K/Q unificados)
--     + Levenshtein com limite + Jaccard de palavras. Sem a cadeia fonética de 15 regex.
--   * Repescagem: join por (dígitos 4-9, 1º nome) em vez de só dígitos 4-9 (~1 par por
--     sócio em vez de ~200).
--
-- Decisão (v3, calibrada com casos reais):
--   * O vencedor sai por CLASSE DE EVIDÊNCIA, não por soma de pontos. Nome confirmado pela
--     RF vem antes de tudo: um CPF confirmado pelo nome ganha de um CNPJ sem confirmação,
--     mesmo com filial > 0 e mesmo com o DV do CPF recalculado.
--   * CNPJ que só passa no DV e existe na RF, mas cujo nome não bate com a razão social nem com
--     o nome fantasia, fica PENDENTE (flag 0):
--     com filial 0001, grande parte das raízes de 8 dígitos existe na RF, então DV + existência
--     sozinhos não bastam (o DV bate por acaso em 1 de cada 100 leituras).
--   * Nome: um nome contido no outro (sobrenome de casada acrescentado/retirado, nome
--     truncado) ou mesmo 1º nome + 1º sobrenome conta como confirmação; 1º nome diferente
--     (ADRIANO x ADRIANA) nunca confirma CPF.
-- =====================================================================================


-- =====================================================================================
-- 0. FUNÇÕES (temporárias, valem para a sessão)
-- =====================================================================================

-- ---------- Documento ----------
-- Maiúsculas, só [0-9A-Z] (A-Z por causa do CNPJ alfanumérico, jul/2026)
CREATE OR REPLACE TEMPORARY FUNCTION fn_limpa_doc(x STRING)
RETURNS STRING
RETURN NULLIF(regexp_replace(upper(trim(x)), '[^0-9A-Z]', ''), '');

-- Remove zeros à esquerda (mantém ao menos 1 caractere). O padding é refeito depois com LPAD.
CREATE OR REPLACE TEMPORARY FUNCTION fn_sem_zeros(x STRING)
RETURNS STRING
RETURN regexp_replace(x, '^0+(?=.)', '');

-- Valor do caractere i (ASCII-48: dígito 0..9, letra 17..42 no CNPJ alfanumérico)
CREATE OR REPLACE TEMPORARY FUNCTION fn_d(s STRING, i INT)
RETURNS INT
RETURN ascii(substr(s, i, 1)) - 48;

-- CPF: s1 = soma com pesos 10..2 ; sd = soma simples. Como os pesos do 2º DV são os do 1º + 1,
-- s2 = s1 + sd + 2*dv1  -> os 2 DVs saem de uma única passada pelos 9 dígitos.
CREATE OR REPLACE TEMPORARY FUNCTION fn_cpf_dv_de(s1 INT, sd INT)
RETURNS STRING
RETURN concat(
  CAST(pmod(s1 * 10, 11) % 10 AS STRING),
  CAST(pmod((s1 + sd + 2 * (pmod(s1 * 10, 11) % 10)) * 10, 11) % 10 AS STRING)
);

-- Os 2 DVs a partir da base de 9 dígitos (quem chama garante que são 9 dígitos)
CREATE OR REPLACE TEMPORARY FUNCTION fn_cpf_dv(b9 STRING)
RETURNS STRING
RETURN CASE WHEN length(b9) = 9 THEN fn_cpf_dv_de(
    10*fn_d(b9,1) + 9*fn_d(b9,2) + 8*fn_d(b9,3) + 7*fn_d(b9,4) + 6*fn_d(b9,5)
  +  5*fn_d(b9,6) + 4*fn_d(b9,7) + 3*fn_d(b9,8) + 2*fn_d(b9,9),
       fn_d(b9,1) +   fn_d(b9,2) +   fn_d(b9,3) +   fn_d(b9,4) +   fn_d(b9,5)
  +    fn_d(b9,6) +   fn_d(b9,7) +   fn_d(b9,8) +   fn_d(b9,9))
END;

-- CNPJ: dv = 0 se (soma mod 11) < 2, senão 11 - (soma mod 11)
CREATE OR REPLACE TEMPORARY FUNCTION fn_mod11_cnpj(x INT)
RETURNS INT
RETURN CASE WHEN pmod(x, 11) < 2 THEN 0 ELSE 11 - pmod(x, 11) END;

-- Pesos do 2º DV = pesos do 1º + 1, exceto a 5ª posição (9 -> 2, ou seja -7):
-- s2 = s1 + sd - 8*d5 + 2*dv1
CREATE OR REPLACE TEMPORARY FUNCTION fn_cnpj_dv_de(s1 INT, sd INT, d5 INT)
RETURNS STRING
RETURN concat(
  CAST(fn_mod11_cnpj(s1) AS STRING),
  CAST(fn_mod11_cnpj(s1 + sd - 8 * d5 + 2 * fn_mod11_cnpj(s1)) AS STRING)
);

CREATE OR REPLACE TEMPORARY FUNCTION fn_cnpj_dv(b12 STRING)
RETURNS STRING
RETURN CASE WHEN length(b12) = 12 THEN fn_cnpj_dv_de(
    5*fn_d(b12,1) + 4*fn_d(b12,2)  + 3*fn_d(b12,3)  + 2*fn_d(b12,4)  + 9*fn_d(b12,5)  + 8*fn_d(b12,6)
  + 7*fn_d(b12,7) + 6*fn_d(b12,8)  + 5*fn_d(b12,9)  + 4*fn_d(b12,10) + 3*fn_d(b12,11) + 2*fn_d(b12,12),
      fn_d(b12,1) +   fn_d(b12,2)  +   fn_d(b12,3)  +   fn_d(b12,4)  +   fn_d(b12,5)  +   fn_d(b12,6)
  +   fn_d(b12,7) +   fn_d(b12,8)  +   fn_d(b12,9)  +   fn_d(b12,10) +   fn_d(b12,11) +   fn_d(b12,12),
  fn_d(b12,5))
END;

-- Validação completa (usada só nos casos raros de documento inteiro num campo só e nos testes)
CREATE OR REPLACE TEMPORARY FUNCTION fn_cpf_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9]{11}$'
  AND c <> repeat(substr(c, 1, 1), 11)
  AND substr(c, 10, 2) = fn_cpf_dv(substr(c, 1, 9)),
  false);

CREATE OR REPLACE TEMPORARY FUNCTION fn_cnpj_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9A-Z]{12}[0-9]{2}$'
  AND c <> repeat(substr(c, 1, 1), 14)
  AND substr(c, 9, 4) <> '0000'
  AND substr(c, 13, 2) = fn_cnpj_dv(substr(c, 1, 12)),
  false);

-- ---------- Nome ----------
-- Limpeza base: maiúsculas, sem acento, só letras/dígitos, espaços colapsados.
-- Nome mascarado (XXXX, XXXXX X) vira NULL = "sem nome para comparar".
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_limpo(x STRING)
RETURNS STRING
RETURN NULLIF(regexp_replace(trim(regexp_replace(
  translate(upper(x), 'ÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝŸ', 'AAAAAAEEEEIIIIOOOOOUUUUCNYY'),
  '[^A-Z0-9]+', ' ')), '^[X ]+$', ''), '');

-- Chave PF "suave": sem dígitos, sem partículas/títulos/ESPOLIO, Y->I W->V Z->S K->C Q->C,
-- sem H e sem letra dobrada. Cobre SOUZA=SOUSA, THIAGO=TIAGO, WALDIR=VALDIR, CAMILLA=KAMILA
-- sem precisar de função fonética.
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_chave_pf(x STRING)
RETURNS STRING
RETURN NULLIF(trim(regexp_replace(regexp_replace(regexp_replace(
  translate(concat(' ', fn_nome_limpo(x), ' '), 'YWZKQH0123456789', 'IVSCC'),
  '(?<= )(DE|DA|DO|DAS|DOS|DI|DU|D|E|DEL|DELLA|VAN|VON|DR|DRA|SR|SRA|ESPOLIO)(?= )', ''),
  '([A-Z])\\1+', '$1'),
  ' +', ' ')), '');

-- Chave PJ: sem natureza jurídica / porte (LTDA, S A, ME, EPP, EIRELI...), partículas e
-- dígitos (razão social de MEI termina com o CPF: "FULANA DE TAL 12345678900")
CREATE OR REPLACE TEMPORARY FUNCTION fn_nome_chave_pj(x STRING)
RETURNS STRING
RETURN NULLIF(trim(regexp_replace(regexp_replace(regexp_replace(
  translate(regexp_replace(
    concat(' ', fn_nome_limpo(x), ' '),
    ' (EM RECUPERACAO JUDICIAL|EM LIQUIDACAO( EXTRAJUDICIAL)?|SOCIEDADE ANONIMA|SOCIEDADE SIMPLES|MICRO ?EMPRESA|EMPRESA INDIVIDUAL|S ?A|S ?S) ', ' '),
    'YWZKQH0123456789', 'IVSCC'),
  '(?<= )(LTDA|LIMITADA|ME|EPP|MEI|EIRELI|SLU|CIA|COMPANIA|DE|DA|DO|DAS|DOS|E)(?= )', ''),
  '([A-Z])\\1+', '$1'),
  ' +', ' ')), '');

-- 1º nome (só translate, sem regex): chave barata do join da repescagem, aplicada nos 2 lados
CREATE OR REPLACE TEMPORARY FUNCTION fn_primeiro_nome(x STRING)
RETURNS STRING
RETURN NULLIF(translate(substring_index(
  translate(upper(trim(x)), 'ÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝŸ', 'AAAAAAEEEEIIIIOOOOOUUUUCNYY'),
  ' ', 1), 'YWZKQH', 'IVSCC'), '');

-- 1º nome "parecido": igual; ou um é o outro com 1 letra a mais no fim (VALDECIRD x VALDECIR);
-- ou 1 letra trocada no meio com a MESMA letra final. Não aceita ADRIANO x ADRIANA, MARIO x MARIA.
CREATE OR REPLACE TEMPORARY FUNCTION fn_primeiro_parecido(p STRING, q STRING)
RETURNS BOOLEAN
RETURN p = q
  OR (least(length(p), length(q)) >= 4 AND abs(length(p) - length(q)) = 1
      AND (left(p, length(q)) = q OR left(q, length(p)) = p))
  OR (least(length(p), length(q)) >= 5 AND length(p) = length(q)
      AND right(p, 1) = right(q, 1) AND levenshtein(p, q, 1) = 1);

-- Similaridade 0..1 entre duas CHAVES (já normalizadas). NULL se faltar um lado.
-- pf = true: comparação de pessoa física -> se o 1º nome não for parecido, no máximo 0.60
--            (é outra pessoa da família: cônjuge, irmão).
-- levenshtein(a, b, 8): para de calcular acima de 8 edições (devolve -1).
--   (se o seu runtime não aceitar o 3º argumento, troque por levenshtein(a, b) aqui e acima)
CREATE OR REPLACE TEMPORARY FUNCTION fn_sim_nome(a STRING, b STRING, pf BOOLEAN)
RETURNS DOUBLE
RETURN CASE
  WHEN a IS NULL OR b IS NULL THEN CAST(NULL AS DOUBLE)
  WHEN a = b THEN 1.0D
  WHEN fn_primeiro_parecido(substring_index(a, ' ', 1), substring_index(b, ' ', 1)) THEN greatest(
    -- Levenshtein normalizado (erros de digitação)
    1.0D - coalesce(nullif(levenshtein(a, b, 8), -1), 99) / greatest(length(a), length(b)),
    -- Jaccard de palavras
    size(array_intersect(split(a, ' '), split(b, ' '))) / size(array_union(split(a, ' '), split(b, ' '))),
    CASE WHEN a LIKE '% %' AND b LIKE '% %' THEN CASE
      -- um nome contido no outro, fora o 1º nome: sobrenome de casada acrescentado/retirado,
      -- nome truncado (LUIZA NIEDERLE x LUIZA NIEDERLE RENGER, CLARICE MALTA DOS SANTOS x CLARICE MALTA)
      WHEN size(array_except(slice(split(a, ' '), 2, 99), split(b, ' '))) = 0
        OR size(array_except(slice(split(b, ' '), 2, 99), split(a, ' '))) = 0 THEN 0.92D
      -- mesmo 1º nome e mesmo 1º sobrenome (REGIANE DA SILVA FREITAS x REGIANE DA SILVA FARIA SANTOS)
      WHEN substring_index(substring_index(a, ' ', 2), ' ', -1)
         = substring_index(substring_index(b, ' ', 2), ' ', -1) THEN 0.88D
      -- mesmo 1º e último nome (JOSE C SILVA x JOSE CARLOS SILVA)
      WHEN substring_index(a, ' ', -1) = substring_index(b, ' ', -1) THEN 0.86D
    END END,
    0.0D)
  ELSE CASE WHEN pf THEN least(0.60D, greatest(
         1.0D - coalesce(nullif(levenshtein(a, b, 8), -1), 99) / greatest(length(a), length(b)),
         size(array_intersect(split(a, ' '), split(b, ' '))) / size(array_union(split(a, ' '), split(b, ' '))),
         0.0D))
       ELSE greatest(
         1.0D - coalesce(nullif(levenshtein(a, b, 8), -1), 99) / greatest(length(a), length(b)),
         size(array_intersect(split(a, ' '), split(b, ' '))) / size(array_union(split(a, ' '), split(b, ' '))),
         0.0D)
       END
END;

-- Máscara visual
CREATE OR REPLACE TEMPORARY FUNCTION fn_formata_doc(d STRING)
RETURNS STRING
RETURN CASE length(d)
  WHEN 11 THEN concat(substr(d,1,3),'.',substr(d,4,3),'.',substr(d,7,3),'-',substr(d,10,2))
  WHEN 14 THEN concat(substr(d,1,2),'.',substr(d,3,3),'.',substr(d,6,3),'/',substr(d,9,4),'-',substr(d,13,2))
END;

-- Testes rápidos (devem voltar todos TRUE)
SELECT
  fn_cpf_dv('529982247') = '25'                  AS cpf_dv,
  fn_cpf_valido('52998224725')                   AS cpf_ok,
  NOT fn_cpf_valido('52998224724')               AS cpf_dv_errado,
  NOT fn_cpf_valido('11111111111')               AS cpf_repetido,
  fn_cnpj_dv('112223330001') = '81'              AS cnpj_dv,
  fn_cnpj_valido('12ABC34501DE35')               AS cnpj_alfanum_ok,
  NOT fn_cnpj_valido('11222333000182')           AS cnpj_dv_errado,
  fn_nome_chave_pf('Thiago de Souza') = fn_nome_chave_pf('TIAGO SOUSA')        AS chave_suave,
  fn_nome_chave_pf('Camilla Wanderley') = fn_nome_chave_pf('KAMILA VANDERLEI') AS chave_suave2,
  fn_nome_limpo('XXXXX') IS NULL                                               AS mascarado_nulo,
  -- casos reais do seu print (todos corretos): precisam dar >= 0.85
  fn_sim_nome(fn_nome_chave_pf('LUIZA NIEDERLE'),           fn_nome_chave_pf('LUIZA NIEDERLE RENGER'), true)         >= 0.85 AS real_sobrenome_a_mais,
  fn_sim_nome(fn_nome_chave_pf('CLARICE MALTA DOS SANTOS'), fn_nome_chave_pf('CLARICE MALTA'), true)                 >= 0.85 AS real_sobrenome_a_menos,
  fn_sim_nome(fn_nome_chave_pf('REGIANE DA SILVA FREITAS'), fn_nome_chave_pf('REGIANE DA SILVA FARIA SANTOS'), true) >= 0.85 AS real_1o_sobrenome,
  fn_sim_nome(fn_nome_chave_pf('VALDECIRD DE SIQUEIRA'),    fn_nome_chave_pf('VALDECIR DONIZETI DE SIQUEIRA'), true) >= 0.85 AS real_1o_nome_digitado,
  fn_sim_nome(fn_nome_chave_pf('JOSE C DA SILVA'),          fn_nome_chave_pf('José Carlos da Silva'), true)          >= 0.85 AS abreviado,
  -- outra pessoa da família: precisa ficar < 0.70
  fn_sim_nome(fn_nome_chave_pf('ADRIANO GOMES SILVA'),      fn_nome_chave_pf('ADRIANA GOMES SILVA'), true)            < 0.70 AS irmao_nao_confirma,
  fn_sim_nome(fn_nome_chave_pf('MARIA APARECIDA SANTOS'),   fn_nome_chave_pf('JOAO PEDRO LIMA'), true)                < 0.70 AS diferente;


-- =====================================================================================
-- 1. FONTES
-- =====================================================================================

-- Quadro societário: a sua query, com UMA mudança nos 3 pedaços do documento.
-- Eles vão CRUS (sem iff/lpad/coalesce com 0) porque:
--   * lpad(x, 8) CORTA quem tem 9 caracteres (lpad('123456789', 8, '0') = '12345678'),
--     perdendo o último dígito da base;
--   * o ", 0" transforma controle/filial NULL em '0'/'00', apagando a informação de que o
--     controle veio vazio (e gera candidato falso '000000000' + '00');
--   * '::int' no *_st quebra em ANSI se aparecer letra (CNPJ alfanumérico).
-- O padding e o teste CPF x CNPJ são feitos na vw_socio_doc_01_base, para toda linha.
CREATE OR REPLACE TEMPORARY VIEW vw_socio_src AS
SELECT
    q_socio.cclub
  , q_socio.cseq_quadr_empr
  , coalesce(CAST(q_socio.ccpf_cnpj       AS STRING), CAST(q_socio.ccpf_cnpj_st       AS STRING)) AS ccpf_cnpj
  , coalesce(CAST(q_socio.cflial_cpf_cnpj AS STRING), CAST(q_socio.cflial_cpf_cnpj_st AS STRING)) AS cflial_cpf_cnpj
  , coalesce(CAST(q_socio.cctrl_cpf_cnpj  AS STRING), CAST(q_socio.cctrl_cpf_cnpj_st  AS STRING)) AS cctrl_cpf_cnpj
  , q_socio.ipartc_empr AS nome_socio
  , q_socio.cindcd_quadr_scial
  , q_socio.pcaptl_tot
  , q_socio.dinic_prtcp_scial
  , q_socio.dfim_prtcp_scial
  , q_socio.ccargo_quadr_admtv
  , q_socio.cindcd_quadr_admtv
  , q_socio.dfim_prtcp_admtv
  , q_socio.hextrc_hpu
FROM pr_platfun.psdc_ing.tquadr_pssoa AS q_socio
WHERE 1=1
  AND q_socio.catulz_reg != 'D'
  -- AND q_socio.cindcd_quadr_scial = 'S'
  -- AND q_socio.dfim_prtcp_scial IS NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY q_socio.cclub, q_socio.cseq_quadr_empr ORDER BY q_socio.hextrc_hpu DESC) = 1;

-- RF Pessoa Física: 1 linha por CPF. O GROUP BY usa a mesma chave do join, então não
-- custa um shuffle a mais (e evita linha duplicada se a RF repetir CPF).
CREATE OR REPLACE TEMPORARY VIEW vw_rf_pf AS
SELECT
  lpad(trim(CAST(documento_pessoa AS STRING)), 11, '0')   AS cpf,
  max(coalesce(nome_pessoa_normalizado, nome_pessoa))     AS nome_rf
FROM pr_explo.d4852s185_imdm.table_vmmp_vw_rbrf            -- <<AJUSTE>> confira o nome
WHERE documento_pessoa IS NOT NULL
GROUP BY 1;

-- RF Estabelecimentos + razão social: 1 linha por CNPJ (zeros à esquerda recompostos com LPAD).
-- O sócio PJ vem com a razão social, e o nome fantasia quase nunca bate com ela; por isso o nome
-- do CNPJ é comparado com os dois (vale o melhor). Para MEI a razão social é "NOME DA PESSOA + CPF"
-- e bate com o nome do sócio (os dígitos são ignorados na comparação).
-- <<AJUSTE>> troque replaceaqui_empresas pelo nome completo da tabela de empresas.
-- <<AJUSTE>> se as tabelas tiverem várias fotos (anomesdia), filtre só a mais recente nos WHEREs.
CREATE OR REPLACE TEMPORARY VIEW vw_rf_pj AS
WITH emp AS (          -- razão social: 1 linha por raiz (8 dígitos)
  SELECT
    lpad(trim(CAST(ccpf_cnpj AS STRING)), 8, '0')  AS raiz,
    max(irz_scial_empr)                            AS nome_rf_razao
  FROM replaceaqui_empresas
  WHERE ccpf_cnpj IS NOT NULL AND irz_scial_empr IS NOT NULL
  GROUP BY 1
),
est AS (
  SELECT
    lpad(trim(CAST(e.ccpf_cnpj AS STRING)), 8, '0')            AS raiz,
    concat(lpad(trim(CAST(e.ccpf_cnpj       AS STRING)), 8, '0'),
           lpad(trim(CAST(e.cflial_cpf_cnpj AS STRING)), 4, '0'),
           lpad(trim(CAST(e.cctrl_cpf_cnpj  AS STRING)), 2, '0'))  AS cnpj,
    e.ifants_estbl,
    e.csit_recta_fedrl
  FROM pr_platfun.aadg_ing.estabelecimento_anomesdia e
  WHERE e.ccpf_cnpj IS NOT NULL AND e.cctrl_cpf_cnpj IS NOT NULL
)
SELECT
  est.cnpj,
  max(est.ifants_estbl)                 AS nome_rf,        -- nome fantasia
  max(emp.nome_rf_razao)                AS nome_rf_razao,  -- razão social
  bool_or(est.csit_recta_fedrl = 2)     AS ativa_rf
FROM est
LEFT JOIN emp ON emp.raiz = est.raiz
-- raiz no GROUP BY: o agrupamento aproveita o particionamento do join por raiz (sem shuffle a mais)
GROUP BY est.raiz, est.cnpj;


-- =====================================================================================
-- 2. SÓCIOS NORMALIZADOS + DVs (1x por sócio) + HIPÓTESES VÁLIDAS NUM ARRAY
--    Função SQL não pode ir dentro do LATERAL VIEW; por isso o array é montado aqui,
--    só com colunas já calculadas, e o explode (passo 3) recebe só a coluna.
--    prior = plausibilidade estrutural (0-10), só serve de desempate.
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_01_base AS
WITH x AS (   -- limpeza (zeros à esquerda removidos; o LPAD certo é aplicado em cada hipótese)
  SELECT s.*,
    fn_sem_zeros(fn_limpa_doc(s.ccpf_cnpj))       AS b,
    fn_sem_zeros(fn_limpa_doc(s.cflial_cpf_cnpj)) AS f,
    fn_sem_zeros(fn_limpa_doc(s.cctrl_cpf_cnpj))  AS c,
    fn_nome_chave_pf(s.nome_socio)                AS nome_chave_pf,
    fn_primeiro_nome(s.nome_socio)                AS pnome
  FROM vw_socio_src s
),
y AS (        -- flags e bases de cada tipo
  SELECT x.*,
    length(b)                                     AS len_b,
    b RLIKE '^[0-9]+$'                            AS b_num,
    (f IS NULL OR f = '0')                        AS f_zero,
    CASE WHEN c RLIKE '^[0-9]{1,2}$' THEN lpad(c, 2, '0') END                        AS c2,
    CASE WHEN b RLIKE '^[0-9]{1,9}$' THEN lpad(b, 9, '0') END                         AS cpf_b9,
    -- CNPJ raiz(8) + filial(4); filial vazia/zero -> 0001 (matriz)
    CASE WHEN length(b) <= 8 AND b <> '0' AND coalesce(length(f), 0) <= 4
         THEN concat(lpad(b, 8, '0'), lpad(CASE WHEN f IS NULL OR f = '0' THEN '1' ELSE f END, 4, '0')) END AS cnpj_b12,
    -- CNPJ com base de 9 dígitos significativos (descarta o 1º) - improvável, baixa prioridade
    CASE WHEN length(b) = 9 AND f IS NOT NULL AND f <> '0' AND length(f) <= 4
         THEN concat(right(b, 8), lpad(f, 4, '0')) END                                AS cnpj9_b12
  FROM x
),
z AS (        -- DVs: 1 cálculo por sócio e por tipo
  SELECT y.*,
    CASE WHEN cpf_b9 <> repeat(substr(cpf_b9, 1, 1), 9) THEN fn_cpf_dv(cpf_b9) END   AS cpf_dv,
    fn_cnpj_dv(cnpj_b12)                                                              AS cnpj_dv,
    fn_cnpj_dv(cnpj9_b12)                                                             AS cnpj9_dv,
    -- documento inteiro dentro do campo base (não aparece no seu perfil de lengths, mas é barato)
    CASE WHEN b_num AND len_b BETWEEN 10 AND 11 AND fn_cpf_valido(lpad(b, 11, '0'))  THEN lpad(b, 11, '0') END AS cpf_completo,
    CASE WHEN len_b BETWEEN 12 AND 14 AND fn_cnpj_valido(lpad(b, 14, '0'))           THEN lpad(b, 14, '0') END AS cnpj_completo
  FROM y
)
SELECT
  cclub, cseq_quadr_empr, ccpf_cnpj, cflial_cpf_cnpj, cctrl_cpf_cnpj, nome_socio,
  cindcd_quadr_scial, pcaptl_tot, dinic_prtcp_scial, dfim_prtcp_scial,
  ccargo_quadr_admtv, cindcd_quadr_admtv, dfim_prtcp_admtv, hextrc_hpu,
  b, len_b, b_num, f_zero, c, nome_chave_pf, pnome,
  filter(array(
    -- CPF = base(9) + controle(2), controle confere
    named_struct('hipotese', 'CPF_BASE_CTRL', 'tipo', 'CPF', 'doc', concat(cpf_b9, c2),
                 'ok', c2 = cpf_dv, 'dv_reconstruido', false,
                 'prior', CASE WHEN f_zero THEN 10 ELSE 4 END),
    -- CPF com DV recalculado (só quando o controle está vazio ou não confere)
    named_struct('hipotese', 'CPF_BASE_DVCALC', 'tipo', 'CPF', 'doc', concat(cpf_b9, cpf_dv),
                 'ok', cpf_dv IS NOT NULL AND (c2 IS NULL OR c2 <> cpf_dv), 'dv_reconstruido', true,
                 'prior', CASE WHEN c IS NULL AND f_zero THEN 6 ELSE 1 END),
    named_struct('hipotese', 'CPF_BASE_COMPLETO', 'tipo', 'CPF', 'doc', cpf_completo,
                 'ok', cpf_completo IS NOT NULL, 'dv_reconstruido', false, 'prior', 5),
    -- CNPJ = raiz(8) + filial(4, ou 0001) + controle(2), controle confere
    named_struct('hipotese', CASE WHEN f_zero THEN 'CNPJ_RAIZ_0001_CTRL' ELSE 'CNPJ_RAIZ_FILIAL_CTRL' END,
                 'tipo', 'CNPJ', 'doc', concat(cnpj_b12, c2),
                 'ok', c2 = cnpj_dv, 'dv_reconstruido', false,
                 'prior', CASE WHEN f_zero THEN 5 ELSE 10 END),
    -- CNPJ com DV recalculado (só quando o controle está vazio ou não confere)
    named_struct('hipotese', 'CNPJ_RAIZ_FILIAL_DVCALC', 'tipo', 'CNPJ', 'doc', concat(cnpj_b12, cnpj_dv),
                 'ok', cnpj_dv IS NOT NULL AND (c2 IS NULL OR c2 <> cnpj_dv), 'dv_reconstruido', true,
                 'prior', CASE WHEN c IS NULL THEN 5 ELSE 1 END),
    named_struct('hipotese', 'CNPJ_BASE9_TRUNC', 'tipo', 'CNPJ', 'doc', concat(cnpj9_b12, c2),
                 'ok', c2 = cnpj9_dv, 'dv_reconstruido', false, 'prior', 2),
    named_struct('hipotese', 'CNPJ_BASE_COMPLETO', 'tipo', 'CNPJ', 'doc', cnpj_completo,
                 'ok', cnpj_completo IS NOT NULL, 'dv_reconstruido', false, 'prior', 5)
  ), h -> coalesce(h.ok, false)) AS candidatos
FROM z;


-- =====================================================================================
-- 3. UMA LINHA POR HIPÓTESE VÁLIDA (docs já distintos por sócio; OUTER mantém quem não tem nenhuma)
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_02_candidatos AS
SELECT s.* EXCEPT (candidatos), t.hipotese, t.tipo, t.doc, t.dv_reconstruido, t.prior
FROM vw_socio_doc_01_base s
LATERAL VIEW OUTER inline(s.candidatos) t;


-- =====================================================================================
-- 4. CRUZAMENTO COM A RF + SIMILARIDADE DE NOME + CLASSE DE EVIDÊNCIA
--    Os 2 LEFT JOINs usam a mesma chave (doc): os candidatos são embaralhados uma vez só.
--
--    Classe (menor = mais forte; o vencedor sai pela classe, não por soma de pontos):
--      1 VALIDADO_RF_NOME                  existe na RF + nome confirma + DV informado confere
--      2 VALIDADO_RF_NOME_DV_RECONSTRUIDO  existe na RF + nome confirma, DV recalculado
--      3 VALIDADO_RF_NOME_PARCIAL          CPF: existe + DV informado + nome 0.70-0.85
--      4 VALIDADO_RF_SEM_NOME              existe + DV informado, sem nome em um dos lados
--      5 PENDENTE_CNPJ_NOME_DIVERGENTE     CNPJ existe + DV informado, mas o nome não bate (flag 0)
--      6 REJEITADO_*                       existe, mas o nome não confirma (CPF) / DV recalculado sem confirmação
--      7 NAO_ENCONTRADO_RF_DV_VALIDO       8 NAO_ENCONTRADO_RF_DV_RECONSTRUIDO   9 SEM_HIPOTESE_DV_VALIDA
--    "Nome confirma" = similaridade >= 0.85 (CPF) ou >= 0.70 (CNPJ).
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_03_match AS
WITH j AS (
  SELECT c.*,
    (pf.cpf IS NOT NULL OR pj.cnpj IS NOT NULL)            AS encontrado_rf,
    coalesce(pf.nome_rf, pj.nome_rf_razao, pj.nome_rf)     AS nome_rf,
    pj.ativa_rf,
    -- chaves calculadas numa camada própria: fn_sim_nome recebe só colunas
    CASE WHEN c.tipo = 'CPF' THEN c.nome_chave_pf
         WHEN c.tipo = 'CNPJ' AND coalesce(pj.nome_rf, pj.nome_rf_razao) IS NOT NULL
         THEN fn_nome_chave_pj(c.nome_socio) END                           AS chave_socio,
    CASE WHEN pf.nome_rf IS NOT NULL THEN fn_nome_chave_pf(pf.nome_rf) END AS chave_rf_pf,
    CASE WHEN pj.nome_rf IS NOT NULL THEN fn_nome_chave_pj(pj.nome_rf) END AS chave_rf_fantasia,
    CASE WHEN pj.nome_rf_razao IS NOT NULL THEN fn_nome_chave_pj(pj.nome_rf_razao) END AS chave_rf_razao
  FROM vw_socio_doc_02_candidatos c
  LEFT JOIN vw_rf_pf pf ON c.tipo = 'CPF'  AND pf.cpf  = c.doc
  LEFT JOIN vw_rf_pj pj ON c.tipo = 'CNPJ' AND pj.cnpj = c.doc
),
k AS (
  SELECT j.* EXCEPT (chave_socio, chave_rf_pf, chave_rf_fantasia, chave_rf_razao),
    CASE WHEN tipo = 'CPF'  THEN fn_sim_nome(chave_socio, chave_rf_pf, true)
         WHEN tipo = 'CNPJ' THEN greatest(fn_sim_nome(chave_socio, chave_rf_razao, false),
                                          fn_sim_nome(chave_socio, chave_rf_fantasia, false))
    END AS sim_nome
  FROM j
),
classif AS (
  SELECT k.*,
    CASE
      WHEN doc IS NULL THEN 9
      WHEN encontrado_rf AND sim_nome >= CASE WHEN tipo = 'CPF' THEN 0.85 ELSE 0.70 END
           THEN CASE WHEN dv_reconstruido THEN 2 ELSE 1 END
      WHEN encontrado_rf AND NOT dv_reconstruido AND tipo = 'CPF' AND sim_nome >= 0.70 THEN 3
      WHEN encontrado_rf AND NOT dv_reconstruido AND sim_nome IS NULL                   THEN 4
      WHEN encontrado_rf AND NOT dv_reconstruido AND tipo = 'CNPJ'                      THEN 5
      WHEN encontrado_rf                                                                THEN 6
      WHEN NOT dv_reconstruido                                                          THEN 7
      ELSE                                                                                   8
    END AS classe_evidencia
  FROM k
)
SELECT c.*,
  CASE classe_evidencia
    WHEN 1 THEN 'VALIDADO_RF_NOME'
    WHEN 2 THEN 'VALIDADO_RF_NOME_DV_RECONSTRUIDO'
    WHEN 3 THEN 'VALIDADO_RF_NOME_PARCIAL'
    WHEN 4 THEN 'VALIDADO_RF_SEM_NOME'
    WHEN 5 THEN 'PENDENTE_CNPJ_NOME_DIVERGENTE'
    WHEN 6 THEN CASE WHEN dv_reconstruido THEN 'REJEITADO_DV_RECONSTRUIDO_SEM_CONFIRMACAO'
                     ELSE 'REJEITADO_RF_NOME_DIVERGENTE' END
    WHEN 7 THEN 'NAO_ENCONTRADO_RF_DV_VALIDO'
    WHEN 8 THEN 'NAO_ENCONTRADO_RF_DV_RECONSTRUIDO'
    ELSE        'SEM_HIPOTESE_DV_VALIDA'
  END                                                              AS status_candidato,
  classe_evidencia <= 4                                            AS aceito,
  CASE WHEN classe_evidencia <= 2 THEN 'ALTA'
       WHEN classe_evidencia <= 4 THEN 'MEDIA'
       ELSE 'BAIXA' END                                            AS nivel_confianca,
  -- score 0-99 que segue a classe (só informativo; +0..4 pelo nome dentro da classe)
  CASE classe_evidencia WHEN 1 THEN 95 WHEN 2 THEN 90 WHEN 3 THEN 80 WHEN 4 THEN 70
                        WHEN 5 THEN 50 WHEN 6 THEN 20 WHEN 7 THEN 10 WHEN 8 THEN 5 ELSE 0 END
    + CAST(round(4 * coalesce(sim_nome, 0)) AS INT)                AS score
FROM classif c;


-- =====================================================================================
-- 5. MELHOR CANDIDATO POR SÓCIO (1 janela): classe -> nome -> plausibilidade estrutural
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_04_vencedor AS
SELECT * FROM (
  SELECT m.*,
    ROW_NUMBER()            OVER w AS rk,
    LEAD(classe_evidencia)  OVER w AS classe_2o
  FROM vw_socio_doc_03_match m
  WINDOW w AS (PARTITION BY cclub, cseq_quadr_empr
               ORDER BY classe_evidencia, sim_nome DESC NULLS LAST, prior DESC, doc)
) WHERE rk = 1;


-- =====================================================================================
-- 6. REPESCAGEM: CPF não resolvido -> dígitos 4-9 (máscara ***.XXX.XXX-**) + 1º nome
--    Cobre erro nos 3 primeiros dígitos / no controle e bases já mascaradas (len 6).
--    Aceita só se houver UMA única pessoa na RF com essa máscara e nome ~idêntico (>= 0.95).
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_05_repescagem AS
WITH pend AS (
  SELECT cclub, cseq_quadr_empr, nome_chave_pf, pnome,
         substr(lpad(b, 9, '0'), 4, 6) AS mascara
  FROM vw_socio_doc_04_vencedor
  WHERE NOT aceito
    AND b_num AND len_b BETWEEN 6 AND 9 AND f_zero
    AND pnome IS NOT NULL
    AND nome_chave_pf LIKE '% %'                          -- nome com 1 palavra é arriscado
),
pf AS (
  SELECT cpf, nome_rf, substr(cpf, 4, 6) AS mascara, fn_primeiro_nome(nome_rf) AS pnome
  FROM vw_rf_pf
),
hits AS (
  SELECT d.cclub, d.cseq_quadr_empr, p.cpf, p.nome_rf,
         fn_nome_chave_pf(p.nome_rf) AS chave_rf, d.nome_chave_pf
  FROM pend d
  JOIN pf p ON p.mascara = d.mascara AND p.pnome = d.pnome
),
sim AS (
  SELECT h.*, fn_sim_nome(nome_chave_pf, chave_rf, true) AS sim_nome FROM hits h
)
SELECT cclub, cseq_quadr_empr,
       max(cpf) AS cpf, max(nome_rf) AS nome_rf, max(sim_nome) AS sim_nome
FROM sim
WHERE sim_nome >= 0.95
GROUP BY cclub, cseq_quadr_empr
HAVING count(DISTINCT cpf) = 1;


-- =====================================================================================
-- 7. RESULTADO FINAL (1 linha por sócio)
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_socio_doc_final AS
WITH j AS (
  SELECT v.*,
    r.cpf AS cpf_rep, r.nome_rf AS nome_rf_rep, r.sim_nome AS sim_rep,
    -- ambíguo: o 2º colocado (outro documento) tem a MESMA classe de evidência do vencedor
    -- (ex.: nome mascarado e tanto a leitura CPF quanto a CNPJ existem na RF)
    coalesce(v.aceito AND v.classe_2o = v.classe_evidencia, false) AS ambiguo
  FROM vw_socio_doc_04_vencedor v
  LEFT JOIN vw_socio_doc_05_repescagem r
    ON r.cclub = v.cclub AND r.cseq_quadr_empr = v.cseq_quadr_empr
),
k AS (
  SELECT j.*,
    CASE WHEN aceito AND NOT ambiguo             THEN doc
         WHEN NOT aceito AND cpf_rep IS NOT NULL THEN cpf_rep END  AS doc_ok,
    CASE WHEN aceito AND NOT ambiguo             THEN tipo
         WHEN NOT aceito AND cpf_rep IS NOT NULL THEN 'CPF' END    AS tipo_ok
  FROM j
)
SELECT
  cclub, cseq_quadr_empr, ccpf_cnpj, cflial_cpf_cnpj, cctrl_cpf_cnpj, nome_socio,
  cindcd_quadr_scial, pcaptl_tot, dinic_prtcp_scial, dfim_prtcp_scial,
  ccargo_quadr_admtv, cindcd_quadr_admtv, dfim_prtcp_admtv, hextrc_hpu,

  -- >>> CAMPO PRINCIPAL <<<
  doc_ok                                                    AS doc_socio_final,
  tipo_ok                                                   AS tipo_doc_final,
  fn_formata_doc(doc_ok)                                    AS doc_socio_final_formatado,

  -- >>> FLAG <<<  1 = encontrado/validado, 0 = não encontrado
  CASE WHEN doc_ok IS NOT NULL THEN 1 ELSE 0 END            AS flag_doc_encontrado,

  CASE WHEN aceito AND ambiguo      THEN 'AMBIGUO_MULTIPLOS_DOCS'
       WHEN aceito                  THEN status_candidato
       WHEN cpf_rep IS NOT NULL     THEN 'RECUPERADO_MASCARA_NOME'
       WHEN ccpf_cnpj IS NULL       THEN 'SEM_DOCUMENTO'
       ELSE                              status_candidato     -- pendente / rejeitado / fora da RF / sem hipótese
  END                                                       AS status_validacao,

  CASE WHEN aceito AND ambiguo      THEN 'BAIXA'
       WHEN aceito                  THEN nivel_confianca
       WHEN cpf_rep IS NOT NULL     THEN 'MEDIA'
       ELSE 'BAIXA' END                                     AS nivel_confianca,

  -- rastreabilidade
  classe_evidencia,
  doc                                                       AS doc_melhor_tentativa,   -- mesmo quando rejeitado
  tipo                                                      AS tipo_melhor_tentativa,
  hipotese                                                  AS hipotese_vencedora,
  dv_reconstruido,
  score,
  CASE WHEN NOT aceito AND cpf_rep IS NOT NULL THEN sim_rep     ELSE sim_nome END AS similaridade_nome,
  CASE WHEN NOT aceito AND cpf_rep IS NOT NULL THEN nome_rf_rep ELSE nome_rf  END AS nome_rf,
  ativa_rf,
  ambiguo                                                   AS flag_ambiguo
FROM k;


-- =====================================================================================
-- 8. DIAGNÓSTICO
--    ATENÇÃO: temp view não guarda resultado; CADA consulta abaixo reprocessa tudo.
--    Se for rodar várias, grave o final uma vez e consulte a tabela:
--    CREATE OR REPLACE TABLE <catalogo>.<schema>.socio_doc_final AS SELECT * FROM vw_socio_doc_final;
-- =====================================================================================

-- 8.1 Resultado geral
SELECT status_validacao, nivel_confianca, tipo_doc_final, flag_doc_encontrado,
       count(*) AS qtd, round(100 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM vw_socio_doc_final
GROUP BY ALL
ORDER BY qtd DESC;

-- 8.2 Mesma quebra do seu anexo (lengths dos 3 pedaços) x resultado
SELECT length(ccpf_cnpj) AS len_base, length(cflial_cpf_cnpj) AS len_filial, length(cctrl_cpf_cnpj) AS len_ctrl,
       tipo_doc_final, hipotese_vencedora, flag_doc_encontrado, count(*) AS qtd
FROM vw_socio_doc_final
GROUP BY ALL
ORDER BY len_base, len_filial, len_ctrl, qtd DESC;

-- 8.3 Amostra para conferência manual dos casos que ainda pedem olho humano
SELECT * FROM vw_socio_doc_final
WHERE status_validacao IN ('VALIDADO_RF_NOME_PARCIAL', 'VALIDADO_RF_SEM_NOME', 'PENDENTE_CNPJ_NOME_DIVERGENTE',
                           'REJEITADO_RF_NOME_DIVERGENTE', 'RECUPERADO_MASCARA_NOME', 'AMBIGUO_MULTIPLOS_DOCS')
LIMIT 200;

-- 8.4 Conflito CPF x CNPJ com dado real: sócios em que a leitura CPF e a leitura CNPJ existem
--     na RF. Mostra a melhor classe de cada lado (1-2 = nome confirmou). Se a regra estiver certa,
--     quase todo conflito tem um lado 1-2 e o outro 4-6, e o lado 1-2 é o que ganha.
SELECT classe_cpf, classe_cnpj, count(*) AS qtd
FROM (
  SELECT cclub, cseq_quadr_empr,
         min(CASE WHEN tipo = 'CPF'  AND encontrado_rf THEN classe_evidencia END) AS classe_cpf,
         min(CASE WHEN tipo = 'CNPJ' AND encontrado_rf THEN classe_evidencia END) AS classe_cnpj
  FROM vw_socio_doc_03_match
  GROUP BY cclub, cseq_quadr_empr
)
WHERE classe_cpf IS NOT NULL AND classe_cnpj IS NOT NULL
GROUP BY ALL
ORDER BY qtd DESC;

-- 8.5 Todos os candidatos dos casos reais do print (o CPF recalculado de BIANCA, NELSON etc.
--     deve aparecer com encontrado_rf = true e o mesmo nome, ganhando do CNPJ)
SELECT nome_socio, ccpf_cnpj, cflial_cpf_cnpj, cctrl_cpf_cnpj, tipo, doc, hipotese, dv_reconstruido,
       encontrado_rf, round(sim_nome, 2) AS sim_nome, nome_rf, classe_evidencia, status_candidato
FROM vw_socio_doc_03_match
WHERE nome_socio IN ('CLEMERSON CERVELIM', 'BIANCA MAIA MATTOS', 'NELSON LACHAC', 'DARIA BOBBIO DE LIMA',
                     'EDUARDO GOMES DE AZEVEDO', 'LUIZA NIEDERLE', 'VALDECIRD DE SIQUEIRA', 'REGIANE DA SILVA FREITAS')
ORDER BY nome_socio, classe_evidencia;
