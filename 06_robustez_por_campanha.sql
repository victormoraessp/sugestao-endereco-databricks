/* =============================================================================
   VALUATION TELEFONE  |  06_robustez_por_campanha.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   Testes de ROBUSTEZ: mostra que o efeito medido no script 03 não depende de
   uma campanha gigante, de uma regra de comparação nem de um tipo de cliente.
     6.1 tabela por campanha (com mínimo por braço) e p-valor de cada uma
     6.2 teste do sinal: em quantas campanhas o GR ganhou?
     6.3 efeito por faixa de volume de campanha
     6.4 efeito excluindo a maior campanha
     6.5 efeito com a regra EXATA de concordância (sem tolerância de formato)
     6.6 efeito por frequência de contato do CPF (proxy de engajamento)

   POR QUE ISSO IMPORTA
   --------------------
   O ataque mais comum a uma inferência observacional é "isso é só uma
   campanha atípica" ou "isso é só clientes engajados". Se o efeito aparece
   na mesma direção em quase todas as campanhas, faixas e regras, o ataque
   perde força. O teste do sinal (6.2) é elegante porque não depende de
   nenhuma suposição sobre distribuição: só conta vitórias e derrotas.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   6.1 é a "tabela de placar": campanha a campanha, o telefone do
              GR entregou mais ou menos? 6.2 conta em quantas campanhas ele
              ganhou. 6.3 a 6.6 repetem a comparação em recortes diferentes.
   [SÊNIOR]   6.2 é um teste binomial (aprox. Normal) sobre o sinal da
              diferença por campanha, restrito a campanhas com n >= mínimo
              em ambos os braços para evitar ruído. 6.3 e 6.6 são
              estratificações alternativas; se os efeitos dentro de cada
              estrato são consistentes com o CMH global, não há modificação
              de efeito relevante.
   [EXECUTIVO] A pergunta é uma só: "o resultado se repete em todo lugar?"
              Se a coluna PCT_CAMPANHAS_GR_VENCEU (6.2) for alta e os
              recortes 6.3-6.6 tiverem o mesmo sinal, a resposta é sim.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   6.1  TABELA POR CAMPANHA (mínimo de envios por braço = vt_parametros)
   -----------------------------------------------------------------------------
   Campanhas menores que o mínimo continuam no CMH do script 03; aqui elas
   saem apenas porque o p-valor individual seria ruído.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_por_campanha AS
WITH s AS (
  SELECT
    e.campanha, e.a, e.b, e.c, e.d,
    e.a + e.b AS n1, e.c + e.d AS n0
  FROM vt_estratos_campanha e
  CROSS JOIN vt_parametros p
  WHERE e.a + e.b >= p.min_envios_por_braco_campanha
    AND e.c + e.d >= p.min_envios_por_braco_campanha
),
calc AS (
  SELECT
    *,
    a / n1                          AS p1,
    c / n0                          AS p0,
    (a + c) / (n1 + n0)             AS p_pool
  FROM s
),
z AS (
  SELECT
    *,
    CASE WHEN p_pool IN (0, 1) THEN NULL
         ELSE (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) END AS z_score
  FROM calc
)
SELECT
  z.campanha,
  v.faixa_volume,
  CAST(n1 AS BIGINT)                            AS envios_concordante,
  round(100.0 * p1, 4)                          AS taxa_concordante_pct,
  round(100.0 * wilson_inf(a, n1), 4)           AS ic95_inf_conc_pct,
  round(100.0 * wilson_sup(a, n1), 4)           AS ic95_sup_conc_pct,
  CAST(n0 AS BIGINT)                            AS envios_discordante,
  round(100.0 * p0, 4)                          AS taxa_discordante_pct,
  round(100.0 * wilson_inf(c, n0), 4)           AS ic95_inf_disc_pct,
  round(100.0 * wilson_sup(c, n0), 4)           AS ic95_sup_disc_pct,
  round(100.0 * (p1 - p0), 4)                   AS diferenca_pp,
  round(z_score, 3)                             AS z,
  p_valor_bilateral(z_score)                    AS p_valor,
  CASE WHEN p1 > p0 THEN 'GR_VENCEU' WHEN p1 < p0 THEN 'GR_PERDEU' ELSE 'EMPATE' END AS sinal,
  CASE WHEN p_valor_bilateral(z_score) < 0.05 THEN 'SIGNIFICANTE' ELSE 'NAO_SIGNIFICANTE' END AS significancia
FROM z
JOIN vt_campanha_volume v ON z.campanha = v.campanha
ORDER BY n1 + n0 DESC
;
SELECT * FROM vt_res_06_por_campanha;


/* -----------------------------------------------------------------------------
   6.2  TESTE DO SINAL: em quantas campanhas o GR venceu?
   -----------------------------------------------------------------------------
   H0: o GR vence em 50% das campanhas (moeda honesta).
   z = (vitórias - n/2) / sqrt(n/4), sobre campanhas sem empate.
   Não depende de tamanho de campanha: cada campanha vale 1 voto. Por isso
   complementa o CMH (que pesa pelo volume).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_teste_sinal AS
WITH t AS (
  SELECT
    count(*)                                                    AS campanhas_avaliadas,
    sum(CASE WHEN sinal = 'GR_VENCEU' THEN 1 ELSE 0 END)        AS gr_venceu,
    sum(CASE WHEN sinal = 'GR_PERDEU' THEN 1 ELSE 0 END)        AS gr_perdeu,
    sum(CASE WHEN sinal = 'EMPATE'    THEN 1 ELSE 0 END)        AS empates,
    sum(CASE WHEN sinal = 'GR_VENCEU' AND significancia = 'SIGNIFICANTE' THEN 1 ELSE 0 END) AS gr_venceu_significante,
    sum(CASE WHEN sinal = 'GR_PERDEU' AND significancia = 'SIGNIFICANTE' THEN 1 ELSE 0 END) AS gr_perdeu_significante
  FROM vt_res_06_por_campanha
),
z AS (
  SELECT
    *,
    gr_venceu + gr_perdeu AS n_sem_empate,
    CASE WHEN gr_venceu + gr_perdeu > 0
         THEN (gr_venceu - (gr_venceu + gr_perdeu) / 2.0) / sqrt((gr_venceu + gr_perdeu) / 4.0) END AS z_score
  FROM t
)
SELECT
  campanhas_avaliadas,
  gr_venceu,
  gr_perdeu,
  empates,
  round(100.0 * gr_venceu / nullif(n_sem_empate, 0), 4)   AS pct_campanhas_gr_venceu,
  gr_venceu_significante,
  gr_perdeu_significante,
  round(z_score, 3)                                        AS z,
  p_valor_bilateral(z_score)                               AS p_valor,
  CASE
    WHEN p_valor_bilateral(z_score) < 0.05 AND gr_venceu > gr_perdeu
      THEN 'O GR vence na maioria das campanhas, além do acaso (p<0,05). Efeito generalizado.'
    WHEN p_valor_bilateral(z_score) < 0.05
      THEN 'O GR perde na maioria das campanhas (p<0,05).'
    ELSE 'Vitórias e derrotas equilibradas entre campanhas.'
  END                                                      AS leitura
FROM z
;
SELECT * FROM vt_res_06_teste_sinal;


/* -----------------------------------------------------------------------------
   6.3  EFEITO POR FAIXA DE VOLUME DE CAMPANHA
   -----------------------------------------------------------------------------
   Pergunta: o efeito é o mesmo nas campanhas pequenas, médias e gigantes?
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_por_faixa_volume AS
WITH agg AS (
  SELECT
    v.faixa_volume,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END) AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END) AS k0
  FROM vt_experimento e
  JOIN vt_campanha_volume v ON e.campanha = v.campanha
  GROUP BY v.faixa_volume
),
calc AS (
  SELECT *, k1 / nullif(n1, 0) AS p1, k0 / nullif(n0, 0) AS p0, (k1 + k0) / (n1 + n0) AS p_pool FROM agg
),
z AS (
  SELECT *,
    CASE WHEN n1 > 0 AND n0 > 0 AND p_pool NOT IN (0, 1)
         THEN (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) END AS z_score
  FROM calc
)
SELECT
  faixa_volume,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  round(z_score, 3) AS z,
  p_valor_bilateral(z_score) AS p_valor
FROM z
ORDER BY faixa_volume
;
SELECT * FROM vt_res_06_por_faixa_volume;


/* -----------------------------------------------------------------------------
   6.4  EFEITO EXCLUINDO A MAIOR CAMPANHA
   -----------------------------------------------------------------------------
   Pergunta: se tirarmos a campanha que mais pesa, o resultado se mantém?
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_sem_maior_campanha AS
WITH maior AS (
  SELECT campanha FROM vt_campanha_volume ORDER BY n_envios DESC LIMIT 1
),
agg AS (
  SELECT
    max(m.campanha)                                            AS campanha_excluida,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END) AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END) AS k0
  FROM vt_experimento e
  CROSS JOIN maior m
  WHERE e.campanha <> m.campanha
),
calc AS (
  SELECT *, k1 / nullif(n1, 0) AS p1, k0 / nullif(n0, 0) AS p0, (k1 + k0) / (n1 + n0) AS p_pool FROM agg
),
z AS (
  SELECT *, (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) AS z_score FROM calc
)
SELECT
  campanha_excluida,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  round(z_score, 3) AS z,
  p_valor_bilateral(z_score) AS p_valor
FROM z
;
SELECT * FROM vt_res_06_sem_maior_campanha;


/* -----------------------------------------------------------------------------
   6.5  REGRA EXATA DE CONCORDÂNCIA (sem tolerância de formato)
   -----------------------------------------------------------------------------
   Pergunta: se só contarmos como "telefone do GR" a string idêntica
   (ddi+ddd+número), o efeito muda? Se IGUAL_TOLERANTE for grande e o efeito
   mudar muito, a regra de comparação está influenciando a conclusão.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_regra_exata AS
WITH agg AS (
  SELECT
    sum(CASE WHEN concordante_exato = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN concordante_exato = 1 THEN entregue ELSE 0 END)  AS k1,
    sum(CASE WHEN concordante_exato = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN concordante_exato = 0 THEN entregue ELSE 0 END)  AS k0
  FROM vt_experimento
),
calc AS (
  SELECT *, k1 / nullif(n1, 0) AS p1, k0 / nullif(n0, 0) AS p0, (k1 + k0) / (n1 + n0) AS p_pool FROM agg
),
z AS (
  SELECT *, (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) AS z_score FROM calc
)
SELECT
  'EXATA' AS regra,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  round(z_score, 3) AS z,
  p_valor_bilateral(z_score) AS p_valor
FROM z
UNION ALL
SELECT
  'TOLERANTE (principal)' AS regra,
  envios_concordante, taxa_concordante_pct,
  envios_discordante, taxa_discordante_pct,
  diferenca_pp, z, p_valor
FROM vt_res_03_bruto
;
SELECT * FROM vt_res_06_regra_exata;


/* -----------------------------------------------------------------------------
   6.6  EFEITO POR FREQUÊNCIA DE CONTATO DO CPF (proxy de engajamento)
   -----------------------------------------------------------------------------
   Pergunta: clientes muito contatados (provavelmente ativos) e pouco
   contatados mostram o mesmo efeito? Ataca o argumento "o GR só coincide
   com o CRM em clientes bons".
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_por_frequencia_cpf AS
WITH freq AS (
  SELECT cpf, count(*) AS n_envios_cpf FROM vt_experimento GROUP BY cpf
),
agg AS (
  SELECT
    CASE WHEN f.n_envios_cpf = 1 THEN '1. 1 envio'
         WHEN f.n_envios_cpf <= 3 THEN '2. 2 a 3 envios'
         WHEN f.n_envios_cpf <= 10 THEN '3. 4 a 10 envios'
         ELSE '4. > 10 envios' END                                 AS faixa_frequencia,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)             AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END)    AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)             AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END)    AS k0
  FROM vt_experimento e
  JOIN freq f ON e.cpf = f.cpf
  GROUP BY 1
),
calc AS (
  SELECT *, k1 / nullif(n1, 0) AS p1, k0 / nullif(n0, 0) AS p0, (k1 + k0) / (n1 + n0) AS p_pool FROM agg
),
z AS (
  SELECT *,
    CASE WHEN n1 > 0 AND n0 > 0 AND p_pool NOT IN (0, 1)
         THEN (p1 - p0) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) END AS z_score
  FROM calc
)
SELECT
  faixa_frequencia,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  round(z_score, 3) AS z,
  p_valor_bilateral(z_score) AS p_valor
FROM z
ORDER BY faixa_frequencia
;
SELECT * FROM vt_res_06_por_frequencia_cpf;
