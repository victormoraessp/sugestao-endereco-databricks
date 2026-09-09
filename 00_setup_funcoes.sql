/* =============================================================================
   VALUATION TELEFONE  |  00_setup_funcoes.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   Cria (1) a tabela de parâmetros e (2) as funções estatísticas auxiliares que
   TODOS os scripts seguintes usam. Rodar UMA vez por sessão, antes dos demais.

   POR QUE PRECISAMOS DISSO
   ------------------------
   O Databricks SQL não tem função nativa de distribuição Normal (CDF), nem de
   intervalo de confiança de proporção. Sem isso não conseguimos entregar
   "p-valor" e "intervalo de 95%", que são exatamente o que dá credibilidade
   estatística ao experimento sem A/B.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   Aqui criamos "calculadoras" reutilizáveis: norm_cdf() transforma
              um z-score em probabilidade; p_valor_bilateral() diz se uma
              diferença pode ser acaso; wilson_inf/sup() dão a faixa em que a
              taxa verdadeira provavelmente está.
   [SÊNIOR]   norm_cdf usa a aproximação de Zelen & Severo (Abramowitz & Stegun
              26.2.17), erro absoluto < 7.5e-8, suficiente para qualquer p-valor
              reportado com 4 casas. Wilson é preferido ao Wald porque não
              "estoura" perto de 0%/100% e funciona em amostras pequenas
              (campanhas de 10-100 envios).
   [EXECUTIVO] Este passo só instala as ferramentas de medição. Nenhum número de
              negócio sai daqui.
   -----------------------------------------------------------------------------
   OBSERVAÇÃO SOBRE TEMPORARY FUNCTION
   Se o seu workspace bloquear CREATE TEMPORARY FUNCTION, troque por
   CREATE OR REPLACE FUNCTION <catalogo>.<schema>.nome(...) e prefixe as
   chamadas nos demais scripts. A lógica é idêntica.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   0.1  PARÂMETROS GLOBAIS (único lugar para ajustar limiares)
   -----------------------------------------------------------------------------
   z_95                          : quantil da Normal para IC de 95%
   min_envios_por_braco_campanha : mínimo de envios em CADA braço (concordante e
                                   discordante) para uma campanha aparecer na
                                   tabela por campanha (script 06). Campanhas
                                   menores NÃO são descartadas da análise
                                   global: entram via CMH (script 03), que pesa
                                   cada campanha pelo seu tamanho.
   min_n_estrato_cmh             : estrato precisa de pelo menos 2 envios e os
                                   dois braços presentes para contribuir no CMH.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_parametros AS
SELECT
  CAST(1.959964 AS DOUBLE) AS z_95,
  CAST(50       AS INT)    AS min_envios_por_braco_campanha,
  CAST(2        AS INT)    AS min_n_estrato_cmh,
  CAST(0.05     AS DOUBLE) AS alpha
;


/* -----------------------------------------------------------------------------
   0.2  CDF DA NORMAL PADRÃO  Φ(x)
   -----------------------------------------------------------------------------
   Aproximação Zelen & Severo: para x >= 0,
     t = 1 / (1 + 0.2316419 x)
     Φ(x) = 1 - φ(x) (b1 t + b2 t^2 + b3 t^3 + b4 t^4 + b5 t^5)
   e Φ(-x) = 1 - Φ(x) por simetria.
   Quebramos em 3 funções porque SQL UDF não permite variáveis locais nem
   recursão; funções podem chamar outras funções.
----------------------------------------------------------------------------- */
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
RETURN
  CASE
    WHEN x IS NULL THEN NULL
    WHEN x >= 0    THEN 1.0 - stat_tail_as(x)
    ELSE                stat_tail_as(x)
  END;


/* -----------------------------------------------------------------------------
   0.3  P-VALORES
   -----------------------------------------------------------------------------
   p_valor_bilateral(z)   : teste z bicaudal  -> 2 * (1 - Φ(|z|))
   p_valor_qui2_1gl(chi2) : qui-quadrado com 1 grau de liberdade. Como
                            χ²(1gl) = Z², o p-valor é 2 * (1 - Φ(sqrt(χ²))).
   Ambos são "quanto menor, mais improvável que a diferença seja acaso".
   Convenção: p < 0.05 = estatisticamente significante.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMPORARY FUNCTION p_valor_bilateral(z DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN z IS NULL THEN NULL ELSE 2.0 * (1.0 - norm_cdf(abs(z))) END;

CREATE OR REPLACE TEMPORARY FUNCTION p_valor_qui2_1gl(chi2 DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN chi2 IS NULL OR chi2 < 0 THEN NULL ELSE 2.0 * (1.0 - norm_cdf(sqrt(chi2))) END;


/* -----------------------------------------------------------------------------
   0.4  INTERVALO DE CONFIANÇA DE WILSON (95%) PARA UMA PROPORÇÃO k/n
   -----------------------------------------------------------------------------
   centro = (p + z²/2n) / (1 + z²/n)
   meia-largura = z * sqrt( p(1-p)/n + z²/4n² ) / (1 + z²/n)
   Vantagem: nunca sai de [0,1] e é confiável mesmo com n pequeno.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMPORARY FUNCTION wilson_inf(k DOUBLE, n DOUBLE)
RETURNS DOUBLE
RETURN
  CASE WHEN n IS NULL OR n <= 0 OR k IS NULL THEN NULL ELSE
    ( (k / n) + (1.959964 * 1.959964) / (2.0 * n)
      - 1.959964 * sqrt( (k / n) * (1.0 - k / n) / n + (1.959964 * 1.959964) / (4.0 * n * n) ) )
    / (1.0 + (1.959964 * 1.959964) / n)
  END;

CREATE OR REPLACE TEMPORARY FUNCTION wilson_sup(k DOUBLE, n DOUBLE)
RETURNS DOUBLE
RETURN
  CASE WHEN n IS NULL OR n <= 0 OR k IS NULL THEN NULL ELSE
    ( (k / n) + (1.959964 * 1.959964) / (2.0 * n)
      + 1.959964 * sqrt( (k / n) * (1.0 - k / n) / n + (1.959964 * 1.959964) / (4.0 * n * n) ) )
    / (1.0 + (1.959964 * 1.959964) / n)
  END;


/* -----------------------------------------------------------------------------
   0.5  TESTE DE SANIDADE DAS FUNÇÕES
   -----------------------------------------------------------------------------
   Valores esperados (tolerância 1e-6):
     norm_cdf(1.959964)         = 0.975
     norm_cdf(-1.959964)        = 0.025
     p_valor_bilateral(1.959964)= 0.050
     p_valor_qui2_1gl(3.841459) = 0.050
     wilson_inf(50,100)         = 0.4038   wilson_sup(50,100) = 0.5962
   Se algum valor divergir, NÃO prossiga: os p-valores dos demais scripts
   estariam errados.
----------------------------------------------------------------------------- */
SELECT
  norm_cdf(1.959964)          AS deve_ser_0_975,
  norm_cdf(-1.959964)         AS deve_ser_0_025,
  p_valor_bilateral(1.959964) AS deve_ser_0_050,
  p_valor_qui2_1gl(3.841459)  AS deve_ser_0_050_qui2,
  wilson_inf(50, 100)         AS deve_ser_0_4038,
  wilson_sup(50, 100)         AS deve_ser_0_5962
;
