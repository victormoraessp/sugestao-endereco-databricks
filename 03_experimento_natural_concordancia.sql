/* =============================================================================
   VALUATION TELEFONE  |  03_experimento_natural_concordancia.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   LENTE 1 (a principal): compara a taxa de entrega de SMS quando o CRM, por
   coincidência, usou o telefone do Golden Record (braço CONCORDANTE) contra
   quando usou outro telefone (braço DISCORDANTE).
     3.1 comparação bruta (2 proporções, teste z, IC 95%, odds ratio)
     3.2 comparação ESTRATIFICADA POR CAMPANHA (Cochran-Mantel-Haenszel)
     3.3 diagnóstico dos estratos usados

   POR QUE ISSO É UM EXPERIMENTO (E NÃO SÓ UMA CORRELAÇÃO)
   --------------------------------------------------------
   O GR foi construído sem olhar para as origens do CRM nem para o resultado
   dos disparos. Logo não há "vazamento": o GR não "sabe" quais SMS
   entregaram. A concordância acontece por coincidência de fontes. Isso
   aproxima um experimento natural, com uma ressalva honesta: clientes cujos
   telefones coincidem entre fontes podem ser clientes com cadastro "mais
   saudável". Para atacar isso:
     - 3.2 controla por CAMPANHA (mesmo período, mesma mensagem, mesmo
       segmento de público);
     - o script 04 controla por PESSOA (mesmo CPF, telefones diferentes);
     - o script 06 controla por tamanho de campanha, regra de comparação e
       frequência de contato.
   Se as três lentes apontarem na mesma direção, a conclusão é robusta.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   3.1: duas taxas de entrega (com o telefone do GR / sem) e um
              p-valor. Se p < 0,05 a diferença não é acaso. 3.2: a mesma
              comparação, mas feita DENTRO de cada campanha e depois somada
              (cada campanha pesa pelo seu tamanho). É o número "defensável".
   [SÊNIOR]   3.2 usa CMH: qui-quadrado de Mantel-Haenszel (sem correção de
              continuidade), OR_MH e IC 95% pela variância de
              Robins-Breslow-Greenland, além da diferença de risco ponderada
              MH (pesos n1k*n0k/nk). Estratos com um só braço não contribuem.
              Campanhas de 10-100 envios entram normalmente: o CMH é
              justamente o método para muitos estratos pequenos.
   [EXECUTIVO] O número que importa é DIFERENCA_PP_MH (pontos percentuais de
              entrega a mais quando o telefone é o do GR) e o P_VALOR ao
              lado. Se for positivo e p < 0,05, usar o GR aumenta entrega de
              forma estatisticamente comprovada, controlando por campanha.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   3.1  COMPARAÇÃO BRUTA: CONCORDANTE  x  DISCORDANTE
   -----------------------------------------------------------------------------
   n1,k1 = envios e entregas no braço concordante (telefone = GR)
   n0,k0 = envios e entregas no braço discordante (telefone ≠ GR)
   Teste z de duas proporções (variância pooled) e IC 95% da diferença
   (variância não-pooled). Odds ratio bruta como referência para o CMH.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_bruto AS
WITH agg AS (
  SELECT
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)  AS k1,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN concordante = 0 THEN entregue ELSE 0 END)  AS k0
  FROM vt_experimento
),
calc AS (
  SELECT
    *,
    k1 / nullif(n1, 0)                    AS p1,
    k0 / nullif(n0, 0)                    AS p0,
    (k1 + k0) / (n1 + n0)      AS p_pool
  FROM agg
),
z AS (
  SELECT
    *,
    (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))   AS z_score,
    sqrt(p1 * (1 - p1) / n1 + p0 * (1 - p0) / n0)                     AS se_diff
  FROM calc
)
SELECT
  n1                                            AS envios_concordante,
  k1                                            AS entregues_concordante,
  round(100.0 * p1, 4)                          AS taxa_concordante_pct,
  round(100.0 * wilson_inf(k1, n1), 4)          AS ic95_inf_concordante_pct,
  round(100.0 * wilson_sup(k1, n1), 4)          AS ic95_sup_concordante_pct,
  n0                                            AS envios_discordante,
  k0                                            AS entregues_discordante,
  round(100.0 * p0, 4)                          AS taxa_discordante_pct,
  round(100.0 * wilson_inf(k0, n0), 4)          AS ic95_inf_discordante_pct,
  round(100.0 * wilson_sup(k0, n0), 4)          AS ic95_sup_discordante_pct,
  round(100.0 * (p1 - p0), 4)                   AS diferenca_pp,
  round(100.0 * (p1 - p0 - 1.959964 * se_diff), 4) AS diferenca_ic95_inf_pp,
  round(100.0 * (p1 - p0 + 1.959964 * se_diff), 4) AS diferenca_ic95_sup_pp,
  round(100.0 * (p1 - p0) / p0, 4)              AS lift_relativo_pct,
  round((k1 / nullif(n1 - k1, 0)) / nullif(k0 / nullif(n0 - k0, 0), 0), 4) AS odds_ratio_bruta,
  round(z_score, 3)                             AS z,
  p_valor_bilateral(z_score)                    AS p_valor,
  CASE WHEN p_valor_bilateral(z_score) < 0.05 AND p1 > p0
         THEN 'Telefone do GR entrega MAIS; diferença estatisticamente significante (p<0,05).'
       WHEN p_valor_bilateral(z_score) < 0.05 AND p1 < p0
         THEN 'Telefone do GR entrega MENOS; diferença significante. Investigar antes de usar.'
       ELSE 'Sem diferença estatisticamente detectável.'
  END                                           AS leitura
FROM z
;
SELECT * FROM vt_res_03_bruto;


/* -----------------------------------------------------------------------------
   3.2a ESTRATOS POR CAMPANHA (tabela 2x2 de cada campanha)
   -----------------------------------------------------------------------------
   a = concordante & entregue      b = concordante & não entregue
   c = discordante & entregue      d = discordante & não entregue
   Tudo em DOUBLE para evitar overflow em n^3 nas campanhas de 10M+.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_estratos_campanha AS
SELECT
  campanha,
  CAST(sum(CASE WHEN concordante = 1 AND entregue = 1 THEN 1 ELSE 0 END) AS DOUBLE) AS a,
  CAST(sum(CASE WHEN concordante = 1 AND entregue = 0 THEN 1 ELSE 0 END) AS DOUBLE) AS b,
  CAST(sum(CASE WHEN concordante = 0 AND entregue = 1 THEN 1 ELSE 0 END) AS DOUBLE) AS c,
  CAST(sum(CASE WHEN concordante = 0 AND entregue = 0 THEN 1 ELSE 0 END) AS DOUBLE) AS d
FROM vt_experimento
GROUP BY campanha
;


/* -----------------------------------------------------------------------------
   3.2b COCHRAN-MANTEL-HAENSZEL  (efeito do GR controlado por campanha)
   -----------------------------------------------------------------------------
   Por estrato k:
     n1 = a+b (concordantes)  n0 = c+d (discordantes)
     m1 = a+c (entregues)     m0 = b+d (não entregues)   n = total
     E[a]   = n1*m1/n
     Var[a] = n1*n0*m1*m0 / (n^2 (n-1))
     R = a*d/n   S = b*c/n   P = (a+d)/n   Q = (b+c)/n
   Agregados:
     χ²_CMH   = (Σa - ΣE[a])² / ΣVar[a]           ~ χ²(1 gl)
     OR_MH    = ΣR / ΣS
     Var(ln OR_MH) = ΣPR/(2ΣR²) + Σ(PS+QR)/(2ΣRΣS) + ΣQS/(2ΣS²)   (RBG)
     RD_MH    = Σ w_k (p1k - p0k) / Σ w_k,  w_k = n1k*n0k/nk
   Estratos com um braço vazio ou n < min_n_estrato_cmh não contribuem
   (não têm informação sobre a diferença).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_cmh AS
WITH s AS (
  SELECT
    e.*,
    a + b           AS n1,
    c + d           AS n0,
    a + c           AS m1,
    b + d           AS m0,
    a + b + c + d   AS n
  FROM vt_estratos_campanha e
  CROSS JOIN vt_parametros p
  WHERE a + b > 0 AND c + d > 0 AND a + b + c + d >= p.min_n_estrato_cmh
),
t AS (
  SELECT
    *,
    n1 * m1 / n                                   AS e_a,
    n1 * n0 * m1 * m0 / (n * n * (n - 1))         AS v_a,
    a * d / n                                     AS r_k,
    b * c / n                                     AS s_k,
    (a + d) / n                                   AS p_k,
    (b + c) / n                                   AS q_k,
    n1 * n0 / n                                   AS w_rd,
    (a / n1) - (c / n0)                           AS rd_k
  FROM s
),
agg AS (
  SELECT
    count(*)                             AS n_estratos,
    sum(n)                               AS n_envios,
    sum(a)                               AS soma_a,
    sum(e_a)                             AS soma_e_a,
    sum(v_a)                             AS soma_v_a,
    sum(r_k)                             AS soma_r,
    sum(s_k)                             AS soma_s,
    sum(p_k * r_k)                       AS soma_pr,
    sum(p_k * s_k + q_k * r_k)           AS soma_ps_qr,
    sum(q_k * s_k)                       AS soma_qs,
    sum(w_rd * rd_k) / sum(w_rd)         AS rd_mh
  FROM t
),
calc AS (
  SELECT
    *,
    soma_r / soma_s                                          AS or_mh,
    power(soma_a - soma_e_a, 2) / soma_v_a                   AS chi2_cmh,
    soma_pr / (2 * soma_r * soma_r)
      + soma_ps_qr / (2 * soma_r * soma_s)
      + soma_qs / (2 * soma_s * soma_s)                      AS var_ln_or
  FROM agg
)
SELECT
  n_estratos                                                    AS campanhas_no_teste,
  CAST(n_envios AS BIGINT)                                      AS envios_no_teste,
  round(100.0 * rd_mh, 4)                                       AS diferenca_pp_mh,
  round(or_mh, 4)                                               AS odds_ratio_mh,
  round(exp(ln(or_mh) - 1.959964 * sqrt(var_ln_or)), 4)         AS odds_ratio_ic95_inf,
  round(exp(ln(or_mh) + 1.959964 * sqrt(var_ln_or)), 4)         AS odds_ratio_ic95_sup,
  round(chi2_cmh, 3)                                            AS qui2_cmh,
  p_valor_qui2_1gl(chi2_cmh)                                    AS p_valor,
  CASE
    WHEN p_valor_qui2_1gl(chi2_cmh) < 0.05 AND or_mh > 1
      THEN 'Controlando por campanha, o telefone do GR entrega MAIS (p<0,05). Resultado defensável.'
    WHEN p_valor_qui2_1gl(chi2_cmh) < 0.05 AND or_mh < 1
      THEN 'Controlando por campanha, o telefone do GR entrega MENOS (p<0,05). Não usar sem investigar.'
    ELSE 'Controlando por campanha não há diferença detectável.'
  END                                                           AS leitura
FROM calc
;
SELECT * FROM vt_res_03_cmh;


/* -----------------------------------------------------------------------------
   3.3  DIAGNÓSTICO DOS ESTRATOS
   -----------------------------------------------------------------------------
   Pergunta: quantas campanhas entraram no CMH e quanto volume elas cobrem?
   Campanhas fora do teste têm apenas um braço (ex.: 100% concordante) e
   por definição não informam sobre a diferença.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_estratos_diag AS
SELECT
  CASE WHEN a + b > 0 AND c + d > 0 THEN 'COM_AMBOS_BRACOS (entra no CMH)'
       WHEN a + b > 0                THEN 'SO_CONCORDANTE (fora do CMH)'
       ELSE                               'SO_DISCORDANTE (fora do CMH)' END AS situacao,
  count(*)                                              AS n_campanhas,
  CAST(sum(a + b + c + d) AS BIGINT)                    AS n_envios,
  round(100.0 * sum(a + b + c + d) / sum(sum(a + b + c + d)) OVER (), 4) AS pct_envios
FROM vt_estratos_campanha
GROUP BY 1
ORDER BY n_envios DESC
;
SELECT * FROM vt_res_03_estratos_diag;


/* -----------------------------------------------------------------------------
   3.4  TAXA CONCORDANTE POR CAMPANHA (insumo de calibração do script 05)
   -----------------------------------------------------------------------------
   p1_k = taxa de entrega do telefone do GR dentro da campanha k.
   Quando a campanha não tem braço concordante, o script 05 usa a taxa global.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_taxa_concordante_campanha AS
SELECT
  campanha,
  a + b                                          AS n_concordante,
  CASE WHEN a + b > 0 THEN a / (a + b) END       AS taxa_concordante_k,
  c + d                                          AS n_discordante,
  CASE WHEN c + d > 0 THEN c / (c + d) END       AS taxa_discordante_k
FROM vt_estratos_campanha
;
