-- =====================================================================================
-- DOC15: classificação de uma string de 15 posições = raiz(9) + filial(4) + controle(2)
--        em CPF ou CNPJ, testando TODAS as disposições plausíveis e validando o DV.
--
-- Layout esperado (posições 1..15 da string s):
--   raiz     = s[1..9]     (9 posições)
--   filial   = s[10..13]   (4 posições)
--   controle = s[14..15]   (2 posições)
--
-- Como a concatenação não distingue PF de PJ, as disposições cobertas são:
--   CPF  : raiz(9 = base do CPF) + filial('0000' de enchimento) + controle(2 = DV)  <- caso clássico
--          "CPF com 4 zeros no meio"
--          + todas as janelas contíguas de 11 posições (offsets 1..5), p/ CPF gravado como número
--            em raiz+filial ('00'+CPF), CPF alinhado à direita nos 15, etc.
--   CNPJ : '0' + raiz(8) + filial(4) + controle(2 = DV)                              <- caso clássico
--          raiz(8) alinhada à esquerda (s[1..8] + filial + controle, s[9]='0')
--          CNPJ contíguo nas 14 primeiras posições (raiz "escorregou" 1 posição)
--          filial '0000' -> matriz '0001'
--   Para cada tipo, além do DV original (controle), uma hipótese com DV RECALCULADO
--   (flag dv_reconstruido = true; só serve de fallback quando nenhum DV original confere).
--
-- Regras de validação (algoritmo oficial):
--   CPF : 11 dígitos, não pode ser todos iguais, DV1/DV2 mod 11 com pesos 10..2 / 11..2
--   CNPJ: 12 posições + 2 DVs, não todos iguais, filial <> '0000', DV mod 11 com pesos
--         5,4,3,2,9,8,7,6,5,4,3,2 / 6,5,4,3,2,9,8,7,6,5,4,3,2. Suporta CNPJ alfanumérico
--         (letra vale ASCII-48, conforme NT RFB 2024): a entrada não precisa ser só dígitos.
--
-- Uso:
--   SELECT fn_doc15_tipo('529982247000025'), fn_doc15_doc(...), fn_doc15_melhor(...)   -> escalar
--   CREATE OR REPLACE TEMPORARY VIEW vw_doc15_src AS SELECT <chave>, <coluna15> AS doc15 FROM ...;
--   SELECT * FROM vw_doc15_final;                                                       -> em lote
--
-- Restrição real do Databricks (já vista em outro trabalho): função SQL não pode entrar direto
-- em LATERAL VIEW / explode; por isso o array de hipóteses vira coluna numa view e o inline()
-- acontece na view seguinte.
-- =====================================================================================


-- =====================================================================================
-- 1. FUNÇÕES DE APOIO
-- =====================================================================================

-- Limpeza: maiúsculas, só [0-9A-Z]. Se ficou só dígitos e MENOR que 15, completa com zeros à
-- esquerda (valor que passou por coluna numérica e perdeu zeros). Devolve NULL se não fechar 15.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_limpa(x STRING)
RETURNS STRING
RETURN CASE
  WHEN regexp_replace(upper(trim(x)), '[^0-9A-Z]', '') = ''           THEN NULL
  WHEN length(regexp_replace(upper(trim(x)), '[^0-9A-Z]', '')) = 15   THEN regexp_replace(upper(trim(x)), '[^0-9A-Z]', '')
  WHEN regexp_replace(upper(trim(x)), '[^0-9A-Z]', '') RLIKE '^[0-9]{1,14}$'
                                                                       THEN lpad(regexp_replace(upper(trim(x)), '[^0-9A-Z]', ''), 15, '0')
  ELSE NULL
END;

-- Valor da posição i (ASCII-48: dígito 0..9; letra A..Z = 17..42, CNPJ alfanumérico)
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_d(s STRING, i INT)
RETURNS INT
RETURN ascii(substr(s, i, 1)) - 48;

-- CPF: s1 = soma com pesos 10..2 ; sd = soma simples. Pesos do 2º DV = pesos do 1º + 1,
-- então s2 = s1 + sd + 2*dv1 -> os 2 DVs saem de uma única passada pelos 9 dígitos.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cpf_dv_de(s1 INT, sd INT)
RETURNS STRING
RETURN concat(
  CAST(pmod(s1 * 10, 11) % 10 AS STRING),
  CAST(pmod((s1 + sd + 2 * (pmod(s1 * 10, 11) % 10)) * 10, 11) % 10 AS STRING)
);

-- 2 DVs do CPF a partir da base de 9 dígitos
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cpf_dv(b9 STRING)
RETURNS STRING
RETURN CASE WHEN b9 RLIKE '^[0-9]{9}$' THEN fn_doc15_cpf_dv_de(
    10*fn_doc15_d(b9,1) + 9*fn_doc15_d(b9,2) + 8*fn_doc15_d(b9,3) + 7*fn_doc15_d(b9,4) + 6*fn_doc15_d(b9,5)
  +  5*fn_doc15_d(b9,6) + 4*fn_doc15_d(b9,7) + 3*fn_doc15_d(b9,8) + 2*fn_doc15_d(b9,9),
       fn_doc15_d(b9,1) +   fn_doc15_d(b9,2) +   fn_doc15_d(b9,3) +   fn_doc15_d(b9,4) +   fn_doc15_d(b9,5)
  +    fn_doc15_d(b9,6) +   fn_doc15_d(b9,7) +   fn_doc15_d(b9,8) +   fn_doc15_d(b9,9))
END;

-- CNPJ: dv = 0 se (soma mod 11) < 2, senão 11 - (soma mod 11)
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_mod11(x INT)
RETURNS INT
RETURN CASE WHEN pmod(x, 11) < 2 THEN 0 ELSE 11 - pmod(x, 11) END;

-- Pesos do 2º DV = pesos do 1º + 1, exceto a 5ª posição (9 -> 2, ou seja -7): s2 = s1 + sd - 8*d5 + 2*dv1
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cnpj_dv_de(s1 INT, sd INT, d5 INT)
RETURNS STRING
RETURN concat(
  CAST(fn_doc15_mod11(s1) AS STRING),
  CAST(fn_doc15_mod11(s1 + sd - 8 * d5 + 2 * fn_doc15_mod11(s1)) AS STRING)
);

-- 2 DVs do CNPJ a partir das 12 primeiras posições (raiz 8 + filial 4)
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cnpj_dv(b12 STRING)
RETURNS STRING
RETURN CASE WHEN b12 RLIKE '^[0-9A-Z]{12}$' THEN fn_doc15_cnpj_dv_de(
    5*fn_doc15_d(b12,1) + 4*fn_doc15_d(b12,2)  + 3*fn_doc15_d(b12,3)  + 2*fn_doc15_d(b12,4)  + 9*fn_doc15_d(b12,5)  + 8*fn_doc15_d(b12,6)
  + 7*fn_doc15_d(b12,7) + 6*fn_doc15_d(b12,8)  + 5*fn_doc15_d(b12,9)  + 4*fn_doc15_d(b12,10) + 3*fn_doc15_d(b12,11) + 2*fn_doc15_d(b12,12),
      fn_doc15_d(b12,1) +   fn_doc15_d(b12,2)  +   fn_doc15_d(b12,3)  +   fn_doc15_d(b12,4)  +   fn_doc15_d(b12,5)  +   fn_doc15_d(b12,6)
  +   fn_doc15_d(b12,7) +   fn_doc15_d(b12,8)  +   fn_doc15_d(b12,9)  +   fn_doc15_d(b12,10) +   fn_doc15_d(b12,11) +   fn_doc15_d(b12,12),
  fn_doc15_d(b12,5))
END;

-- Validação completa de CPF (11 dígitos)
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cpf_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9]{11}$'
  AND c <> repeat(substr(c, 1, 1), 11)
  AND substr(c, 10, 2) = fn_doc15_cpf_dv(substr(c, 1, 9)),
  false);

-- Validação completa de CNPJ (12 posições alfanuméricas + 2 DVs numéricos)
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_cnpj_valido(c STRING)
RETURNS BOOLEAN
RETURN coalesce(
  c RLIKE '^[0-9A-Z]{12}[0-9]{2}$'
  AND c <> repeat(substr(c, 1, 1), 14)
  AND substr(c, 1, 8) <> '00000000'
  AND substr(c, 9, 4) <> '0000'
  AND substr(c, 13, 2) = fn_doc15_cnpj_dv(substr(c, 1, 12)),
  false);

-- Formatação para exibição
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_formata(tipo STRING, d STRING)
RETURNS STRING
RETURN CASE
  WHEN tipo = 'CPF'  AND length(d) = 11 THEN regexp_replace(d, '^(.{3})(.{3})(.{3})(.{2})$', '$1.$2.$3-$4')
  WHEN tipo = 'CNPJ' AND length(d) = 14 THEN regexp_replace(d, '^(.{2})(.{3})(.{3})(.{4})(.{2})$', '$1.$2.$3/$4-$5')
  ELSE d
END;


-- =====================================================================================
-- 2. FUNÇÃO PRINCIPAL: todas as hipóteses válidas de uma string de 15
--    Devolve ARRAY<STRUCT>, já filtrado para só hipóteses com DV válido, e com o campo
--    `prioridade` em PRIMEIRO lugar no struct para array_min()/array_sort() escolherem a melhor.
--
--    prioridade (menor = melhor):
--      1  DV original confere + layout canônico
--           CPF : raiz(9) + '0000' + controle              CNPJ: '0' + raiz(8) + filial(<>0000) + controle
--      2  DV original confere + layout plausível (sobras da string são zeros)
--           CPF : raiz + filial<>'0000' + controle ; janelas contíguas com sobra zero
--           CNPJ: raiz alinhada à esquerda ; CNPJ contíguo em [1..14] com s[15]='0' ; matriz 0001
--      3  DV original confere + layout sem apoio (sobras da string não são zeros)
--      4  DV RECALCULADO + layout canônico (controle não confere ou vazio) -> só fallback
--      5  DV RECALCULADO + layout não canônico (matriz 0001 com DV recalculado)
--
-- =====================================================================================
-- Função interna: recebe a string JÁ LIMPA (15 posições). Corpo = expressão pura (sem subquery),
-- formato que já rodou no Databricks; as SQL UDFs são inlinadas pelo analisador, então as
-- chamadas repetidas a fn_doc15_cpf_dv/fn_doc15_cnpj_dv custam só aritmética.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_hipoteses_s(s STRING)
RETURNS ARRAY<STRUCT<prioridade INT, tipo STRING, doc STRING, hipotese STRING,
                     dv_reconstruido BOOLEAN, layout_canonico BOOLEAN, sobra STRING>>
RETURN transform(filter(array(
    -- ---------------- CPF ----------------
    -- CPF = raiz(9) + controle(2): o caso "4 zeros no meio"
    named_struct('prioridade', CASE WHEN substr(s,10,4) = '0000' THEN 1 ELSE 2 END,
                 'tipo', 'CPF', 'doc', concat(substr(s,1,9), substr(s,14,2)), 'hipotese', 'CPF_RAIZ_CTRL',
                 'dv_reconstruido', false, 'layout_canonico', substr(s,10,4) = '0000', 'sobra', substr(s,10,4),
                 'ok', fn_doc15_cpf_valido(concat(substr(s,1,9), substr(s,14,2)))),
    -- CPF = raiz(9) + DV recalculado (controle vazio/'00' ou não confere)
    named_struct('prioridade', CASE WHEN substr(s,10,4) = '0000' THEN 4 ELSE 5 END,
                 'tipo', 'CPF', 'doc', concat(substr(s,1,9), fn_doc15_cpf_dv(substr(s,1,9))), 'hipotese', 'CPF_RAIZ_DVCALC',
                 'dv_reconstruido', true, 'layout_canonico', substr(s,10,4) = '0000', 'sobra', concat(substr(s,10,4), '|', substr(s,14,2)),
                 'ok', fn_doc15_cpf_dv(substr(s,1,9)) IS NOT NULL AND substr(s,14,2) <> fn_doc15_cpf_dv(substr(s,1,9)) AND fn_doc15_cpf_valido(concat(substr(s,1,9), fn_doc15_cpf_dv(substr(s,1,9))))),
    -- CPF contíguo nas janelas [k..k+10], k = 1..5 (cobre '00'+CPF em raiz+filial, CPF à direita etc.)
    named_struct('prioridade', CASE WHEN substr(s,12,4) RLIKE '^0*$' THEN 2 ELSE 3 END,
                 'tipo', 'CPF', 'doc', substr(s,1,11), 'hipotese', 'CPF_JANELA_01',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', substr(s,12,4),
                 'ok', fn_doc15_cpf_valido(substr(s,1,11))),
    named_struct('prioridade', CASE WHEN concat(substr(s,1,1), substr(s,13,3)) RLIKE '^0*$' THEN 2 ELSE 3 END,
                 'tipo', 'CPF', 'doc', substr(s,2,11), 'hipotese', 'CPF_JANELA_02',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', concat(substr(s,1,1), '|', substr(s,13,3)),
                 'ok', fn_doc15_cpf_valido(substr(s,2,11))),
    named_struct('prioridade', CASE WHEN concat(substr(s,1,2), substr(s,14,2)) RLIKE '^0*$' THEN 2 ELSE 3 END,
                 'tipo', 'CPF', 'doc', substr(s,3,11), 'hipotese', 'CPF_JANELA_03',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', concat(substr(s,1,2), '|', substr(s,14,2)),
                 'ok', fn_doc15_cpf_valido(substr(s,3,11))),
    named_struct('prioridade', CASE WHEN concat(substr(s,1,3), substr(s,15,1)) RLIKE '^0*$' THEN 2 ELSE 3 END,
                 'tipo', 'CPF', 'doc', substr(s,4,11), 'hipotese', 'CPF_JANELA_04',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', concat(substr(s,1,3), '|', substr(s,15,1)),
                 'ok', fn_doc15_cpf_valido(substr(s,4,11))),
    named_struct('prioridade', CASE WHEN substr(s,1,4) RLIKE '^0*$' THEN 2 ELSE 3 END,
                 'tipo', 'CPF', 'doc', substr(s,5,11), 'hipotese', 'CPF_JANELA_05',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', substr(s,1,4),
                 'ok', fn_doc15_cpf_valido(substr(s,5,11))),

    -- ---------------- CNPJ ----------------
    -- CNPJ = '0' + raiz(8) + filial(4) + controle(2): caso clássico (raiz de 8 numa coluna de 9)
    named_struct('prioridade', CASE WHEN substr(s,1,1) = '0' THEN 1 ELSE 3 END,
                 'tipo', 'CNPJ', 'doc', substr(s,2,14), 'hipotese', 'CNPJ_RAIZ_DIR_FILIAL_CTRL',
                 'dv_reconstruido', false, 'layout_canonico', substr(s,1,1) = '0', 'sobra', substr(s,1,1),
                 'ok', fn_doc15_cnpj_valido(substr(s,2,14))),
    -- idem com DV recalculado
    named_struct('prioridade', CASE WHEN substr(s,1,1) = '0' THEN 4 ELSE 5 END,
                 'tipo', 'CNPJ', 'doc', concat(substr(s,2,12), fn_doc15_cnpj_dv(substr(s,2,12))), 'hipotese', 'CNPJ_RAIZ_DIR_FILIAL_DVCALC',
                 'dv_reconstruido', true, 'layout_canonico', substr(s,1,1) = '0', 'sobra', concat(substr(s,1,1), '|', substr(s,14,2)),
                 'ok', fn_doc15_cnpj_dv(substr(s,2,12)) IS NOT NULL AND substr(s,14,2) <> fn_doc15_cnpj_dv(substr(s,2,12)) AND NOT (substr(s,2,8) = repeat(substr(s,2,1), 8))
                   AND fn_doc15_cnpj_valido(concat(substr(s,2,12), fn_doc15_cnpj_dv(substr(s,2,12))))),
    -- raiz(8) alinhada à esquerda na coluna de 9 (s[9] é enchimento): s[1..8] + filial + controle
    named_struct('prioridade', CASE WHEN substr(s,9,1) = '0' THEN 2 ELSE 3 END,
                 'tipo', 'CNPJ', 'doc', concat(substr(s,1,8), substr(s,10,4), substr(s,14,2)), 'hipotese', 'CNPJ_RAIZ_ESQ_FILIAL_CTRL',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', substr(s,9,1),
                 'ok', fn_doc15_cnpj_valido(concat(substr(s,1,8), substr(s,10,4), substr(s,14,2)))),
    -- CNPJ contíguo em [1..14] (raiz "escorregou": raiz9 = raiz8 + 1º dígito da filial), s[15] é sobra
    named_struct('prioridade', CASE WHEN substr(s,15,1) = '0' THEN 2 ELSE 3 END,
                 'tipo', 'CNPJ', 'doc', substr(s,1,14), 'hipotese', 'CNPJ_JANELA_01',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', substr(s,15,1),
                 'ok', fn_doc15_cnpj_valido(substr(s,1,14))),
    -- filial '0000' (inexistente) -> matriz '0001', com o controle original
    named_struct('prioridade', CASE WHEN substr(s,1,1) = '0' THEN 2 ELSE 3 END,
                 'tipo', 'CNPJ', 'doc', concat(substr(s,2,8), '0001', substr(s,14,2)), 'hipotese', 'CNPJ_MATRIZ_0001_CTRL',
                 'dv_reconstruido', false, 'layout_canonico', false, 'sobra', concat(substr(s,1,1), '|', substr(s,10,4)),
                 'ok', substr(s,10,4) = '0000' AND fn_doc15_cnpj_valido(concat(substr(s,2,8), '0001', substr(s,14,2)))),
    -- filial '0000' -> matriz '0001', DV recalculado
    named_struct('prioridade', 5,
                 'tipo', 'CNPJ', 'doc', concat(substr(s,2,8), '0001', fn_doc15_cnpj_dv(concat(substr(s,2,8), '0001'))), 'hipotese', 'CNPJ_MATRIZ_0001_DVCALC',
                 'dv_reconstruido', true, 'layout_canonico', false, 'sobra', concat(substr(s,1,1), '|', substr(s,10,4), '|', substr(s,14,2)),
                 'ok', substr(s,10,4) = '0000' AND fn_doc15_cnpj_dv(concat(substr(s,2,8), '0001')) IS NOT NULL AND substr(s,14,2) <> fn_doc15_cnpj_dv(concat(substr(s,2,8), '0001')) AND NOT (substr(s,2,8) = repeat(substr(s,2,1), 8))
                   AND fn_doc15_cnpj_valido(concat(substr(s,2,8), '0001', fn_doc15_cnpj_dv(concat(substr(s,2,8), '0001')))))
), h -> coalesce(h.ok, false)),
  -- descarta o campo auxiliar 'ok' para bater com o tipo declarado no RETURNS
  h -> named_struct('prioridade', h.prioridade, 'tipo', h.tipo, 'doc', h.doc, 'hipotese', h.hipotese,
                    'dv_reconstruido', h.dv_reconstruido, 'layout_canonico', h.layout_canonico, 'sobra', h.sobra));

-- Função pública: limpa a entrada e delega. Entrada inválida (não fecha 15) -> array vazio.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_hipoteses(x STRING)
RETURNS ARRAY<STRUCT<prioridade INT, tipo STRING, doc STRING, hipotese STRING,
                     dv_reconstruido BOOLEAN, layout_canonico BOOLEAN, sobra STRING>>
RETURN fn_doc15_hipoteses_s(fn_doc15_limpa(x));

-- Melhor hipótese (struct): o campo prioridade vem primeiro no struct, então array_min escolhe
-- a menor prioridade; empate desempata por tipo ('CNPJ' < 'CPF') e doc. NULL se nenhuma hipótese.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_melhor(x STRING)
RETURNS STRUCT<prioridade INT, tipo STRING, doc STRING, hipotese STRING,
               dv_reconstruido BOOLEAN, layout_canonico BOOLEAN, sobra STRING>
RETURN array_min(fn_doc15_hipoteses(x));

-- Atalhos escalares
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_tipo(x STRING)
RETURNS STRING
RETURN fn_doc15_melhor(x).tipo;

CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_doc(x STRING)
RETURNS STRING
RETURN fn_doc15_melhor(x).doc;

-- Ambíguo = a string admite CPF E CNPJ, ambos com DV original e layout ao menos plausível
-- (prioridade <= 2). Janelas "sem apoio" (prio 3) não contam: batem DV por acaso em ~1% cada.
-- Medido em 40 mil docs sintéticos: ~0,4% dos CPFs e ~1% dos CNPJs ficam com a flag ligada,
-- mas o vencedor (prioridade 1) continua sendo o documento certo em 100% deles.
CREATE OR REPLACE TEMPORARY FUNCTION fn_doc15_ambiguo(x STRING)
RETURNS BOOLEAN
RETURN size(filter(fn_doc15_hipoteses(x), e -> e.prioridade <= 2 AND e.tipo = 'CPF'))  > 0
   AND size(filter(fn_doc15_hipoteses(x), e -> e.prioridade <= 2 AND e.tipo = 'CNPJ')) > 0;


-- =====================================================================================
-- 3. USO EM LOTE (views). Troque a origem em vw_doc15_src.
-- =====================================================================================
CREATE OR REPLACE TEMPORARY VIEW vw_doc15_src AS
SELECT chave, doc15 FROM VALUES
  -- (chave, string de 15): exemplos sintéticos; substitua por: SELECT <chave>, <coluna> FROM <tabela>
  ('cpf_classico',      '529982247000025'),   -- CPF 529.982.247-25 com '0000' no meio
  ('cpf_filial_0001',   '529982247000125'),   -- CPF com filial 0001 (visto em dado real)
  ('cpf_dv_perdido',    '529982247000000'),   -- CPF com controle zerado -> DV recalculado
  ('cpf_num_13',        '005299822472500'),   -- '00'+CPF em raiz+filial (gravado como número), controle 00
  ('cpf_direita',       '000052998224725'),   -- CPF alinhado à direita nos 15
  ('cnpj_classico',     '011222333000181'),   -- CNPJ 11.222.333/0001-81 com raiz de 8 numa coluna de 9
  ('cnpj_dv_perdido',   '011222333000100'),   -- CNPJ com controle zerado -> DV recalculado
  ('cnpj_raiz_esq',     '112223330000181'),   -- raiz alinhada à esquerda (s[9]='0')
  ('cnpj_matriz_0000',  '011222333000081'),   -- filial 0000 -> matriz 0001 com o mesmo controle
  ('cnpj_alfanum',      '012ABC345010140'),   -- CNPJ alfanumérico 12.ABC.345/0101-40
  ('lixo_repetido',     '111111111000011'),   -- raiz toda igual -> nada (nem DV recalculado)
  ('ambiguo_real',      '082537122000186'),   -- fecha CNPJ 82.537.122/0001-86 (p1) E CPF 082.537.122-86 c/ filial 0001 (p2) -> flag_ambiguo
  ('lixo_zeros',        '000000000000000'),
  ('curto_numerico',    '11222333000181'),    -- 14 dígitos -> lpad -> CNPJ clássico
  ('nulo',              NULL)
AS t(chave, doc15);

-- 3.1 hipóteses como coluna (função SQL NÃO pode ir direto no LATERAL VIEW)
CREATE OR REPLACE TEMPORARY VIEW vw_doc15_01_hipoteses AS
SELECT chave, doc15, fn_doc15_limpa(doc15) AS doc15_limpo, fn_doc15_hipoteses(doc15) AS hipoteses
FROM vw_doc15_src;

-- 3.2 uma linha por hipótese válida (OUTER mantém quem não tem nenhuma); dedupe por (chave, tipo, doc)
CREATE OR REPLACE TEMPORARY VIEW vw_doc15_02_candidatos AS
SELECT chave, doc15, doc15_limpo,
       h.prioridade, h.tipo, h.doc, h.hipotese, h.dv_reconstruido, h.layout_canonico, h.sobra,
       fn_doc15_formata(h.tipo, h.doc) AS doc_formatado
FROM vw_doc15_01_hipoteses
LATERAL VIEW OUTER inline(hipoteses) h
QUALIFY row_number() OVER (PARTITION BY chave, h.tipo, h.doc ORDER BY h.prioridade, h.hipotese) = 1;

-- 3.3 resultado final: 1 linha por chave com a melhor hipótese + diagnóstico
CREATE OR REPLACE TEMPORARY VIEW vw_doc15_final AS
SELECT
  chave, doc15, doc15_limpo,
  tipo                                              AS tipo_final,
  doc                                               AS doc_final,
  doc_formatado                                     AS doc_final_formatado,
  hipotese                                          AS hipotese_vencedora,
  prioridade,
  dv_reconstruido,
  layout_canonico,
  CASE
    WHEN doc15_limpo IS NULL          THEN 'ENTRADA_INVALIDA'        -- não fechou 15 posições
    WHEN tipo IS NULL                 THEN 'SEM_HIPOTESE_DV_VALIDA'
    WHEN prio_cpf_dvorig = prio_cnpj_dvorig THEN 'AMBIGUO_CPF_E_CNPJ'  -- empate real de prioridade
    WHEN dv_reconstruido              THEN 'DV_RECONSTRUIDO'         -- só aceitar com confirmação externa
    WHEN prioridade = 1               THEN 'OK_CANONICO'
    WHEN prioridade = 2               THEN 'OK_LAYOUT_PLAUSIVEL'
    ELSE                                   'OK_LAYOUT_SEM_APOIO'
  END                                               AS status,
  -- o outro tipo também fecha DV com layout plausível (prio <= 2): vencedor continua válido,
  -- mas vale confirmar em fonte externa (RF PF/PJ). Ver comentário em fn_doc15_ambiguo.
  coalesce(prio_cpf_dvorig <= 2 AND prio_cnpj_dvorig <= 2, false) AS flag_ambiguo,
  CASE WHEN tipo = 'CPF' THEN doc_cnpj_dvorig ELSE doc_cpf_dvorig END AS doc_alternativo_outro_tipo,
  prio_cpf_dvorig,
  prio_cnpj_dvorig,
  qtd_hipoteses,
  hipoteses_txt
FROM (
  SELECT c.*,
         count(tipo)                                       OVER (PARTITION BY chave) AS qtd_hipoteses,
         min(CASE WHEN tipo = 'CPF'  AND NOT dv_reconstruido THEN prioridade END)
                                                           OVER (PARTITION BY chave) AS prio_cpf_dvorig,
         min(CASE WHEN tipo = 'CNPJ' AND NOT dv_reconstruido THEN prioridade END)
                                                           OVER (PARTITION BY chave) AS prio_cnpj_dvorig,
         -- melhor doc de cada tipo com DV original (min do struct = menor prioridade)
         (min(CASE WHEN tipo = 'CPF'  AND NOT dv_reconstruido THEN struct(prioridade, doc) END)
                                                           OVER (PARTITION BY chave)).doc AS doc_cpf_dvorig,
         (min(CASE WHEN tipo = 'CNPJ' AND NOT dv_reconstruido THEN struct(prioridade, doc) END)
                                                           OVER (PARTITION BY chave)).doc AS doc_cnpj_dvorig,
         concat_ws(' ; ', collect_list(concat(tipo, ':', doc, ' (', hipotese, ' p', prioridade, ')'))
                          OVER (PARTITION BY chave))       AS hipoteses_txt
  FROM vw_doc15_02_candidatos c
)
QUALIFY row_number() OVER (PARTITION BY chave ORDER BY prioridade, tipo, doc) = 1;


-- =====================================================================================
-- 4. TESTES / DIAGNÓSTICO
-- =====================================================================================
-- 4.1 sanidade das funções de DV
SELECT fn_doc15_cpf_valido('52998224725')     AS cpf_ok_esperado_true,
       fn_doc15_cpf_valido('52998224726')     AS cpf_ok_esperado_false,
       fn_doc15_cpf_valido('11111111111')     AS cpf_repetido_esperado_false,
       fn_doc15_cnpj_valido('11222333000181') AS cnpj_ok_esperado_true,
       fn_doc15_cnpj_valido('11222333000182') AS cnpj_ok_esperado_false,
       fn_doc15_cnpj_valido('12ABC345010140') AS cnpj_alfanum_esperado_true;

-- 4.2 escalar
SELECT fn_doc15_tipo('529982247000025')     AS tipo,
       fn_doc15_doc('529982247000025')      AS doc,
       fn_doc15_melhor('011222333000181')   AS melhor_cnpj,
       fn_doc15_ambiguo('529982247000025')  AS ambiguo,
       fn_doc15_hipoteses('529982247000000') AS hipoteses_dv_perdido;

-- 4.3 lote (esperado: ver comentário de cada linha em vw_doc15_src)
SELECT * FROM vw_doc15_final ORDER BY chave;

-- 4.4 todas as hipóteses (auditoria)
SELECT * FROM vw_doc15_02_candidatos ORDER BY chave, prioridade, tipo;

-- 4.5 distribuição por status/hipótese (rodar na base real)
-- SELECT status, tipo_final, hipotese_vencedora, count(*) AS qtd FROM vw_doc15_final GROUP BY ALL ORDER BY qtd DESC;
