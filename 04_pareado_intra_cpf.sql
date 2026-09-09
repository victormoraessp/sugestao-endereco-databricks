/* =============================================================================
   VALUATION TELEFONE  |  04_pareado_intra_cpf.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   LENTE 2: compara o MESMO CLIENTE consigo mesmo. Há CPFs que o CRM
   contatou em campanhas diferentes usando, em uma delas, o telefone do GR
   e, em outra, um telefone diferente. Para esses CPFs perguntamos: o SMS
   chegou quando foi para o telefone do GR e não chegou quando foi para o
   outro (ou vice-versa)?
     4.1 universo pareado (quantos CPFs têm os dois braços)
     4.2 McNemar em 1 envio por braço por CPF (sorteio determinístico)
     4.3 diferença média das taxas por CPF (usa todos os envios)
     4.4 versão estrita: mesmo CPF, MESMA campanha, telefones diferentes

   POR QUE ESSA LENTE É FORTE
   --------------------------
   Toda característica fixa da pessoa (perfil, região, engajamento, idade do
   cadastro) é a mesma nos dois braços, porque é a mesma pessoa. O que sobra
   como explicação da diferença é o telefone. O custo é que o universo é
   menor (só quem foi contatado nos dois braços) e a campanha pode diferir
   entre os braços; a versão 4.4 fecha até isso, ao preço de ainda menos
   volume.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   Pegamos clientes que receberam SMS nos dois telefones. Contamos
              em quantos "só o telefone do GR chegou" (b) e em quantos "só o
              outro telefone chegou" (c). Se b for bem maior que c, o GR é
              melhor. O teste de McNemar diz se b e c são diferentes além
              do acaso.
   [SÊNIOR]   McNemar χ² = (b-c)²/(b+c), 1 gl. Para não deixar a exposição
              desbalanceada (CPF com 10 envios discordantes e 1 concordante),
              4.2 sorteia 1 envio por braço via xxhash64 (reprodutível). 4.3
              usa todos os envios com diferença média pareada e z = média /
              (dp/√n); com n grande a Normal é adequada. Confundimento por
              campanha permanece em 4.2/4.3 e é eliminado em 4.4.
   [EXECUTIVO] "Para o mesmo cliente, o telefone do GR chega X p.p. mais
              vezes que o telefone que o CRM usou". É a evidência mais
              intuitiva para quem não quer discutir estatística.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   4.1  UNIVERSO PAREADO: CPFs com pelo menos 1 envio em cada braço
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_pareado_cpf AS
WITH por_cpf AS (
  SELECT
    cpf,
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)       AS n_conc,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)       AS n_disc,
    avg(CASE WHEN concordante = 1 THEN entregue END)       AS taxa_conc,
    avg(CASE WHEN concordante = 0 THEN entregue END)       AS taxa_disc
  FROM vt_experimento
  GROUP BY cpf
)
SELECT *
FROM por_cpf
WHERE n_conc > 0 AND n_disc > 0
;

CREATE OR REPLACE TEMP VIEW vt_res_04_universo AS
SELECT
  count(*)                                        AS cpfs_pareados,
  CAST(sum(n_conc) AS BIGINT)                     AS envios_concordantes,
  CAST(sum(n_disc) AS BIGINT)                     AS envios_discordantes,
  round(avg(n_conc), 2)                           AS media_envios_conc_por_cpf,
  round(avg(n_disc), 2)                           AS media_envios_disc_por_cpf,
  (SELECT count(DISTINCT cpf) FROM vt_experimento) AS cpfs_no_experimento,
  round(100.0 * count(*) / (SELECT count(DISTINCT cpf) FROM vt_experimento), 4)
                                                  AS pct_cpfs_pareados
FROM vt_pareado_cpf
;
SELECT * FROM vt_res_04_universo;


/* -----------------------------------------------------------------------------
   4.2  McNEMAR: 1 envio por braço por CPF
   -----------------------------------------------------------------------------
   Sorteio determinístico: ordena por xxhash64(cpf, campanha, telefone) e
   pega o primeiro de cada braço. Reprodutível entre execuções.
   Tabela pareada:
     b = GR entregou & outro não entregou   (a favor do GR)
     c = GR não entregou & outro entregou   (contra o GR)
     concordantes (ambos entregaram / nenhum) não informam.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_pareado_1por_braco AS
WITH um_por_braco AS (
  SELECT
    e.cpf, e.concordante, e.entregue
  FROM vt_experimento e
  JOIN vt_pareado_cpf p ON e.cpf = p.cpf
  QUALIFY row_number() OVER (
    PARTITION BY e.cpf, e.concordante
    ORDER BY xxhash64(e.cpf, e.campanha, e.telefone_crm)
  ) = 1
)
SELECT
  cpf,
  max(CASE WHEN concordante = 1 THEN entregue END) AS entregue_gr,
  max(CASE WHEN concordante = 0 THEN entregue END) AS entregue_outro
FROM um_por_braco
GROUP BY cpf
;

CREATE OR REPLACE TEMP VIEW vt_res_04_mcnemar AS
WITH tab AS (
  SELECT
    count(*)                                                              AS n_pares,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS ambos_entregaram,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS b_so_gr_entregou,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS c_so_outro_entregou,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS nenhum_entregou,
    avg(entregue_gr)                                                      AS taxa_gr,
    avg(entregue_outro)                                                   AS taxa_outro
  FROM vt_pareado_1por_braco
),
calc AS (
  SELECT
    *,
    CASE WHEN b_so_gr_entregou + c_so_outro_entregou > 0
         THEN power(b_so_gr_entregou - c_so_outro_entregou, 2)
              / (b_so_gr_entregou + c_so_outro_entregou) END              AS chi2_mcnemar
  FROM tab
)
SELECT
  n_pares,
  ambos_entregaram,
  b_so_gr_entregou,
  c_so_outro_entregou,
  nenhum_entregou,
  round(100.0 * taxa_gr, 4)                              AS taxa_entrega_telefone_gr_pct,
  round(100.0 * taxa_outro, 4)                           AS taxa_entrega_telefone_outro_pct,
  round(100.0 * (taxa_gr - taxa_outro), 4)               AS diferenca_pp,
  round(b_so_gr_entregou / nullif(c_so_outro_entregou, 0), 4)       AS razao_b_sobre_c,
  round(chi2_mcnemar, 3)                                 AS qui2_mcnemar,
  p_valor_qui2_1gl(chi2_mcnemar)                         AS p_valor,
  CASE
    WHEN p_valor_qui2_1gl(chi2_mcnemar) < 0.05 AND b_so_gr_entregou > c_so_outro_entregou
      THEN 'Para o mesmo cliente, o telefone do GR entrega MAIS (p<0,05).'
    WHEN p_valor_qui2_1gl(chi2_mcnemar) < 0.05
      THEN 'Para o mesmo cliente, o telefone do GR entrega MENOS (p<0,05).'
    ELSE 'Sem diferença detectável no pareado.'
  END                                                    AS leitura
FROM calc
;
SELECT * FROM vt_res_04_mcnemar;


/* -----------------------------------------------------------------------------
   4.3  DIFERENÇA MÉDIA PAREADA DAS TAXAS POR CPF (todos os envios)
   -----------------------------------------------------------------------------
   d_i = taxa_conc_i - taxa_disc_i para cada CPF pareado.
   z = média(d) / (dp(d)/√n).  IC 95% = média ± 1,96 dp/√n.
   Complementa 4.2 usando toda a informação (mas com exposição desigual).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_04_diferenca_media AS
WITH d AS (
  SELECT cpf, taxa_conc - taxa_disc AS dif FROM vt_pareado_cpf
),
agg AS (
  SELECT
    count(*)          AS n,
    avg(dif)          AS media_dif,
    stddev_samp(dif)  AS dp_dif
  FROM d
)
SELECT
  n                                                         AS cpfs_pareados,
  round(100.0 * media_dif, 4)                               AS diferenca_media_pp,
  round(100.0 * (media_dif - 1.959964 * dp_dif / sqrt(n)), 4) AS ic95_inf_pp,
  round(100.0 * (media_dif + 1.959964 * dp_dif / sqrt(n)), 4) AS ic95_sup_pp,
  round(media_dif / nullif(dp_dif / sqrt(n), 0), 3)                  AS z,
  p_valor_bilateral(media_dif / nullif(dp_dif / sqrt(n), 0))         AS p_valor
FROM agg
;
SELECT * FROM vt_res_04_diferenca_media;


/* -----------------------------------------------------------------------------
   4.4  VERSÃO ESTRITA: mesmo CPF, MESMA CAMPANHA, um envio em cada braço
   -----------------------------------------------------------------------------
   Só existe se o CRM dispara para mais de um telefone do mesmo cliente na
   mesma campanha. Elimina qualquer efeito de campanha. Se n_pares for
   pequeno (< 500), reportar como ilustrativo e não como prova.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_04_mcnemar_mesma_campanha AS
WITH pares AS (
  SELECT
    cpf, campanha,
    max(CASE WHEN concordante = 1 THEN entregue END) AS entregue_gr,
    max(CASE WHEN concordante = 0 THEN entregue END) AS entregue_outro
  FROM vt_experimento
  GROUP BY cpf, campanha
  HAVING max(CASE WHEN concordante = 1 THEN 1 ELSE 0 END) = 1
     AND max(CASE WHEN concordante = 0 THEN 1 ELSE 0 END) = 1
),
tab AS (
  SELECT
    count(*)                                                                AS n_pares,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS b_so_gr_entregou,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS c_so_outro_entregou,
    avg(entregue_gr)                                                        AS taxa_gr,
    avg(entregue_outro)                                                     AS taxa_outro
  FROM pares
),
calc AS (
  SELECT
    *,
    CASE WHEN b_so_gr_entregou + c_so_outro_entregou > 0
         THEN power(b_so_gr_entregou - c_so_outro_entregou, 2)
              / (b_so_gr_entregou + c_so_outro_entregou) END                AS chi2_mcnemar
  FROM tab
)
SELECT
  n_pares,
  b_so_gr_entregou,
  c_so_outro_entregou,
  round(100.0 * taxa_gr, 4)                    AS taxa_entrega_telefone_gr_pct,
  round(100.0 * taxa_outro, 4)                 AS taxa_entrega_telefone_outro_pct,
  round(100.0 * (taxa_gr - taxa_outro), 4)     AS diferenca_pp,
  round(chi2_mcnemar, 3)                       AS qui2_mcnemar,
  p_valor_qui2_1gl(chi2_mcnemar)               AS p_valor,
  CASE WHEN n_pares < 500 THEN 'Amostra pequena: tratar como ilustrativo.'
       WHEN p_valor_qui2_1gl(chi2_mcnemar) < 0.05 AND b_so_gr_entregou > c_so_outro_entregou
         THEN 'Mesma campanha, mesmo cliente: telefone do GR entrega MAIS (p<0,05).'
       WHEN p_valor_qui2_1gl(chi2_mcnemar) < 0.05
         THEN 'Mesma campanha, mesmo cliente: telefone do GR entrega MENOS (p<0,05).'
       ELSE 'Sem diferença detectável.' END     AS leitura
FROM calc
;
SELECT * FROM vt_res_04_mcnemar_mesma_campanha;
