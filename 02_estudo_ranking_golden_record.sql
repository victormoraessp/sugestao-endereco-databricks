/* =============================================================================
   ESTUDO 2  RANKING DO GOLDEN RECORD CONTRA A ORDEM DE ACIONAMENTO DO CRM
   =============================================================================

   PERGUNTA
   O ranking do Golden Record separa telefone bom de telefone ruim ao longo de
   todas as suas posições? E se a operação acionasse os telefones na ordem do
   Golden Record em vez da ordem do cadastro do CRM, o que mudaria?

   REGRA DE SUBSTITUIÇÃO AVALIADA
   Cada disparo ocupa uma posição dentro da campanha, do primeiro ao enésimo
   telefone acionado para aquele cliente. A regra mapeia posição por posição:
     posição 1 do CRM recebe o telefone de ranking 1 do Golden Record
     posição 2 recebe o ranking 2, e assim por diante até a profundidade
     posições além da profundidade voltam ao ranking 1
   Quando o cliente não possui a posição pedida, o plano recorre ao ranking 1 e
   a ocorrência fica registrada como uso de reserva.

   COMO O PLANO É AVALIADO SEM SUPOSIÇÃO
   Sempre que o telefone indicado pelo plano também foi acionado pelo CRM na
   mesma campanha, o desfecho daquele número é fato registrado. Isso cria um
   subconjunto em que a comparação entre as duas ordens é feita inteiramente
   com dados observados.

   LIMITE ESTRUTURAL DESTE SUBCONJUNTO
   Um par só é integralmente observado quando todos os números do plano também
   foram acionados naquela campanha. Nesse recorte o plano trabalha sobre um
   subconjunto dos números que a operação já tentou, e portanto não pode
   conquistar cobertura nova, porque não há número inédito em jogo. O que ele
   pode fazer é alcançar mais cedo o número que funciona, e é isso que a
   economia de disparos mede. O ganho de cobertura por números inéditos é
   estimado no estudo 1.

   DEPENDÊNCIA
   Consome as duas tabelas materializadas pelo estudo 1. Rode o estudo 1 antes,
   ao menos uma vez, para que elas existam.

   SAÍDA
   Um único resultado é exibido, o resumo executivo da seção 08.

   ESTRUTURA
     00  Parâmetros
     01  Funções estatísticas
     02  Leitura das tabelas materializadas e escopo
     03  Qualidade do ranking
     04  Plano de substituição posição a posição
     05  Simulação de sequência
     06  Valuation da reordenação
     07  Ressalva sobre a ordem de origem
     08  Resumo executivo
   ============================================================================= */


/* =============================================================================
   SEÇÃO 00  PARÂMETROS
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_param AS
SELECT
  CAST(0.04     AS DOUBLE) AS custo_sms,
  CAST(0.0050   AS DOUBLE) AS taxa_conversao,
  CAST(150.00   AS DOUBLE) AS valor_conversao,
  CAST(4        AS INT)    AS profundidade_ranking,
  CAST(1.959964 AS DOUBLE) AS z_95,
  CAST(1000000  AS BIGINT) AS volume_referencia
;

CREATE OR REPLACE TEMP VIEW vt_param_grupos AS
SELECT
  'GRUPO_1'                   AS grupo,
  'Recorte 1'                 AS descricao,
  CAST(NULL AS ARRAY<STRING>) AS campanhas,
  CAST(NULL AS STRING)        AS campanhas_texto
UNION ALL
SELECT 'GRUPO_2', 'Recorte 2', CAST(NULL AS ARRAY<STRING>), CAST(NULL AS STRING)
UNION ALL
SELECT 'GRUPO_3', 'Recorte 3', CAST(NULL AS ARRAY<STRING>), CAST(NULL AS STRING)
;


/* =============================================================================
   SEÇÃO 01  FUNÇÕES ESTATÍSTICAS

   Recriadas porque funções temporárias não sobrevivem ao fim da sessão.
   Nenhuma delas pode ser chamada dentro de round, pelo motivo documentado no
   estudo 1.
   ============================================================================= */

CREATE OR REPLACE TEMPORARY FUNCTION stat_t_as(x DOUBLE)
RETURNS DOUBLE
RETURN 1.0 / (1.0 + 0.2316419 * abs(x));

CREATE OR REPLACE TEMPORARY FUNCTION stat_tail_as(x DOUBLE)
RETURNS DOUBLE
RETURN
  (exp(-(x * x) / 2.0) / sqrt(2.0 * pi()))
  * stat_t_as(x)
  * ( 0.319381530
      + stat_t_as(x) * ( -0.356563782
      + stat_t_as(x) * (  1.781477937
      + stat_t_as(x) * ( -1.821255978
      + stat_t_as(x) *    1.330274429 ))));

CREATE OR REPLACE TEMPORARY FUNCTION norm_cdf(x DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN x IS NULL THEN NULL
            WHEN x >= 0    THEN 1.0 - stat_tail_as(x)
            ELSE                stat_tail_as(x) END;

CREATE OR REPLACE TEMPORARY FUNCTION p_valor_bilateral(z DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN z IS NULL THEN NULL ELSE 2.0 * (1.0 - norm_cdf(abs(z))) END;

CREATE OR REPLACE TEMPORARY FUNCTION p_valor_qui2_1gl(chi2 DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN chi2 IS NULL OR chi2 < 0 THEN NULL
            ELSE 2.0 * (1.0 - norm_cdf(sqrt(chi2))) END;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_inf(k DOUBLE, n DOUBLE)
RETURNS DOUBLE
RETURN
  CASE WHEN n IS NULL OR n <= 0 OR k IS NULL THEN NULL ELSE
    ( (k / n) + (1.959964 * 1.959964) / (2.0 * n)
      - 1.959964 * sqrt( (k / n) * (1.0 - k / n) / n
                         + (1.959964 * 1.959964) / (4.0 * n * n) ) )
    / (1.0 + (1.959964 * 1.959964) / n)
  END;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_sup(k DOUBLE, n DOUBLE)
RETURNS DOUBLE
RETURN
  CASE WHEN n IS NULL OR n <= 0 OR k IS NULL THEN NULL ELSE
    ( (k / n) + (1.959964 * 1.959964) / (2.0 * n)
      + 1.959964 * sqrt( (k / n) * (1.0 - k / n) / n
                         + (1.959964 * 1.959964) / (4.0 * n * n) ) )
    / (1.0 + (1.959964 * 1.959964) / n)
  END;


/* =============================================================================
   SEÇÃO 02  LEITURA DAS TABELAS MATERIALIZADAS E ESCOPO
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW tb_gr_telefone_ranking AS
SELECT * FROM catalogo.schema.tb_gr_telefone_ranking
;

CREATE OR REPLACE TEMP VIEW tb_crm_envio_analitico AS
SELECT * FROM catalogo.schema.tb_crm_envio_analitico
;

CREATE OR REPLACE TEMP VIEW vt_gr_rank1 AS
SELECT cpf, telefone_gr, ddd_gr, chave_gr
FROM tb_gr_telefone_ranking
WHERE ranking = 1
;

CREATE OR REPLACE TEMP VIEW vt_gr_profundidade_cpf AS
SELECT
  cpf,
  count(*)                    AS rankings_disponiveis,
  count(DISTINCT telefone_gr) AS telefones_distintos
FROM tb_gr_telefone_ranking
GROUP BY cpf
;

CREATE OR REPLACE TEMP VIEW vt_grupo_lista AS
SELECT
  grupo,
  descricao,
  CASE
    WHEN campanhas IS NOT NULL AND size(campanhas) > 0
      THEN array_distinct(filter(transform(campanhas, x -> trim(x)), x -> length(x) > 0))
    WHEN campanhas_texto IS NOT NULL AND length(trim(campanhas_texto)) > 0
      THEN array_distinct(filter(transform(split(campanhas_texto, ','), x -> trim(x)),
                                 x -> length(x) > 0))
    ELSE CAST(NULL AS ARRAY<STRING>)
  END AS campanhas
FROM vt_param_grupos
;

CREATE OR REPLACE TEMP VIEW vt_grupo_campanha AS
WITH definido AS (
  SELECT grupo, explode(campanhas) AS campanha
  FROM vt_grupo_lista
  WHERE campanhas IS NOT NULL AND size(campanhas) > 0
),
contagem AS (SELECT count(*) AS listadas FROM definido),
universo AS (SELECT DISTINCT campanha FROM tb_crm_envio_analitico),
total_sem_lista AS (
  SELECT 'TOTAL' AS grupo, u.campanha
  FROM universo u CROSS JOIN contagem c WHERE c.listadas = 0
),
total_com_lista AS (SELECT DISTINCT 'TOTAL' AS grupo, campanha FROM definido)
SELECT grupo, campanha FROM definido
UNION ALL SELECT grupo, campanha FROM total_com_lista
UNION ALL SELECT grupo, campanha FROM total_sem_lista
;

CREATE OR REPLACE TEMP VIEW vt_experimento AS
SELECT g.grupo, b.*
FROM tb_crm_envio_analitico b
JOIN vt_grupo_campanha g ON b.campanha = g.campanha
WHERE b.tem_gr
;

CREATE OR REPLACE TEMP VIEW vt_crm_envios AS
SELECT
  cpf, campanha, telefone_crm, chave_crm, entregue, ranking_crm, telefones_na_campanha
FROM tb_crm_envio_analitico
;


/* =============================================================================
   SEÇÃO 03  QUALIDADE DO RANKING
   =============================================================================
   O ranking do Golden Record carrega informação de verdade? A taxa de entrega
   cai à medida que a posição piora?

   A comparação usa o telefone efetivamente disparado, portanto não depende de
   nenhuma suposição contrafactual. É a evidência mais direta de que o ranking
   é um preditor válido de entregabilidade, e não uma ordenação arbitrária.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_03_por_ranking AS
WITH classificado AS (
  SELECT
    grupo,
    CASE
      WHEN ranking_gr_do_telefone_usado IS NULL THEN 'FORA_DO_GR'
      WHEN ranking_gr_do_telefone_usado >= 5    THEN 'RANKING_5_OU_MAIS'
      ELSE concat('RANKING_', CAST(ranking_gr_do_telefone_usado AS STRING))
    END AS posicao,
    ranking_gr_do_telefone_usado,
    entregue
  FROM vt_experimento
),
agg AS (
  SELECT
    grupo,
    posicao,
    min(coalesce(ranking_gr_do_telefone_usado, 99)) AS ordem,
    count(*)                                        AS envios,
    sum(entregue)                                   AS entregues
  FROM classificado
  GROUP BY grupo, posicao
),
intervalo AS (
  SELECT
    a.*,
    a.entregues / nullif(a.envios, 0)   AS taxa,
    wilson_inf(a.entregues, a.envios)   AS ic_inf,
    wilson_sup(a.entregues, a.envios)   AS ic_sup,
    a.envios / sum(a.envios) OVER (PARTITION BY a.grupo) AS fracao_envios
  FROM agg a
)
SELECT * FROM intervalo
;

CREATE OR REPLACE TEMP VIEW vt_res_03_monotonicidade AS
WITH base AS (
  SELECT grupo, ordem, posicao, envios, entregues, taxa
  FROM vt_res_03_por_ranking
  WHERE ordem <= 5
),
pares AS (
  SELECT
    b.grupo,
    b.posicao AS posicao_melhor,
    s.posicao AS posicao_pior,
    b.envios  AS envios_melhor,
    s.envios  AS envios_pior,
    b.taxa    AS taxa_melhor,
    s.taxa    AS taxa_pior,
    (b.entregues + s.entregues) / nullif(b.envios + s.envios, 0) AS p_pool
  FROM base b
  JOIN base s ON b.grupo = s.grupo AND s.ordem = b.ordem + 1
)
SELECT
  *,
  taxa_melhor - taxa_pior AS diferenca,
  p_valor_bilateral(
    (taxa_melhor - taxa_pior)
    / sqrt(p_pool * (1 - p_pool)
           * (1.0 / nullif(envios_melhor, 0) + 1.0 / nullif(envios_pior, 0)))) AS p_valor
FROM pares
;

CREATE OR REPLACE TEMP VIEW vt_res_03_estrutura AS
SELECT
  e.grupo,
  count(DISTINCT e.cpf)                                                     AS clientes,
  avg(coalesce(p.rankings_disponiveis, 0))                                  AS media_posicoes,
  count(DISTINCT CASE WHEN p.rankings_disponiveis > 1 THEN e.cpf END)
    / nullif(count(DISTINCT e.cpf), 0)                                      AS fracao_multiposicao,
  avg(CASE WHEN e.telefones_na_campanha > 1 THEN 1 ELSE 0 END)              AS fracao_disparo_multiplo,
  avg(CAST(e.telefones_na_campanha AS DOUBLE))                              AS media_telefones_disparo
FROM vt_experimento e
LEFT JOIN vt_gr_profundidade_cpf p ON e.cpf = p.cpf
GROUP BY e.grupo
;


/* =============================================================================
   SEÇÃO 04  PLANO DE SUBSTITUIÇÃO POSIÇÃO A POSIÇÃO
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_resultado_por_telefone_cpf AS
SELECT
  cpf,
  chave_crm,
  max(entregue)            AS ja_entregou,
  avg(entregue)            AS taxa_observada,
  count(DISTINCT campanha) AS campanhas
FROM vt_crm_envios
GROUP BY cpf, chave_crm
;

CREATE OR REPLACE TEMP VIEW vt_plano_substituicao AS
WITH alvo AS (
  SELECT
    e.grupo, e.cpf, e.campanha, e.telefone_crm, e.chave_crm, e.entregue,
    e.ranking_crm, e.telefones_na_campanha,
    CASE WHEN e.ranking_crm <= p.profundidade_ranking THEN e.ranking_crm ELSE 1 END AS ranking_alvo
  FROM vt_experimento e
  CROSS JOIN vt_param p
),
com_plano AS (
  SELECT
    a.*,
    coalesce(ga.telefone_gr, g1.telefone_gr) AS telefone_plano,
    coalesce(ga.chave_gr, g1.chave_gr)       AS chave_plano,
    CASE WHEN ga.cpf IS NOT NULL THEN 'RANKING_EXATO'
         WHEN g1.cpf IS NOT NULL THEN 'RESERVA_RANKING_1'
         ELSE 'SEM_PLANO' END                AS origem_plano
  FROM alvo a
  LEFT JOIN tb_gr_telefone_ranking ga ON a.cpf = ga.cpf AND ga.ranking = a.ranking_alvo
  LEFT JOIN vt_gr_rank1 g1            ON a.cpf = g1.cpf
),
com_desfecho AS (
  SELECT
    c.*,
    r.entregue       AS entregue_plano_campanha,
    h.ja_entregou    AS plano_ja_entregou,
    h.taxa_observada AS taxa_observada_plano
  FROM com_plano c
  LEFT JOIN vt_crm_envios r
    ON c.cpf = r.cpf AND c.campanha = r.campanha AND c.chave_plano = r.chave_crm
  LEFT JOIN vt_resultado_por_telefone_cpf h
    ON c.cpf = h.cpf AND c.chave_plano = h.chave_crm
)
SELECT
  *,
  CASE
    WHEN telefone_plano IS NULL              THEN 'SEM_PLANO'
    WHEN chave_plano = chave_crm             THEN 'PLANO_IGUAL_AO_USADO'
    WHEN entregue_plano_campanha IS NOT NULL THEN 'PLANO_OBSERVADO_NA_CAMPANHA'
    WHEN plano_ja_entregou IS NOT NULL       THEN 'PLANO_OBSERVADO_EM_OUTRA_CAMPANHA'
    ELSE                                          'PLANO_NAO_OBSERVADO'
  END AS classe_substituicao
FROM com_desfecho
;

CREATE OR REPLACE TEMP VIEW vt_res_04_composicao AS
SELECT
  grupo,
  classe_substituicao,
  count(*)                                            AS envios,
  count(*) / sum(count(*)) OVER (PARTITION BY grupo)  AS fracao,
  avg(CASE WHEN origem_plano = 'RESERVA_RANKING_1' THEN 1 ELSE 0 END) AS fracao_reserva
FROM vt_plano_substituicao
GROUP BY grupo, classe_substituicao
;

CREATE OR REPLACE TEMP VIEW vt_res_04_primeira_posicao AS
SELECT
  grupo,
  count(*)                                                                     AS envios,
  avg(CASE WHEN classe_substituicao = 'PLANO_IGUAL_AO_USADO' THEN 1 ELSE 0 END) AS fracao_confirma,
  avg(CASE WHEN classe_substituicao <> 'PLANO_IGUAL_AO_USADO' THEN 1 ELSE 0 END) AS fracao_troca,
  avg(entregue)                                                                AS taxa_entrega
FROM vt_plano_substituicao
WHERE ranking_crm = 1
GROUP BY grupo
;

/* Comparação pareada restrita aos disparos em que o plano trocaria o número por
   outro que também foi acionado na mesma campanha. Nesses casos os dois
   desfechos são fatos registrados, e a comparação não depende de premissa. */
CREATE OR REPLACE TEMP VIEW vt_res_04_pareado AS
WITH base AS (
  SELECT grupo, ranking_crm, entregue AS usado, entregue_plano_campanha AS plano
  FROM vt_plano_substituicao
  WHERE classe_substituicao = 'PLANO_OBSERVADO_NA_CAMPANHA'
),
tab AS (
  SELECT
    grupo,
    count(*)                                                  AS comparacoes,
    sum(CASE WHEN plano = 1 AND usado = 0 THEN 1 ELSE 0 END)  AS so_plano,
    sum(CASE WHEN plano = 0 AND usado = 1 THEN 1 ELSE 0 END)  AS so_usado,
    avg(plano)                                                AS taxa_plano,
    avg(usado)                                                AS taxa_usado
  FROM base
  GROUP BY grupo
)
SELECT
  *,
  taxa_plano - taxa_usado AS diferenca,
  p_valor_qui2_1gl(
    CASE WHEN so_plano + so_usado > 0
         THEN power(so_plano - so_usado, 2) / (so_plano + so_usado) END) AS p_valor
FROM tab
;

CREATE OR REPLACE TEMP VIEW vt_res_04_pareado_posicao1 AS
WITH base AS (
  SELECT grupo, entregue AS usado, entregue_plano_campanha AS plano
  FROM vt_plano_substituicao
  WHERE classe_substituicao = 'PLANO_OBSERVADO_NA_CAMPANHA' AND ranking_crm = 1
),
tab AS (
  SELECT
    grupo,
    count(*)                                                 AS comparacoes,
    sum(CASE WHEN plano = 1 AND usado = 0 THEN 1 ELSE 0 END) AS so_plano,
    sum(CASE WHEN plano = 0 AND usado = 1 THEN 1 ELSE 0 END) AS so_usado,
    avg(plano)                                               AS taxa_plano,
    avg(usado)                                               AS taxa_usado
  FROM base
  GROUP BY grupo
)
SELECT
  *,
  taxa_plano - taxa_usado AS diferenca,
  p_valor_qui2_1gl(
    CASE WHEN so_plano + so_usado > 0
         THEN power(so_plano - so_usado, 2) / (so_plano + so_usado) END) AS p_valor
FROM tab
;


/* =============================================================================
   SEÇÃO 05  SIMULAÇÃO DE SEQUÊNCIA
   =============================================================================
   Reconstrói, para cada par de cliente e campanha, duas trajetórias de
   acionamento: a que de fato ocorreu, na ordem do CRM, e a que teria ocorrido
   na ordem do Golden Record. Para cada uma, identifica em que posição a
   primeira entrega acontece.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_simulacao_sequencia AS
WITH agregado AS (
  SELECT
    grupo, cpf, campanha,
    count(*)                                                         AS tentativas,
    min(CASE WHEN entregue = 1 THEN ranking_crm END)                 AS pos_sucesso_crm,
    min(CASE WHEN entregue_plano_campanha = 1 THEN ranking_crm END)  AS pos_sucesso_plano,
    sum(CASE WHEN entregue_plano_campanha IS NULL THEN 1 ELSE 0 END) AS nao_observadas
  FROM vt_plano_substituicao
  GROUP BY grupo, cpf, campanha
)
SELECT
  *,
  coalesce(pos_sucesso_crm, tentativas)                                     AS disparos_crm,
  coalesce(pos_sucesso_plano, tentativas)                                   AS disparos_plano,
  coalesce(pos_sucesso_crm, tentativas) - coalesce(pos_sucesso_plano, tentativas) AS economia,
  CASE
    WHEN pos_sucesso_crm IS NOT NULL AND pos_sucesso_plano IS NOT NULL THEN 'AMBOS_ENTREGAM'
    WHEN pos_sucesso_plano IS NOT NULL                                 THEN 'SOMENTE_PLANO'
    WHEN pos_sucesso_crm IS NOT NULL                                   THEN 'SOMENTE_CRM'
    ELSE                                                                    'NENHUM'
  END                                                                       AS desfecho,
  (nao_observadas = 0)                                                      AS observado
FROM agregado
;

CREATE OR REPLACE TEMP VIEW vt_res_05_sequencia AS
SELECT
  grupo,
  count(*)                                                    AS pares,
  CAST(sum(tentativas) AS BIGINT)                             AS disparos,
  CAST(sum(disparos_crm) AS BIGINT)                           AS disparos_crm,
  CAST(sum(disparos_plano) AS BIGINT)                         AS disparos_plano,
  CAST(sum(economia) AS BIGINT)                               AS economia_disparos,
  avg(CAST(economia AS DOUBLE))                               AS economia_media,
  sum(economia) / nullif(sum(disparos_crm), 0)                AS fracao_reducao,
  sum(CASE WHEN economia > 0 THEN 1 ELSE 0 END)               AS pares_com_ganho,
  sum(CASE WHEN economia < 0 THEN 1 ELSE 0 END)               AS pares_com_atraso,
  sum(CASE WHEN desfecho = 'SOMENTE_CRM' THEN 1 ELSE 0 END)   AS perda_cobertura,
  avg(CASE WHEN desfecho = 'SOMENTE_CRM' THEN 1 ELSE 0 END)   AS fracao_perda_cobertura,
  sum(CASE WHEN desfecho = 'AMBOS_ENTREGAM' THEN 1 ELSE 0 END) AS ambos,
  sum(CASE WHEN desfecho = 'NENHUM' THEN 1 ELSE 0 END)        AS nenhum
FROM vt_simulacao_sequencia
WHERE observado
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_05_abrangencia AS
SELECT
  grupo,
  count(*)                                                        AS pares_totais,
  sum(CASE WHEN observado THEN 1 ELSE 0 END)                      AS pares_observados,
  avg(CASE WHEN observado THEN 1 ELSE 0 END)                      AS fracao_pares,
  CAST(sum(tentativas) AS BIGINT)                                 AS disparos_totais,
  sum(CASE WHEN observado THEN tentativas ELSE 0 END)
    / nullif(sum(tentativas), 0)                                  AS fracao_disparos
FROM vt_simulacao_sequencia
GROUP BY grupo
;


/* =============================================================================
   SEÇÃO 06  VALUATION DA REORDENAÇÃO
   =============================================================================
   Cada disparo poupado é um custo que deixa de existir. Ao contrário do estudo
   1, esta camada não depende de premissa de conversão: é caixa direto.

   Valor negativo significa que a ordem do Golden Record chega ao número que
   funciona depois da ordem atual, e portanto gastaria mais disparos.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_06_valuation AS
SELECT
  s.grupo,
  s.economia_disparos,
  s.fracao_reducao,
  p.custo_sms,
  s.economia_disparos * p.custo_sms                                     AS economia_observada,
  a.fracao_disparos,
  s.economia_disparos / nullif(a.fracao_disparos, 0)                    AS economia_projetada_disparos,
  s.economia_disparos / nullif(a.fracao_disparos, 0) * p.custo_sms      AS economia_projetada
FROM vt_res_05_sequencia s
JOIN vt_res_05_abrangencia a ON s.grupo = a.grupo
CROSS JOIN vt_param p
;


/* =============================================================================
   SEÇÃO 07  RESSALVA SOBRE A ORDEM DE ORIGEM
   =============================================================================
   A ordem do CRM usada como referência é inferida quando a base de campanhas
   não traz um campo explícito de prioridade de telefone. A inferência assume
   que o slot principal do cadastro é o número acionado no maior volume de
   campanhas daquele cliente.

   Consequência para a leitura: os resultados da seção 05, que comparam a ordem
   do Golden Record com a ordem do CRM, são tão bons quanto essa inferência.
   Já a seção 03, sobre a qualidade do ranking, e a seção 04, sobre a
   comparação posição a posição, não dependem dela, porque comparam telefones e
   não ordens. Quando a base de origem passar a expor a prioridade real, basta
   preenchê-la no estudo 1 e a seção 05 ganha força.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_07_origem_ordem AS
SELECT
  grupo,
  avg(CASE WHEN telefones_na_campanha > 1 THEN 1 ELSE 0 END) AS fracao_disparo_multiplo,
  count(DISTINCT concat(cpf, '|', campanha))                 AS pares_cpf_campanha
FROM vt_experimento
GROUP BY grupo
;


/* -----------------------------------------------------------------------------
   07.1  INSUMOS COMPLEMENTARES DO RESUMO
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_contraste AS
SELECT
  r1.grupo,
  r1.taxa                AS taxa_ranking1,
  r1.envios              AS envios_ranking1,
  fora.taxa              AS taxa_fora,
  fora.envios            AS envios_fora,
  r1.taxa - fora.taxa    AS diferenca
FROM (SELECT * FROM vt_res_03_por_ranking WHERE posicao = 'RANKING_1') r1
LEFT JOIN (SELECT * FROM vt_res_03_por_ranking WHERE posicao = 'FORA_DO_GR') fora
  ON r1.grupo = fora.grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_07_reserva AS
SELECT
  grupo,
  avg(CASE WHEN origem_plano = 'RESERVA_RANKING_1' THEN 1 ELSE 0 END) AS fracao_reserva,
  avg(CASE WHEN ranking_crm > 1 THEN 1 ELSE 0 END)                    AS fracao_posicao_profunda
FROM vt_plano_substituicao
GROUP BY grupo
;


/* =============================================================================
   SEÇÃO 08  RESUMO EXECUTIVO
   =============================================================================
   Única saída exibida por este arquivo.

   Blocos:
     A  Estrutura do ranking, o que existe para trabalhar
     B  Qualidade do ranking, a ordenação carrega informação
     C  Substituição posição a posição, o telefone certo em cada tentativa
     D  Simulação de sequência, a ordem de acionamento
     E  Valuation da reordenação, o efeito em caixa
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_08_resumo AS

/* ---------------------------------------------------------------- BLOCO A -- */
SELECT
  e.grupo,
  'A. Estrutura do ranking'                    AS bloco,
  1                                            AS ordem,
  'Clientes analisados'                        AS indicador,
  CAST(e.clientes AS DOUBLE)                   AS valor,
  'CPFs'                                       AS unidade,
  'Clientes com cobertura do Golden Record dentro do escopo.'                    AS definicao,
  'Contagem distinta de CPF na base analitica materializada pelo estudo 1.'      AS calculo,
  'E o universo em que a comparacao entre ordenacoes pode ser feita.'            AS interpretacao,
  concat('Media de ', format_number(e.media_telefones_disparo, 2),
         ' telefones acionados por cliente em cada campanha.')                   AS exemplo,
  'vt_res_03_estrutura'                        AS origem
FROM vt_res_03_estrutura e

UNION ALL
SELECT e.grupo, 'A. Estrutura do ranking', 2, 'Posicoes de ranking por cliente',
  round(CAST(e.media_posicoes AS DOUBLE), 4), 'posicoes',
  'Quantidade media de telefones ranqueados que o Golden Record oferece por cliente.',
  'Media do numero de posicoes distintas por CPF na tabela de ranking.',
  'Define ate onde o plano de substituicao consegue ir. Com media proxima de um, a troca de ordem tem pouco espaco para atuar, porque nao existe alternativa cadastrada.',
  concat(format_number(100.0 * e.fracao_multiposicao, 1),
         ' por cento dos clientes tem mais de uma posicao disponivel.'),
  'vt_res_03_estrutura'
FROM vt_res_03_estrutura e

UNION ALL
SELECT e.grupo, 'A. Estrutura do ranking', 3, 'Disparos com mais de um telefone na mesma campanha',
  round(CAST(100.0 * e.fracao_disparo_multiplo AS DOUBLE), 4), '%',
  'Percentual dos disparos que ocorreram em campanhas nas quais o cliente recebeu SMS em mais de um numero.',
  'Fracao dos envios cujo par de cliente e campanha possui dois ou mais telefones distintos.',
  'E a materia-prima da simulacao de sequencia. Quanto menor, menor o alcance de qualquer politica de ordenacao, porque a maioria dos disparos e tentativa unica.',
  'Em disparo unico nao existe ordem a otimizar, apenas escolha do numero, tratada no bloco C.',
  'vt_res_03_estrutura'
FROM vt_res_03_estrutura e

/* ---------------------------------------------------------------- BLOCO B -- */
UNION ALL
SELECT r.grupo, 'B. Qualidade do ranking', 10, 'Entrega no telefone de ranking 1',
  round(CAST(100.0 * r.taxa AS DOUBLE), 4), '%',
  'Taxa de entrega observada quando o numero acionado ocupa a primeira posicao do Golden Record.',
  'Entregas divididas por envios, entre os disparos cujo numero coincide com a posicao 1.',
  'E o teto pratico de desempenho por cliente. Nenhuma outra posicao deveria superar esta se o ranking estiver calibrado.',
  concat('Intervalo de 95 por cento entre ', format_number(100.0 * r.ic_inf, 2), ' e ',
         format_number(100.0 * r.ic_sup, 2), ' por cento, sobre ', format_number(r.envios, 0), ' disparos.'),
  'vt_res_03_por_ranking'
FROM vt_res_03_por_ranking r WHERE r.posicao = 'RANKING_1'

UNION ALL
SELECT r.grupo, 'B. Qualidade do ranking', 11, 'Entrega no telefone de ranking 2',
  round(CAST(100.0 * r.taxa AS DOUBLE), 4), '%',
  'Taxa de entrega observada quando o numero acionado ocupa a segunda posicao do Golden Record.',
  'Entregas divididas por envios, entre os disparos cujo numero coincide com a posicao 2.',
  'Deve ficar abaixo da linha 10 e acima das posicoes seguintes. E o segundo degrau da escada de qualidade.',
  concat('Baseada em ', format_number(r.envios, 0), ' disparos, ou ',
         format_number(100.0 * r.fracao_envios, 2), ' por cento do volume com cobertura.'),
  'vt_res_03_por_ranking'
FROM vt_res_03_por_ranking r WHERE r.posicao = 'RANKING_2'

UNION ALL
SELECT c.grupo, 'B. Qualidade do ranking', 12, 'Entrega em numero ausente do Golden Record',
  round(CAST(100.0 * c.taxa_fora AS DOUBLE), 4), '%',
  'Taxa de entrega quando o numero acionado nao consta em nenhuma posicao do ranking daquele cliente.',
  'Entregas divididas por envios, entre os disparos sem correspondencia no Golden Record.',
  'E o piso da escada. A distancia para a linha 10 mede o poder de discriminacao do cadastro como um todo.',
  concat('Sao ', format_number(c.envios_fora, 0), ' disparos para numeros fora do ranking.'),
  'vt_res_07_contraste'
FROM vt_res_07_contraste c

UNION ALL
SELECT m.grupo, 'B. Qualidade do ranking', 13, 'Vantagem do ranking 1 sobre o ranking 2',
  round(CAST(100.0 * m.diferenca AS DOUBLE), 4), 'p.p.',
  'Diferenca de entrega entre a primeira e a segunda posicao do Golden Record.',
  'Taxa da posicao 1 menos taxa da posicao 2, com teste de duas proporcoes.',
  'Valor positivo confirma que a ordenacao interna do cadastro carrega informacao real, e nao e um rotulo arbitrario. E o teste mais direto da qualidade do ranking.',
  concat('Probabilidade de ser acaso: ', format_number(m.p_valor, 6),
         '. Comparacao entre ', format_number(m.envios_melhor, 0), ' e ',
         format_number(m.envios_pior, 0), ' disparos.'),
  'vt_res_03_monotonicidade'
FROM vt_res_03_monotonicidade m WHERE m.posicao_melhor = 'RANKING_1'

UNION ALL
SELECT c.grupo, 'B. Qualidade do ranking', 14, 'Vantagem do ranking 1 sobre numero fora do cadastro',
  round(CAST(100.0 * c.diferenca AS DOUBLE), 4), 'p.p.',
  'Diferenca de entrega entre o telefone de primeira posicao e um numero que nao consta no ranking.',
  'Taxa da posicao 1 menos taxa dos disparos sem correspondencia no Golden Record.',
  'E o argumento mais forte a favor do cadastro, porque compara o melhor caso com a ausencia de recomendacao. Costuma ser bem maior que a vantagem entre posicoes vizinhas.',
  concat('Equivale a ', format_number(c.diferenca * 1000000, 0),
         ' entregas a mais a cada milhao de disparos migrados de numero fora do cadastro para a primeira posicao.'),
  'vt_res_07_contraste'
FROM vt_res_07_contraste c

/* ---------------------------------------------------------------- BLOCO C -- */
UNION ALL
SELECT p.grupo, 'C. Substituicao por posicao', 20, 'Primeiros acionamentos em que o plano trocaria o numero',
  round(CAST(100.0 * p.fracao_troca AS DOUBLE), 4), '%',
  'Percentual dos primeiros disparos de cada cliente e campanha em que a ordem do Golden Record usaria outro telefone.',
  'Fracao dos envios de posicao 1 cuja classe de substituicao nao e confirmacao do numero ja usado.',
  'Dimensiona o impacto operacional da mudanca no contato inicial, que e o de maior valor porque define se havera necessidade de novas tentativas.',
  concat('Nos demais ', format_number(100.0 * p.fracao_confirma, 1),
         ' por cento o plano apenas confirma o numero que ja seria acionado.'),
  'vt_res_04_primeira_posicao'
FROM vt_res_04_primeira_posicao p

UNION ALL
SELECT r.grupo, 'C. Substituicao por posicao', 21, 'Vantagem do telefone do plano, desfecho observado',
  round(CAST(100.0 * r.diferenca AS DOUBLE), 4), 'p.p.',
  'Comparacao pareada entre o telefone que o plano usaria e o que foi de fato usado, restrita aos casos em que ambos foram acionados na mesma campanha.',
  'Teste de McNemar sobre os disparos cuja substituicao aponta para um numero de desfecho conhecido.',
  'E a evidencia sem premissa deste estudo: os dois desfechos sao fatos registrados. Valor positivo indica que, posicao a posicao, o Golden Record escolhe melhor que o cadastro atual.',
  concat('Em ', format_number(r.comparacoes, 0), ' comparacoes, so o telefone do plano entregou em ',
         format_number(r.so_plano, 0), ' casos contra ', format_number(r.so_usado, 0),
         ' do telefone usado. Probabilidade de ser acaso: ', format_number(r.p_valor, 6), '.'),
  'vt_res_04_pareado'
FROM vt_res_04_pareado r

UNION ALL
SELECT r.grupo, 'C. Substituicao por posicao', 22, 'Vantagem do telefone do plano no primeiro acionamento',
  round(CAST(100.0 * r.diferenca AS DOUBLE), 4), 'p.p.',
  'A mesma comparacao pareada, restrita ao primeiro disparo de cada cliente e campanha.',
  'Teste de McNemar sobre os envios de posicao 1 com desfecho conhecido nos dois numeros.',
  'Isola a decisao de maior valor operacional. Ganho aqui reduz a necessidade de tentativas subsequentes e portanto o custo total da campanha.',
  concat('Baseada em ', format_number(r.comparacoes, 0), ' comparacoes.'),
  'vt_res_04_pareado_posicao1'
FROM vt_res_04_pareado_posicao1 r

UNION ALL
SELECT rv.grupo, 'C. Substituicao por posicao', 23, 'Disparos em que o plano recorreu a reserva',
  round(CAST(100.0 * rv.fracao_reserva AS DOUBLE), 4), '%',
  'Percentual dos disparos em que o cliente nao possuia a posicao de ranking pedida e o plano voltou para a primeira posicao.',
  'Fracao dos envios cuja origem do plano e reserva, e nao correspondencia exata de posicao.',
  'Mede o quanto a profundidade do cadastro limita a politica. Valor alto indica que ampliar a profundidade do Golden Record tem mais efeito do que mudar a regra de ordenacao.',
  concat(format_number(100.0 * rv.fracao_posicao_profunda, 1),
         ' por cento dos disparos ocorrem em posicoes alem da primeira.'),
  'vt_res_07_reserva'
FROM vt_res_07_reserva rv

/* ---------------------------------------------------------------- BLOCO D -- */
UNION ALL
SELECT a.grupo, 'D. Simulacao de sequencia', 30, 'Abrangencia da simulacao',
  round(CAST(100.0 * a.fracao_disparos AS DOUBLE), 4), '%',
  'Percentual do volume de disparos que pode ser simulado sem nenhuma suposicao.',
  'Disparos pertencentes a pares de cliente e campanha em que todos os numeros do plano tambem foram acionados, divididos pelo volume total.',
  'Quanto maior, mais representativo o bloco. O restante do volume nao permite comparacao observada porque o plano indicaria numeros nunca acionados, e esses casos sao tratados no estudo 1.',
  concat(format_number(a.pares_observados, 0), ' pares observados de um total de ',
         format_number(a.pares_totais, 0), '.'),
  'vt_res_05_abrangencia'
FROM vt_res_05_abrangencia a

UNION ALL
SELECT s.grupo, 'D. Simulacao de sequencia', 31, 'Reducao de disparos ate a primeira entrega',
  round(CAST(100.0 * s.fracao_reducao AS DOUBLE), 4), '%',
  'Variacao no numero de acionamentos necessarios para alcancar a primeira entrega, ao trocar a ordem do CRM pela ordem do Golden Record.',
  'Soma dos disparos ate o desfecho na ordem atual menos a mesma soma na ordem do plano, dividida pela primeira.',
  'Valor positivo significa que o plano chega antes ao numero que funciona e poupa disparos. Valor negativo significa que chega depois e gasta mais. Leia junto com a ressalva da secao 07, porque a ordem atual e inferida quando a origem nao traz prioridade explicita.',
  concat('Foram ', format_number(s.economia_disparos, 0), ' disparos de diferenca em ',
         format_number(s.pares, 0), ' pares, ou ', format_number(s.economia_media, 4), ' por par.'),
  'vt_res_05_sequencia'
FROM vt_res_05_sequencia s

UNION ALL
SELECT s.grupo, 'D. Simulacao de sequencia', 32, 'Pares em que o plano acerta antes',
  CAST(s.pares_com_ganho AS DOUBLE), 'pares',
  'Casos em que a ordem do Golden Record alcanca a entrega em uma posicao mais adiantada.',
  'Pares de cliente e campanha com economia de disparos positiva no conjunto observado.',
  'Compare com a linha 33. O saldo entre as duas explica o sinal da linha 31 melhor do que a media, porque revela se o efeito vem de muitos casos pequenos ou de poucos casos grandes.',
  concat('Contra ', format_number(s.pares_com_atraso, 0), ' pares em que o plano acerta depois.'),
  'vt_res_05_sequencia'
FROM vt_res_05_sequencia s

UNION ALL
SELECT s.grupo, 'D. Simulacao de sequencia', 33, 'Pares em que o plano acerta depois',
  CAST(s.pares_com_atraso AS DOUBLE), 'pares',
  'Casos em que a ordem do Golden Record alcanca a entrega em uma posicao mais atrasada.',
  'Pares de cliente e campanha com economia de disparos negativa no conjunto observado.',
  'Quando esta linha supera a linha 32, a ordem atual ja esta bem calibrada e o ganho da reordenacao esta na escolha do numero, tratada no bloco C, e nao na sequencia.',
  concat('Em ', format_number(s.ambos, 0), ' pares as duas ordens entregam, e em ',
         format_number(s.nenhum, 0), ' nenhuma entrega.'),
  'vt_res_05_sequencia'
FROM vt_res_05_sequencia s

UNION ALL
SELECT s.grupo, 'D. Simulacao de sequencia', 34, 'Perda de cobertura por truncamento do plano',
  round(CAST(100.0 * s.fracao_perda_cobertura AS DOUBLE), 4), '%',
  'Casos em que o numero que resolveu o contato esta fora da profundidade do plano e portanto nao seria acionado.',
  'Pares em que apenas a ordem atual alcanca entrega, divididos pelo total de pares observados.',
  'E o principal risco da politica de truncamento. Se a perda se concentrar em posicoes profundas, ampliar a profundidade no parametro resolve sem mudar a regra.',
  concat('Ocorre em ', format_number(s.perda_cobertura, 0), ' de ',
         format_number(s.pares, 0), ' pares avaliados.'),
  'vt_res_05_sequencia'
FROM vt_res_05_sequencia s

/* ---------------------------------------------------------------- BLOCO E -- */
UNION ALL
SELECT v.grupo, 'E. Valuation da reordenacao', 40, 'Disparos poupados no conjunto observado',
  CAST(v.economia_disparos AS DOUBLE), 'envios',
  'Quantidade de acionamentos que deixariam de existir ao adotar a ordem do Golden Record, medida sem estimativa.',
  'Diferenca entre os disparos ate o desfecho nas duas ordens, restrita ao conjunto integralmente observado.',
  'E caixa direto e nao depende de premissa de conversao. Valor negativo indica gasto adicional, e nesse caso a reordenacao nao deve ser adotada isoladamente.',
  concat('Sobre ', format_number(v.economia_disparos, 0), ' disparos, ao custo unitario de ',
         format_number(v.custo_sms, 4), ' reais.'),
  'vt_res_06_valuation'
FROM vt_res_06_valuation v

UNION ALL
SELECT v.grupo, 'E. Valuation da reordenacao', 41, 'Efeito em reais no conjunto observado',
  round(CAST(v.economia_observada AS DOUBLE), 2), 'R$',
  'Valor dos disparos poupados, ou gastos a mais, no recorte que pode ser medido sem suposicao.',
  'Disparos poupados multiplicados pelo custo unitario.',
  'E o resultado mais defensavel deste estudo, porque nao extrapola nada. Compare a magnitude com o bloco de valuation do estudo 1 para dimensionar a importancia relativa da ordem frente a escolha do numero.',
  'Um valor pequeno em relacao ao estudo 1 indica que o ganho do Golden Record esta em acertar o numero, e nao em reordenar tentativas.',
  'vt_res_06_valuation'
FROM vt_res_06_valuation v

UNION ALL
SELECT v.grupo, 'E. Valuation da reordenacao', 42, 'Efeito em reais projetado para o volume total',
  round(CAST(v.economia_projetada AS DOUBLE), 2), 'R$',
  'Extrapolacao do efeito medido para todo o volume de disparos do escopo.',
  'Efeito observado dividido pela fracao de disparos que a simulacao consegue observar.',
  'Assume que os pares nao observados se comportam como os observados, o que e premissa e nao medicao. Use a linha 41 quando precisar de um numero incontestavel e esta quando precisar de ordem de grandeza.',
  concat('A simulacao cobre ', format_number(100.0 * v.fracao_disparos, 2),
         ' por cento do volume, e a projecao escala o resultado por esse fator.'),
  'vt_res_06_valuation'
FROM vt_res_06_valuation v
;


/* -----------------------------------------------------------------------------
   08.1  SAÍDA DO ESTUDO 2
----------------------------------------------------------------------------- */
SELECT
  grupo,
  bloco,
  ordem,
  indicador,
  valor,
  unidade,
  definicao,
  calculo,
  interpretacao,
  exemplo,
  origem
FROM vt_res_08_resumo
ORDER BY grupo, ordem
;
