/* =============================================================================
   VALUATION TELEFONE  |  02_diagnostico_cobertura.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   Antes de inferir qualquer coisa, mostra o "chão" em que a análise pisa:
     2.1 quantos registros do CRM foram descartados e por quê
     2.2 cobertura do GR (quantos envios / CPFs do CRM têm GR)
     2.3 quanto o CRM já concorda com o GR (e quanto é só formatação)
     2.4 distribuição de tamanho das campanhas (>1000 campanhas, de 10 a 10M)
     2.5 CHECAGEM DE SELEÇÃO: quem tem GR entrega diferente de quem não tem?
     2.6 anatomia das diferenças "só de formato" (nono dígito, DDI)

   POR QUE ISSO IMPORTA
   --------------------
   Toda inferência sem A/B é atacada em dois pontos: "a amostra é
   representativa?" e "os grupos comparados são parecidos?". Este script
   responde o primeiro e prepara o segundo.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   São contagens e percentuais. A pergunta de cada bloco está no
              comentário acima dele. Nada aqui ainda diz se o GR é bom.
   [SÊNIOR]   2.5 é o teste de validade externa: se CPFs com GR já entregam
              muito melhor que CPFs sem GR, o experimento vale para a
              população "com GR" e a extrapolação para o resto precisa de
              cautela explícita. 2.6 protege a conclusão de um erro clássico:
              contar como "telefone diferente" o que é o mesmo número escrito
              de outro jeito.
   [EXECUTIVO] Aqui respondemos "o GR cobre quantos % dos clientes que o CRM
              tenta contatar?" e "o CRM já usa o telefone do GR em quantos %
              dos disparos?". São as duas âncoras do tamanho da oportunidade.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   2.1  QUALIDADE DOS REGISTROS DO CRM
   -----------------------------------------------------------------------------
   Pergunta: quantos registros entram no experimento e quantos saem por
   status ambíguo ou chave inválida?
   Leitura: STATUS_INCONSISTENTE e SEM_STATUS altos indicam problema de carga
   no CRM; não afetam a validade do experimento, mas reduzem sua cobertura.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_qualidade AS
SELECT
  qualidade,
  count(*)                                                 AS registros,
  round(100.0 * count(*) / sum(count(*)) OVER (), 4)       AS pct_registros
FROM vt_crm_envios_qualidade
GROUP BY qualidade
ORDER BY registros DESC
;
SELECT * FROM vt_res_02_qualidade;


/* -----------------------------------------------------------------------------
   2.2  COBERTURA DO GOLDEN RECORD
   -----------------------------------------------------------------------------
   Pergunta: de tudo que o CRM disparou, quanto tem contrafactual no GR?
   Duas granularidades: ENVIO (peso de volume) e CPF (peso de cliente).
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_cobertura AS
SELECT
  'ENVIO' AS grao,
  count(*)                                                 AS total,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)                  AS com_gr,
  round(100.0 * avg(CASE WHEN tem_gr THEN 1 ELSE 0 END), 4) AS pct_com_gr
FROM vt_base_analitica
UNION ALL
SELECT
  'CPF' AS grao,
  count(DISTINCT cpf)                                              AS total,
  count(DISTINCT CASE WHEN tem_gr THEN cpf END)                    AS com_gr,
  round(100.0 * count(DISTINCT CASE WHEN tem_gr THEN cpf END)
              / count(DISTINCT cpf), 4)                            AS pct_com_gr
FROM vt_base_analitica
;
SELECT * FROM vt_res_02_cobertura;


/* -----------------------------------------------------------------------------
   2.3  CONCORDÂNCIA ATUAL ENTRE CRM E GR (universo com GR)
   -----------------------------------------------------------------------------
   Pergunta: hoje, sem usar o GR, o CRM já acerta o telefone do GR em quantos
   % dos envios?  Quanto da "discordância" é só formatação?
   Leitura: DIFERENTE é o espaço em que o GR pode mudar alguma coisa.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_concordancia AS
SELECT
  classe_concordancia,
  count(*)                                              AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (), 4)    AS pct_envios,
  count(DISTINCT cpf)                                   AS cpfs,
  round(100.0 * avg(entregue), 4)                       AS taxa_entrega_pct
FROM vt_experimento
GROUP BY classe_concordancia
ORDER BY envios DESC
;
SELECT * FROM vt_res_02_concordancia;


/* -----------------------------------------------------------------------------
   2.4  DISTRIBUIÇÃO DE TAMANHO DAS CAMPANHAS
   -----------------------------------------------------------------------------
   Pergunta: quantas campanhas há em cada faixa e quanto volume elas carregam?
   Leitura: normalmente poucas campanhas gigantes concentram a maior parte
   dos envios. Por isso o script 03 usa análise ESTRATIFICADA (cada campanha
   pesa pelo seu tamanho) e o 06 testa se o efeito se repete nas faixas.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_faixas_campanha AS
SELECT
  faixa_volume,
  count(*)                                              AS n_campanhas,
  sum(n_envios)                                         AS n_envios,
  round(100.0 * sum(n_envios) / sum(sum(n_envios)) OVER (), 4) AS pct_envios,
  round(100.0 * sum(n_entregues) / sum(n_envios), 4)    AS taxa_entrega_pct,
  round(100.0 * sum(n_com_gr) / sum(n_envios), 4)       AS pct_com_gr,
  sum(CASE WHEN n_concordante > 0 AND n_discordante > 0 THEN 1 ELSE 0 END)
                                                        AS n_campanhas_com_ambos_bracos
FROM vt_campanha_volume
GROUP BY faixa_volume
ORDER BY faixa_volume
;
SELECT * FROM vt_res_02_faixas_campanha;


/* -----------------------------------------------------------------------------
   2.5  CHECAGEM DE SELEÇÃO: CPF com GR  x  CPF sem GR
   -----------------------------------------------------------------------------
   Pergunta: os clientes que TÊM Golden Record já entregam melhor (ou pior)
   que os que não têm, independentemente do telefone usado?
   Por que: o experimento só roda em quem tem GR. Se esse grupo for muito
   diferente do resto, o resultado vale para ele e a extrapolação para os
   demais deve ser declarada como premissa.
   Estatística: teste z de duas proporções + IC de Wilson por grupo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_selecao AS
WITH agg AS (
  SELECT
    sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)                        AS n_com,
    sum(CASE WHEN tem_gr THEN entregue ELSE 0 END)                 AS k_com,
    sum(CASE WHEN NOT tem_gr THEN 1 ELSE 0 END)                    AS n_sem,
    sum(CASE WHEN NOT tem_gr THEN entregue ELSE 0 END)             AS k_sem
  FROM vt_base_analitica
),
calc AS (
  SELECT
    *,
    k_com / nullif(n_com, 0)                     AS p_com,
    k_sem / nullif(n_sem, 0)                     AS p_sem,
    (k_com + k_sem) / (n_com + n_sem) AS p_pool
  FROM agg
),
z AS (
  SELECT
    *,
    CASE WHEN n_sem = 0 THEN NULL ELSE
      (p_com - p_sem) / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n_com, 0) + 1.0 / nullif(n_sem, 0)))
    END AS z_score
  FROM calc
)
SELECT
  n_com                                        AS envios_com_gr,
  round(100.0 * p_com, 4)                      AS taxa_entrega_com_gr_pct,
  round(100.0 * wilson_inf(k_com, n_com), 4)   AS ic95_inf_com_gr_pct,
  round(100.0 * wilson_sup(k_com, n_com), 4)   AS ic95_sup_com_gr_pct,
  n_sem                                        AS envios_sem_gr,
  round(100.0 * p_sem, 4)                      AS taxa_entrega_sem_gr_pct,
  round(100.0 * wilson_inf(k_sem, n_sem), 4)   AS ic95_inf_sem_gr_pct,
  round(100.0 * wilson_sup(k_sem, n_sem), 4)   AS ic95_sup_sem_gr_pct,
  round(100.0 * (p_com - p_sem), 4)            AS diferenca_pp,
  round(z_score, 3)                            AS z,
  p_valor_bilateral(z_score)                   AS p_valor,
  CASE
    WHEN n_sem = 0 THEN 'Sem grupo de comparação: 100% dos envios têm GR.'
    WHEN abs(p_com - p_sem) < 0.02 THEN 'Grupos parecidos (< 2 p.p.): extrapolar para quem não tem GR é razoável.'
    ELSE 'Grupos diferentes: declarar que o resultado vale para a população COM GR.'
  END                                          AS leitura
FROM z
;
SELECT * FROM vt_res_02_selecao;


/* -----------------------------------------------------------------------------
   2.6  ANATOMIA DAS DIFERENÇAS "SÓ DE FORMATO"
   -----------------------------------------------------------------------------
   Pergunta: quando CRM e GR são IGUAL_TOLERANTE mas não IGUAL_EXATO, o que
   difere? Combinação de tamanhos (13 x 12 = nono dígito; 13 x 11 = DDI).
   Leitura: se isso for grande, o GR e o CRM "concordam" mais do que a
   comparação exata sugere, e a regra tolerante é a correta para o negócio.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_formato AS
SELECT
  length(telefone_crm)                                  AS tamanho_crm,
  length(telefone_gr)                                   AS tamanho_gr,
  count(*)                                              AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (), 4)    AS pct
FROM vt_experimento
WHERE classe_concordancia = 'IGUAL_TOLERANTE'
GROUP BY length(telefone_crm), length(telefone_gr)
ORDER BY envios DESC
;
SELECT * FROM vt_res_02_formato;
