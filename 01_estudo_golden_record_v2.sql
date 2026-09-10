/* =============================================================================
   ESTUDO 1  VALOR DO GOLDEN RECORD DE TELEFONE NA ENTREGA DE SMS
   =============================================================================

   PERGUNTA
   O telefone de ranking 1 do Golden Record entrega mais SMS do que o telefone
   que o CRM usa hoje? Se sim, quanto isso vale em reais?

   DESENHO
   Experimento natural. O Golden Record é construído a partir de fontes que não
   alimentam o CRM e não observam o resultado dos disparos. Quando o telefone
   usado pelo CRM coincide com o do Golden Record, a coincidência vem da
   sobreposição de cadastros, e não de uma decisão de quem conhecia o desfecho.
   Isso permite comparar dois grupos cuja formação é independente do resultado.

   ESCOPO DESTE ARQUIVO
   Trabalha apenas com o telefone de ranking 1. A comparação entre as demais
   posições do ranking e a ordem de acionamento do CRM é objeto do estudo 2,
   que consome as tabelas materializadas aqui.

   SAÍDA
   Um único resultado é exibido, o resumo executivo da seção 11. Todos os
   cálculos intermediários ficam disponíveis como views, e podem ser
   consultados individualmente quando houver necessidade de auditoria.

   ESTRUTURA
     00  Parâmetros do experimento e do valuation
     01  Funções estatísticas
     02  Fontes, preparação e materialização
     03  Escopo de campanhas e grupos de análise
     04  Diagnóstico de cobertura
     05  Experimento natural, concordância de telefone
     06  Desenho pareado dentro do mesmo cliente
     07  Contrafactual dos insucessos
     08  Testes de robustez
     09  Valuation pelo custo de disparo
     10  Valuation pela conversão
     11  Aprofundamentos
     12  Resumo executivo

   CONTRATO DE DADOS
   Golden Record, uma linha por CPF e ranking de telefone:
     cpf, ranking, ddi, ddd, telefone, data_ingestao
   Campanhas de SMS do CRM, uma linha por disparo:
     cpf, campanha, telefone_bruto, bol_entregue, bol_nao_entregue
     prioridade_crm é opcional e representa a ordem do slot de telefone no
     cadastro de origem.

   JANELA
   O escopo é o ano de 2025, delimitado pelo filtro de data aplicado na origem
   das campanhas. Os valores do bloco de valuation são, portanto, leitura anual.

   GRÃO DE ANÁLISE
   Um envio é a combinação de CPF, campanha e telefone. Retentativas para o
   mesmo trio são consolidadas em uma única observação.
   ============================================================================= */


/* =============================================================================
   SEÇÃO 00  PARÂMETROS DO EXPERIMENTO E DO VALUATION
   =============================================================================
   Concentra todas as variáveis de decisão. Nenhum número fixo aparece nas
   seções seguintes.

   [JÚNIOR]    Painel de controle. Mudar um valor aqui muda todos os resultados
               abaixo, sem tocar em nenhuma consulta.
   [SÊNIOR]    Separar premissa de lógica mantém a análise auditável e permite
               rodar cenários sem reescrever o pipeline.
   [EXECUTIVO] As três alavancas financeiras do estudo são o custo de disparo,
               a taxa de conversão sobre entregas e o retorno por conversão.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   00.1  DESTINO DAS TABELAS MATERIALIZADAS

   As duas tabelas criadas na seção 02 persistem entre sessões e são a fonte do
   estudo 2. O catálogo e o schema abaixo aparecem em todos os comandos de
   materialização e são o único ponto a ajustar.

   Nomes definidos:
     tb_gr_telefone_ranking   telefones do Golden Record, um por CPF e posição
     tb_crm_envio_analitico   um registro por envio, já cruzado com o Golden Record
----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   00.2  PARÂMETROS GERAIS

   custo_sms         Custo unitário de um disparo, em reais. Incide sobre todo
                     disparo, entregue ou não.
   taxa_conversao    Fração dos SMS entregues que gera a conversão de interesse.
   valor_conversao   Retorno financeiro médio de cada conversão, em reais.
   z_95              Quantil da Normal padrão para intervalos de 95 por cento.
   min_envios_braco  Mínimo de envios em cada braço para uma campanha ser
                     testada isoladamente na seção 08.
   min_n_estrato     Mínimo de envios para um estrato entrar no estimador
                     estratificado da seção 05.
   volume_referencia Volume usado nos exemplos numéricos do resumo executivo,
                     para tornar cada percentual tangível.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param AS
SELECT
  CAST(0.04       AS DOUBLE) AS custo_sms,
  CAST(0.0050     AS DOUBLE) AS taxa_conversao,
  CAST(150.00     AS DOUBLE) AS valor_conversao,
  CAST(1.959964   AS DOUBLE) AS z_95,
  CAST(50         AS INT)    AS min_envios_braco,
  CAST(2          AS INT)    AS min_n_estrato,
  CAST(0.05       AS DOUBLE) AS alpha,
  CAST(1000000    AS BIGINT) AS volume_referencia
;


/* -----------------------------------------------------------------------------
   00.3  GRUPOS DE CAMPANHAS

   Define até três recortes analisados em paralelo. Cada grupo produz sua
   própria linha no resumo executivo, e o rótulo TOTAL consolida o conjunto.

   REGRA DE ESCOPO
     Com ao menos um grupo preenchido, a análise roda apenas sobre as campanhas
     informadas, e TOTAL é a união delas.
     Com os três grupos vazios, a análise roda sobre a base completa sob o
     rótulo TOTAL. Essa é a configuração padrão.

   COMO INFORMAR
     campanhas        vetor de nomes, por exemplo array('CAMPANHA_A', 'CAMPANHA_B')
     campanhas_texto  nomes separados por vírgula, por exemplo 'CAMPANHA_A, CAMPANHA_B'
   O vetor tem precedência. Espaços em volta dos nomes são removidos e nomes
   repetidos desconsiderados. Nulo, vetor vazio ou texto em branco desligam o
   grupo sem gerar erro.

   taxa_conversao_grupo e valor_conversao_grupo permitem premissas financeiras
   distintas por recorte. Nulas, valem os parâmetros gerais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param_grupos AS
SELECT
  'GRUPO_1'                   AS grupo,
  'Recorte 1'                 AS descricao,
  CAST(NULL AS ARRAY<STRING>) AS campanhas,
  CAST(NULL AS STRING)        AS campanhas_texto,
  CAST(NULL AS DOUBLE)        AS taxa_conversao_grupo,
  CAST(NULL AS DOUBLE)        AS valor_conversao_grupo
UNION ALL
SELECT 'GRUPO_2', 'Recorte 2', CAST(NULL AS ARRAY<STRING>), CAST(NULL AS STRING),
       CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE)
UNION ALL
SELECT 'GRUPO_3', 'Recorte 3', CAST(NULL AS ARRAY<STRING>), CAST(NULL AS STRING),
       CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE)
;


/* -----------------------------------------------------------------------------
   00.4  GRADE DE SENSIBILIDADE DO VALUATION

   Multiplicadores aplicados sobre a taxa de conversão e sobre o valor por
   conversão. A combinação de um por um reproduz os parâmetros gerais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param_sensibilidade AS
SELECT
  m_taxa.mult    AS mult_taxa,
  m_taxa.rotulo  AS rotulo_taxa,
  m_valor.mult   AS mult_valor,
  m_valor.rotulo AS rotulo_valor
FROM (
  SELECT * FROM VALUES
    (CAST(0.50 AS DOUBLE), 'conversao_metade'),
    (CAST(1.00 AS DOUBLE), 'conversao_base'),
    (CAST(2.00 AS DOUBLE), 'conversao_dobro')
  AS t(mult, rotulo)
) m_taxa
CROSS JOIN (
  SELECT * FROM VALUES
    (CAST(0.50 AS DOUBLE), 'ticket_metade'),
    (CAST(1.00 AS DOUBLE), 'ticket_base'),
    (CAST(2.00 AS DOUBLE), 'ticket_dobro')
  AS t(mult, rotulo)
) m_valor
;


/* =============================================================================
   SEÇÃO 01  FUNÇÕES ESTATÍSTICAS
   =============================================================================
   O motor não expõe nativamente a distribuição Normal acumulada nem intervalos
   de confiança de proporção.

   REGRA DE USO
   Nenhuma destas funções pode ser chamada dentro de round. A expansão de uma
   função SQL dentro de uma expressão arredondada reescreve a expressão em uma
   projeção intermediária e o literal das casas decimais deixa de ser
   reconhecido como constante, o que faz a consulta ser recusada. Sempre que um
   valor produzido por estas funções precisa ser arredondado, ele é calculado
   em uma etapa anterior, com resultado nomeado, e arredondado na etapa
   seguinte.
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
   SEÇÃO 02  FONTES, PREPARAÇÃO E MATERIALIZAÇÃO
   =============================================================================
   Constrói a base do estudo e a persiste em duas tabelas. A persistência tem
   três objetivos: evitar recalcular joins pesados a cada consulta, congelar o
   recorte analisado para que os números do relatório sejam reproduzíveis, e
   servir de insumo ao estudo 2 sem repetir o processamento.

   [JÚNIOR]    Organizar o Golden Record com um telefone por CPF e posição,
               limpar a base do CRM e juntar as duas por CPF.
   [SÊNIOR]    A comparação de telefones acontece em dois níveis. O exato
               compara a string completa. O tolerante compara área mais os oito
               dígitos finais, neutralizando nono dígito e código de país. O CPF
               é normalizado antes da deduplicação do Golden Record, e não
               depois, para que duas grafias do mesmo documento não gerem dois
               registros de ranking 1.
   [EXECUTIVO] Para cada SMS enviado passa a ser possível responder se ele foi
               para o telefone recomendado e se chegou ao destino.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   02.1  FONTES DE DADOS E NORMALIZAÇÃO DE NOMES

   Único ponto de contato com as tabelas de origem. Cada coluna é renomeada aqui
   para o nome canônico usado no restante do arquivo. Para apontar o estudo para
   outras tabelas, altere o nome da tabela no FROM e a expressão à esquerda de
   cada AS.

   NOMES CANÔNICOS DO GOLDEN RECORD
     cpf            identificador do cliente, em qualquer formatação
     ranking        posição de qualidade do telefone, sendo 1 a melhor
     ddi            código do país
     ddd            código de área
     telefone       número sem país e sem área
     data_ingestao  momento da carga, usado para escolher o registro mais
                    recente quando há mais de um para o mesmo cpf e ranking.
                    Precisa apenas ser ordenável.

   NOMES CANÔNICOS DAS CAMPANHAS DE SMS
     cpf               identificador do cliente, em qualquer formatação
     campanha          identificador da campanha
     telefone_bruto    país, área e número concatenados
     bol_entregue      indicador de entrega
     bol_nao_entregue  indicador de falha de entrega
     data_ingestao_crm momento em que o registro do disparo entrou na base.
                       Delimita a janela do estudo e permite verificar se a
                       recomendação do Golden Record já existia quando a
                       campanha ocorreu.
     prioridade_crm    ordem do slot de telefone no cadastro de origem. Campo
                       opcional. Sem esse dado, o valor permanece nulo e a ordem
                       é inferida pelo padrão de uso do número.

   FILTROS APLICADOS NA ORIGEM DAS CAMPANHAS
     recebimento       descarta as mensagens recebidas dos clientes, mantendo
                       apenas os disparos enviados pela operação. Sem esse
                       filtro, respostas de clientes entrariam no denominador e
                       distorceriam a taxa de entrega.
     data_ingestao     restringe o estudo ao ano de 2025, entre o primeiro de
                       janeiro inclusive e o primeiro de janeiro de 2026
                       exclusive. Com a janela fechada em doze meses, os valores
                       do bloco de valuation passam a ser leitura anual.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_fonte_golden_record AS
SELECT
  cpf                AS cpf,
  ranking            AS ranking,
  ddi                AS ddi,
  ddd                AS ddd,
  telefone           AS telefone,
  data_ingestao      AS data_ingestao
FROM temp_view_golden_record
;

CREATE OR REPLACE TEMP VIEW vt_fonte_crm_sms AS
SELECT
  cpf                AS cpf,
  campanha           AS campanha,
  telefone_bruto     AS telefone_bruto,
  bol_entregue       AS bol_entregue,
  bol_nao_entregue   AS bol_nao_entregue,
  data_ingestao      AS data_ingestao_crm,
  CAST(NULL AS INT)  AS prioridade_crm
FROM temp_view_crm_sms
WHERE 1 = 1
  AND coalesce(CAST(recebimento AS BOOLEAN), FALSE) = FALSE
  AND to_date(data_ingestao) >= '2025-01-01'
  AND to_date(data_ingestao) <  '2026-01-01'
;


/* -----------------------------------------------------------------------------
   02.2  GOLDEN RECORD, UM TELEFONE POR CPF E POSIÇÃO

   telefone_gr  país, área e número concatenados, apenas dígitos
   chave_gr     área e oito dígitos finais, usada na comparação tolerante

   O estudo 1 usa apenas a posição 1. As demais posições são preservadas porque
   o estudo 2 as consome.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_ranking_calc AS
WITH normalizado AS (
  SELECT
    lpad(regexp_replace(CAST(cpf AS STRING), '[^0-9]', ''), 11, '0')           AS cpf,
    CAST(int(ranking) AS INT)                                                  AS ranking,
    regexp_replace(
      concat(CAST(int(ddi) AS STRING), CAST(int(ddd) AS STRING), telefone),
      '[^0-9]', '')                                                            AS telefone_gr,
    CAST(int(ddd) AS STRING)                                                   AS ddd_gr,
    concat(CAST(int(ddd) AS STRING), '-',
           right(regexp_replace(CAST(telefone AS STRING), '[^0-9]', ''), 8))   AS chave_gr,
    data_ingestao
  FROM vt_fonte_golden_record
  WHERE ranking IS NOT NULL
    AND telefone IS NOT NULL
)
SELECT
  cpf,
  ranking,
  telefone_gr,
  ddd_gr,
  chave_gr,
  data_ingestao AS data_ingestao_gr
FROM normalizado
QUALIFY row_number() OVER (PARTITION BY cpf, ranking ORDER BY data_ingestao DESC) = 1
;


/* -----------------------------------------------------------------------------
   02.3  MATERIALIZAÇÃO DO GOLDEN RECORD
----------------------------------------------------------------------------- */
DROP TABLE IF EXISTS catalogo.schema.tb_gr_telefone_ranking;

CREATE TABLE catalogo.schema.tb_gr_telefone_ranking
CLUSTER BY AUTO
AS SELECT * FROM vt_gr_ranking_calc;

CREATE OR REPLACE TEMP VIEW tb_gr_telefone_ranking AS
SELECT * FROM catalogo.schema.tb_gr_telefone_ranking;

CREATE OR REPLACE TEMP VIEW vt_gr_rank1 AS
SELECT cpf, telefone_gr, ddd_gr, chave_gr, data_ingestao_gr
FROM tb_gr_telefone_ranking
WHERE ranking = 1
;

CREATE OR REPLACE TEMP VIEW vt_gr_profundidade_cpf AS
SELECT
  cpf,
  count(*)                    AS rankings_disponiveis,
  max(ranking)                AS ranking_maximo,
  count(DISTINCT telefone_gr) AS telefones_distintos
FROM tb_gr_telefone_ranking
GROUP BY cpf
;


/* -----------------------------------------------------------------------------
   02.4  CRM, NORMALIZAÇÃO E QUALIDADE

   entregue assume 1 quando o registro indica entrega, 0 quando indica falha e
   nulo quando os dois indicadores se contradizem ou estão ambos ausentes.
   Apenas registros classificados como OK entram no estudo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios_raw AS
WITH base AS (
  SELECT
    lpad(regexp_replace(CAST(cpf AS STRING), '[^0-9]', ''), 11, '0')  AS cpf,
    CAST(campanha AS STRING)                                          AS campanha,
    regexp_replace(CAST(telefone_bruto AS STRING), '[^0-9]', '')      AS telefone_crm,
    coalesce(CAST(bol_entregue     AS BOOLEAN), false)                AS flag_entregue,
    coalesce(CAST(bol_nao_entregue AS BOOLEAN), false)                AS flag_nao_entregue,
    to_date(data_ingestao_crm)                                        AS data_disparo,
    CAST(prioridade_crm AS INT)                                       AS prioridade_crm
  FROM vt_fonte_crm_sms
),
sem_pais AS (
  SELECT
    *,
    CASE WHEN length(telefone_crm) >= 12 AND telefone_crm LIKE '55%'
         THEN substr(telefone_crm, 3)
         ELSE telefone_crm END AS telefone_crm_local
  FROM base
)
SELECT
  cpf, campanha, telefone_crm, flag_entregue, flag_nao_entregue, data_disparo, prioridade_crm,
  left(telefone_crm_local, 2)                                            AS ddd_crm,
  concat(left(telefone_crm_local, 2), '-', right(telefone_crm_local, 8)) AS chave_crm
FROM sem_pais
;

CREATE OR REPLACE TEMP VIEW vt_crm_envios_qualidade AS
SELECT
  *,
  CASE
    WHEN cpf IS NULL OR cpf = '00000000000' OR length(cpf) <> 11 THEN 'SEM_CPF'
    WHEN telefone_crm IS NULL OR length(telefone_crm) < 10       THEN 'SEM_TELEFONE'
    WHEN flag_entregue AND flag_nao_entregue                     THEN 'STATUS_INCONSISTENTE'
    WHEN NOT flag_entregue AND NOT flag_nao_entregue             THEN 'SEM_STATUS'
    ELSE 'OK'
  END AS qualidade,
  CASE
    WHEN flag_entregue AND NOT flag_nao_entregue THEN 1
    WHEN flag_nao_entregue AND NOT flag_entregue THEN 0
    ELSE NULL
  END AS entregue
FROM vt_crm_envios_raw
;


/* -----------------------------------------------------------------------------
   02.5  ORDEM DE ACIONAMENTO DOS TELEFONES NO CRM

   Coluna calculada aqui para servir ao estudo 2, que compara a ordem do CRM
   com a ordem do Golden Record. O estudo 1 não a utiliza.

   Quando prioridade_crm está preenchida, ela é respeitada. Sem esse campo, a
   ordem é inferida pelo padrão de uso: o telefone acionado no maior número de
   campanhas do CPF é tratado como principal. O desempate final é o próprio
   número, o que torna a ordem reprodutível.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_perfil_telefone AS
WITH agg AS (
  SELECT
    cpf,
    telefone_crm,
    min(prioridade_crm)      AS prioridade_declarada,
    count(DISTINCT campanha) AS campanhas_com_uso,
    count(*)                 AS envios_totais
  FROM vt_crm_envios_qualidade
  WHERE qualidade = 'OK'
  GROUP BY cpf, telefone_crm
)
SELECT
  *,
  CASE WHEN row_number() OVER (
         PARTITION BY cpf
         ORDER BY campanhas_com_uso DESC, envios_totais DESC, telefone_crm ASC) = 1
       THEN 1 ELSE 0 END AS telefone_mais_acionado
FROM agg
;

CREATE OR REPLACE TEMP VIEW vt_crm_envios AS
WITH consolidado AS (
  SELECT
    cpf, campanha, telefone_crm, ddd_crm, chave_crm,
    max(entregue)      AS entregue,
    count(*)           AS registros_originais,
    min(data_disparo)  AS data_disparo,
    max(data_disparo)  AS data_disparo_ultima
  FROM vt_crm_envios_qualidade
  WHERE qualidade = 'OK'
  GROUP BY cpf, campanha, telefone_crm, ddd_crm, chave_crm
)
SELECT
  c.cpf,
  c.campanha,
  c.telefone_crm,
  c.ddd_crm,
  c.chave_crm,
  c.entregue,
  c.registros_originais,
  c.data_disparo,
  c.data_disparo_ultima,
  coalesce(p.telefone_mais_acionado, 0) AS heuristica_mais_acionado,
  dense_rank() OVER (
    PARTITION BY c.cpf, c.campanha
    ORDER BY coalesce(p.prioridade_declarada, 9999) ASC,
             p.campanhas_com_uso DESC,
             p.envios_totais DESC,
             c.telefone_crm ASC
  ) AS ranking_crm,
  count(*) OVER (PARTITION BY c.cpf, c.campanha) AS telefones_na_campanha
FROM consolidado c
LEFT JOIN vt_crm_perfil_telefone p
  ON c.cpf = p.cpf AND c.telefone_crm = p.telefone_crm
;


/* -----------------------------------------------------------------------------
   02.6  BASE ANALÍTICA

   Um envio por linha, com o telefone de ranking 1 ao lado e a classificação de
   concordância.

   classe_concordancia
     SEM_GR           CPF ausente do Golden Record, sem contrafactual possível
     IGUAL_EXATO      o CRM usou exatamente o telefone de ranking 1
     IGUAL_TOLERANTE  mesmo número, com diferença apenas de formatação
     DIFERENTE        o Golden Record indicaria outro telefone

   ranking_gr_do_telefone_usado informa em que posição do Golden Record está o
   número que o CRM de fato usou. Fica nulo quando o número não aparece em
   nenhuma posição. Assim como ranking_crm, é insumo do estudo 2.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_base_calc AS
WITH com_rank1 AS (
  SELECT
    e.cpf,
    e.campanha,
    e.telefone_crm,
    e.chave_crm,
    e.entregue,
    e.registros_originais,
    e.data_disparo,
    e.data_disparo_ultima,
    e.ddd_crm,
    e.heuristica_mais_acionado,
    e.ranking_crm,
    e.telefones_na_campanha,
    g.telefone_gr,
    g.ddd_gr,
    g.chave_gr,
    g.data_ingestao_gr,
    (g.cpf IS NOT NULL)                    AS tem_gr,
    coalesce(prof.rankings_disponiveis, 0) AS rankings_disponiveis
  FROM vt_crm_envios e
  LEFT JOIN vt_gr_rank1 g               ON e.cpf = g.cpf
  LEFT JOIN vt_gr_profundidade_cpf prof ON e.cpf = prof.cpf
),
com_posicao AS (
  SELECT
    c.*,
    t.ranking AS ranking_gr_do_telefone_usado
  FROM com_rank1 c
  LEFT JOIN tb_gr_telefone_ranking t
    ON c.cpf = t.cpf
   AND (c.telefone_crm = t.telefone_gr OR c.chave_crm = t.chave_gr)
  QUALIFY row_number() OVER (
    PARTITION BY c.cpf, c.campanha, c.telefone_crm
    ORDER BY t.ranking ASC NULLS LAST
  ) = 1
)
SELECT
  *,
  CASE
    WHEN NOT tem_gr                 THEN 'SEM_GR'
    WHEN telefone_crm = telefone_gr THEN 'IGUAL_EXATO'
    WHEN chave_crm    = chave_gr    THEN 'IGUAL_TOLERANTE'
    ELSE                                 'DIFERENTE'
  END AS classe_concordancia,
  CASE
    WHEN NOT tem_gr THEN NULL
    WHEN telefone_crm = telefone_gr OR chave_crm = chave_gr THEN 1
    ELSE 0
  END AS concordante,
  CASE
    WHEN NOT tem_gr THEN NULL
    WHEN telefone_crm = telefone_gr THEN 1
    ELSE 0
  END AS concordante_exato
FROM com_posicao
;


/* -----------------------------------------------------------------------------
   02.7  MATERIALIZAÇÃO DA BASE ANALÍTICA
----------------------------------------------------------------------------- */
DROP TABLE IF EXISTS catalogo.schema.tb_crm_envio_analitico;

CREATE TABLE catalogo.schema.tb_crm_envio_analitico
CLUSTER BY AUTO
AS SELECT * FROM vt_base_calc;

CREATE OR REPLACE TEMP VIEW tb_crm_envio_analitico AS
SELECT * FROM catalogo.schema.tb_crm_envio_analitico;


/* =============================================================================
   SEÇÃO 03  ESCOPO DE CAMPANHAS E GRUPOS DE ANÁLISE
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_grupo_lista AS
SELECT
  grupo,
  descricao,
  taxa_conversao_grupo,
  valor_conversao_grupo,
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
contagem AS (
  SELECT count(*) AS listadas FROM definido
),
universo AS (
  SELECT DISTINCT campanha FROM tb_crm_envio_analitico
),
total_sem_lista AS (
  SELECT 'TOTAL' AS grupo, u.campanha
  FROM universo u CROSS JOIN contagem c
  WHERE c.listadas = 0
),
total_com_lista AS (
  SELECT DISTINCT 'TOTAL' AS grupo, campanha FROM definido
)
SELECT grupo, campanha FROM definido
UNION ALL SELECT grupo, campanha FROM total_com_lista
UNION ALL SELECT grupo, campanha FROM total_sem_lista
;

CREATE OR REPLACE TEMP VIEW vt_grupo_param AS
SELECT
  g.grupo,
  g.descricao,
  coalesce(g.taxa_conversao_grupo,  p.taxa_conversao)  AS taxa_conversao,
  coalesce(g.valor_conversao_grupo, p.valor_conversao) AS valor_conversao,
  p.custo_sms,
  p.volume_referencia
FROM vt_grupo_lista g
CROSS JOIN vt_param p
WHERE g.campanhas IS NOT NULL AND size(g.campanhas) > 0
UNION ALL
SELECT
  'TOTAL',
  'Consolidado das campanhas em escopo',
  p.taxa_conversao,
  p.valor_conversao,
  p.custo_sms,
  p.volume_referencia
FROM vt_param p
;

CREATE OR REPLACE TEMP VIEW vt_base_grupo AS
SELECT g.grupo, b.*
FROM tb_crm_envio_analitico b
JOIN vt_grupo_campanha g ON b.campanha = g.campanha
;

CREATE OR REPLACE TEMP VIEW vt_experimento AS
SELECT * FROM vt_base_grupo WHERE tem_gr
;

CREATE OR REPLACE TEMP VIEW vt_campanha_volume AS
SELECT
  grupo,
  campanha,
  count(*)                                         AS n_envios,
  sum(entregue)                                    AS n_entregues,
  avg(entregue)                                    AS taxa_entrega,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)          AS n_com_gr,
  sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END) AS n_concordante,
  sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END) AS n_discordante,
  CASE
    WHEN count(*) <      100 THEN '1. ate 100'
    WHEN count(*) <     1000 THEN '2. 100 a 1 mil'
    WHEN count(*) <    10000 THEN '3. 1 mil a 10 mil'
    WHEN count(*) <   100000 THEN '4. 10 mil a 100 mil'
    WHEN count(*) <  1000000 THEN '5. 100 mil a 1 milhao'
    ELSE                          '6. acima de 1 milhao'
  END                                              AS faixa_volume
FROM vt_base_grupo
GROUP BY grupo, campanha
;


/* =============================================================================
   SEÇÃO 04  DIAGNÓSTICO DE COBERTURA
   =============================================================================
   Mede o terreno antes de qualquer inferência: quanto o Golden Record alcança,
   quanto o CRM já concorda com ele e se o grupo estudado é comparável ao
   restante da base.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_04_volume AS
SELECT
  grupo,
  count(*)                                        AS disparos,
  count(DISTINCT cpf)                             AS clientes,
  count(DISTINCT campanha)                        AS campanhas,
  sum(entregue)                                   AS entregas,
  count(*) - sum(entregue)                        AS insucessos,
  avg(entregue)                                   AS taxa_entrega,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)         AS disparos_com_gr,
  avg(CASE WHEN tem_gr THEN 1 ELSE 0 END)         AS cobertura_disparo,
  count(DISTINCT CASE WHEN tem_gr THEN cpf END)   AS clientes_com_gr,
  count(DISTINCT CASE WHEN tem_gr THEN cpf END)
    / nullif(count(DISTINCT cpf), 0)              AS cobertura_cliente
FROM vt_base_grupo
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_04_concordancia AS
SELECT
  grupo,
  classe_concordancia,
  count(*)                                                   AS envios,
  count(*) / sum(count(*)) OVER (PARTITION BY grupo)         AS fracao_envios,
  count(DISTINCT cpf)                                        AS cpfs,
  avg(entregue)                                              AS taxa_entrega
FROM vt_experimento
GROUP BY grupo, classe_concordancia
;

CREATE OR REPLACE TEMP VIEW vt_res_04_anatomia_insucesso AS
SELECT
  grupo,
  count(*)                                                                    AS insucessos,
  sum(CASE WHEN NOT tem_gr THEN 1 ELSE 0 END)                                 AS sem_gr,
  sum(CASE WHEN classe_concordancia IN ('IGUAL_EXATO','IGUAL_TOLERANTE')
           THEN 1 ELSE 0 END)                                                 AS gr_igual,
  sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)          AS gr_diferente,
  sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)
    / nullif(sum(CASE WHEN tem_gr THEN 1 ELSE 0 END), 0)                      AS fracao_sobre_com_gr
FROM vt_base_grupo
WHERE entregue = 0
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_04_selecao AS
WITH agg AS (
  SELECT
    grupo,
    sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)            AS n_com,
    sum(CASE WHEN tem_gr THEN entregue ELSE 0 END)     AS k_com,
    sum(CASE WHEN NOT tem_gr THEN 1 ELSE 0 END)        AS n_sem,
    sum(CASE WHEN NOT tem_gr THEN entregue ELSE 0 END) AS k_sem
  FROM vt_base_grupo
  GROUP BY grupo
),
calc AS (
  SELECT
    *,
    k_com / nullif(n_com, 0)                   AS p_com,
    k_sem / nullif(n_sem, 0)                   AS p_sem,
    (k_com + k_sem) / nullif(n_com + n_sem, 0) AS p_pool
  FROM agg
)
SELECT
  grupo,
  n_com AS envios_com_gr,
  n_sem AS envios_sem_gr,
  p_com AS taxa_com_gr,
  p_sem AS taxa_sem_gr,
  p_com - p_sem AS diferenca,
  CASE WHEN n_sem > 0 AND n_com > 0 AND p_pool NOT IN (0, 1)
       THEN (p_com - p_sem)
            / sqrt(p_pool * (1 - p_pool)
                   * (1.0 / nullif(n_com, 0) + 1.0 / nullif(n_sem, 0)))
  END AS z_score
FROM calc
;


/* =============================================================================
   SEÇÃO 05  EXPERIMENTO NATURAL, CONCORDÂNCIA DE TELEFONE
   =============================================================================
   Compara a entrega quando o CRM usou, por coincidência, o telefone de ranking
   1 do Golden Record contra quando usou outro número.

   A ressalva honesta do desenho é que clientes cujos telefones coincidem entre
   fontes independentes podem ter cadastro mais estável. As seções 05.2, 06 e 08
   atacam essa ressalva controlando por campanha, por pessoa e por recortes
   alternativos.

   As views desta seção guardam valores brutos, em fração. O arredondamento
   acontece apenas no resumo executivo.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_05_bruto AS
WITH agg AS (
  SELECT
    grupo,
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)        AS n1,
    sum(CASE WHEN concordante = 1 THEN entregue ELSE 0 END) AS k1,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)        AS n0,
    sum(CASE WHEN concordante = 0 THEN entregue ELSE 0 END) AS k0
  FROM vt_experimento
  GROUP BY grupo
),
calc AS (
  SELECT
    *,
    k1 / nullif(n1, 0)             AS p1,
    k0 / nullif(n0, 0)             AS p0,
    (k1 + k0) / nullif(n1 + n0, 0) AS p_pool
  FROM agg
),
z AS (
  SELECT
    *,
    (p1 - p0) / sqrt(p_pool * (1 - p_pool)
                     * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))      AS z_score,
    sqrt(p1 * (1 - p1) / nullif(n1, 0) + p0 * (1 - p0) / nullif(n0, 0))  AS se_diff
  FROM calc
)
SELECT
  z.*,
  wilson_inf(z.k1, z.n1) AS ic_inf_conc,
  wilson_sup(z.k1, z.n1) AS ic_sup_conc,
  wilson_inf(z.k0, z.n0) AS ic_inf_disc,
  wilson_sup(z.k0, z.n0) AS ic_sup_disc,
  z.p1 - z.p0            AS diferenca,
  (z.k1 / nullif(z.n1 - z.k1, 0))
    / nullif(z.k0 / nullif(z.n0 - z.k0, 0), 0) AS odds_ratio_bruta,
  p_valor_bilateral(z.z_score)                 AS p_valor
FROM z
;


/* -----------------------------------------------------------------------------
   05.2  ESTIMADOR ESTRATIFICADO POR CAMPANHA

   Cochran, Mantel e Haenszel. Refaz a comparação dentro de cada campanha e
   combina, ponderando pelo tamanho do estrato. Neutraliza qualquer diferença
   entre campanhas, como período, mensagem e público.

   O intervalo da razão de chances usa a variância de Robins, Breslow e
   Greenland, consistente tanto para poucos estratos grandes quanto para muitos
   estratos pequenos.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_estratos_campanha AS
SELECT
  grupo,
  campanha,
  CAST(sum(CASE WHEN concordante = 1 AND entregue = 1 THEN 1 ELSE 0 END) AS DOUBLE) AS a,
  CAST(sum(CASE WHEN concordante = 1 AND entregue = 0 THEN 1 ELSE 0 END) AS DOUBLE) AS b,
  CAST(sum(CASE WHEN concordante = 0 AND entregue = 1 THEN 1 ELSE 0 END) AS DOUBLE) AS c,
  CAST(sum(CASE WHEN concordante = 0 AND entregue = 0 THEN 1 ELSE 0 END) AS DOUBLE) AS d
FROM vt_experimento
GROUP BY grupo, campanha
;

CREATE OR REPLACE TEMP VIEW vt_res_05_estratificado AS
WITH s AS (
  SELECT
    e.*,
    a + b AS n1, c + d AS n0, a + c AS m1, b + d AS m0, a + b + c + d AS n
  FROM vt_estratos_campanha e
  CROSS JOIN vt_param p
  WHERE a + b > 0 AND c + d > 0 AND a + b + c + d >= p.min_n_estrato
),
t AS (
  SELECT
    *,
    n1 * m1 / n                           AS e_a,
    n1 * n0 * m1 * m0 / (n * n * (n - 1)) AS v_a,
    a * d / n                             AS r_k,
    b * c / n                             AS s_k,
    (a + d) / n                           AS p_k,
    (b + c) / n                           AS q_k,
    n1 * n0 / n                           AS w_rd,
    (a / n1) - (c / n0)                   AS rd_k
  FROM s
),
agg AS (
  SELECT
    grupo,
    count(*)                                AS n_estratos,
    sum(n)                                  AS n_envios,
    sum(a)                                  AS soma_a,
    sum(e_a)                                AS soma_e_a,
    sum(v_a)                                AS soma_v_a,
    sum(r_k)                                AS soma_r,
    sum(s_k)                                AS soma_s,
    sum(p_k * r_k)                          AS soma_pr,
    sum(p_k * s_k + q_k * r_k)              AS soma_ps_qr,
    sum(q_k * s_k)                          AS soma_qs,
    sum(w_rd * rd_k) / nullif(sum(w_rd), 0) AS rd_mh
  FROM t
  GROUP BY grupo
),
calc AS (
  SELECT
    *,
    soma_r / nullif(soma_s, 0)                        AS or_mh,
    power(soma_a - soma_e_a, 2) / nullif(soma_v_a, 0) AS chi2,
    soma_pr / nullif(2 * soma_r * soma_r, 0)
      + soma_ps_qr / nullif(2 * soma_r * soma_s, 0)
      + soma_qs / nullif(2 * soma_s * soma_s, 0)      AS var_ln_or
  FROM agg
)
SELECT
  grupo,
  n_estratos                                       AS campanhas_no_teste,
  CAST(n_envios AS BIGINT)                         AS envios_no_teste,
  rd_mh                                            AS diferenca,
  or_mh                                            AS odds_ratio,
  exp(ln(or_mh) - 1.959964 * sqrt(var_ln_or))      AS or_ic_inf,
  exp(ln(or_mh) + 1.959964 * sqrt(var_ln_or))      AS or_ic_sup,
  chi2,
  p_valor_qui2_1gl(chi2)                           AS p_valor
FROM calc
;

CREATE OR REPLACE TEMP VIEW vt_taxa_por_campanha AS
SELECT
  grupo,
  campanha,
  a + b                                    AS n_concordante,
  CASE WHEN a + b > 0 THEN a / (a + b) END AS taxa_concordante,
  c + d                                    AS n_discordante,
  CASE WHEN c + d > 0 THEN c / (c + d) END AS taxa_discordante
FROM vt_estratos_campanha
;


/* =============================================================================
   SEÇÃO 06  DESENHO PAREADO DENTRO DO MESMO CLIENTE
   =============================================================================
   Compara o mesmo CPF consigo mesmo, em um momento com o telefone do Golden
   Record e em outro com um número diferente. Qualquer característica fixa da
   pessoa é idêntica nos dois lados, e o que resta como explicação da diferença
   é o telefone.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_pareado_cpf AS
WITH por_cpf AS (
  SELECT
    grupo,
    cpf,
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END) AS n_conc,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END) AS n_disc,
    avg(CASE WHEN concordante = 1 THEN entregue END) AS taxa_conc,
    avg(CASE WHEN concordante = 0 THEN entregue END) AS taxa_disc
  FROM vt_experimento
  GROUP BY grupo, cpf
)
SELECT * FROM por_cpf WHERE n_conc > 0 AND n_disc > 0
;

CREATE OR REPLACE TEMP VIEW vt_pareado_um_por_braco AS
WITH selecionado AS (
  SELECT e.grupo, e.cpf, e.concordante, e.entregue
  FROM vt_experimento e
  JOIN vt_pareado_cpf p ON e.grupo = p.grupo AND e.cpf = p.cpf
  QUALIFY row_number() OVER (
    PARTITION BY e.grupo, e.cpf, e.concordante
    ORDER BY xxhash64(e.cpf, e.campanha, e.telefone_crm)
  ) = 1
)
SELECT
  grupo,
  cpf,
  max(CASE WHEN concordante = 1 THEN entregue END) AS entregue_gr,
  max(CASE WHEN concordante = 0 THEN entregue END) AS entregue_outro
FROM selecionado
GROUP BY grupo, cpf
;

CREATE OR REPLACE TEMP VIEW vt_res_06_pareado AS
WITH tab AS (
  SELECT
    grupo,
    count(*)                                                                AS n_pares,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS ambos,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS so_gr,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS so_outro,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS nenhum,
    avg(entregue_gr)                                                        AS taxa_gr,
    avg(entregue_outro)                                                     AS taxa_outro
  FROM vt_pareado_um_por_braco
  GROUP BY grupo
)
SELECT
  *,
  taxa_gr - taxa_outro AS diferenca,
  CASE WHEN so_gr + so_outro > 0
       THEN power(so_gr - so_outro, 2) / (so_gr + so_outro) END AS chi2,
  p_valor_qui2_1gl(
    CASE WHEN so_gr + so_outro > 0
         THEN power(so_gr - so_outro, 2) / (so_gr + so_outro) END)          AS p_valor
FROM tab
;

CREATE OR REPLACE TEMP VIEW vt_res_06_mesma_campanha AS
WITH pares AS (
  SELECT
    grupo, cpf, campanha,
    max(CASE WHEN concordante = 1 THEN entregue END) AS entregue_gr,
    max(CASE WHEN concordante = 0 THEN entregue END) AS entregue_outro
  FROM vt_experimento
  GROUP BY grupo, cpf, campanha
  HAVING max(CASE WHEN concordante = 1 THEN 1 ELSE 0 END) = 1
     AND max(CASE WHEN concordante = 0 THEN 1 ELSE 0 END) = 1
),
tab AS (
  SELECT
    grupo,
    count(*)                                                                AS n_pares,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS so_gr,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS so_outro,
    avg(entregue_gr)                                                        AS taxa_gr,
    avg(entregue_outro)                                                     AS taxa_outro
  FROM pares
  GROUP BY grupo
)
SELECT
  *,
  taxa_gr - taxa_outro AS diferenca,
  p_valor_qui2_1gl(
    CASE WHEN so_gr + so_outro > 0
         THEN power(so_gr - so_outro, 2) / (so_gr + so_outro) END)          AS p_valor
FROM tab
;


/* =============================================================================
   SEÇÃO 07  CONTRAFACTUAL DOS INSUCESSOS
   =============================================================================
   Dado um SMS que não foi entregue, o telefone do Golden Record seria diferente
   do que foi usado? E se fosse, quantas entregas teriam sido recuperadas?

   Cinco cenários, do otimista ao conservador, sempre com as perdas descontadas.
   Adotar o Golden Record também substitui números que hoje funcionam, e cada
   cenário estima quantas entregas atuais ficariam em risco.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_gr_observado_no_crm AS
SELECT
  grupo,
  cpf,
  count(*)      AS envios_no_telefone_gr,
  max(entregue) AS gr_alguma_entrega,
  avg(entregue) AS gr_taxa_entrega
FROM vt_experimento
WHERE concordante = 1
GROUP BY grupo, cpf
;

CREATE OR REPLACE TEMP VIEW vt_taxa_global_grupo AS
SELECT
  grupo,
  avg(CASE WHEN concordante = 1 THEN entregue END) AS taxa_concordante_global,
  avg(CASE WHEN concordante = 0 THEN entregue END) AS taxa_discordante_global
FROM vt_experimento
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_envios_gr_diferente AS
SELECT
  e.grupo,
  e.cpf,
  e.campanha,
  e.entregue,
  o.gr_taxa_entrega,
  CASE
    WHEN o.cpf IS NULL           THEN 'GR_NUNCA_ACIONADO'
    WHEN o.gr_alguma_entrega = 1 THEN 'GR_ACIONADO_E_ENTREGOU'
    ELSE                              'GR_ACIONADO_SEM_ENTREGA'
  END                                                     AS evidencia_direta,
  coalesce(t.taxa_concordante, g.taxa_concordante_global) AS taxa_calibracao_campanha,
  g.taxa_concordante_global
FROM vt_experimento e
LEFT JOIN vt_gr_observado_no_crm o ON e.grupo = o.grupo AND e.cpf = o.cpf
LEFT JOIN vt_taxa_por_campanha t   ON e.grupo = t.grupo AND e.campanha = t.campanha
JOIN vt_taxa_global_grupo g        ON e.grupo = g.grupo
WHERE e.classe_concordancia = 'DIFERENTE'
;

/* Insumo do resumo executivo: quanto do universo candidato depende de
   extrapolação e qual a taxa observada do telefone do Golden Record entre os
   clientes em que ele já foi acionado. Esses dois números explicam o
   comportamento do cenário de evidência extrapolada. */
CREATE OR REPLACE TEMP VIEW vt_res_07_evidencia AS
SELECT
  grupo,
  count(*)                                                                    AS candidatos,
  sum(CASE WHEN evidencia_direta = 'GR_NUNCA_ACIONADO' THEN 1 ELSE 0 END)     AS sem_historico,
  sum(CASE WHEN evidencia_direta = 'GR_NUNCA_ACIONADO' THEN 1 ELSE 0 END)
    / nullif(count(*), 0)                                                     AS fracao_sem_historico,
  sum(CASE WHEN evidencia_direta = 'GR_ACIONADO_E_ENTREGOU' THEN 1 ELSE 0 END) AS com_entrega_provada,
  avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN gr_taxa_entrega END) AS taxa_historica
FROM vt_envios_gr_diferente
WHERE entregue = 0
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_07_ganhos AS
WITH base AS (
  SELECT
    grupo,
    count(*)                                                                       AS candidatos,
    max(taxa_concordante_global)                                                   AS taxa_global,
    sum(taxa_calibracao_campanha)                                                  AS recup_campanha,
    sum(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN 1 ELSE 0 END)       AS com_historico,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN gr_taxa_entrega END) AS taxa_historica,
    sum(CASE WHEN evidencia_direta = 'GR_ACIONADO_E_ENTREGOU' THEN 1 ELSE 0 END)   AS entrega_provada
  FROM vt_envios_gr_diferente
  WHERE entregue = 0
  GROUP BY grupo
)
SELECT grupo, 1 AS ordem, 'TETO' AS cenario, candidatos,
       CAST(1.0 AS DOUBLE) AS taxa_aplicada, CAST(candidatos AS DOUBLE) AS recuperadas
FROM base
UNION ALL
SELECT grupo, 2, 'CALIBRADO_GLOBAL', candidatos, taxa_global, candidatos * taxa_global
FROM base
UNION ALL
SELECT grupo, 3, 'CALIBRADO_CAMPANHA', candidatos,
       recup_campanha / nullif(candidatos, 0), recup_campanha
FROM base
UNION ALL
SELECT grupo, 4, 'EVIDENCIA_EXTRAPOLADA', candidatos, taxa_historica, candidatos * taxa_historica
FROM base
UNION ALL
SELECT grupo, 5, 'PISO_OBSERVADO', com_historico,
       entrega_provada / nullif(com_historico, 0), CAST(entrega_provada AS DOUBLE)
FROM base
;

CREATE OR REPLACE TEMP VIEW vt_res_07_perdas AS
WITH base AS (
  SELECT
    grupo,
    count(*)                                                                        AS em_risco,
    max(taxa_concordante_global)                                                    AS taxa_global,
    sum(1 - taxa_calibracao_campanha)                                               AS perda_campanha,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN gr_taxa_entrega END) AS taxa_historica,
    sum(CASE WHEN evidencia_direta = 'GR_ACIONADO_SEM_ENTREGA' THEN 1 ELSE 0 END)   AS perda_comprovada
  FROM vt_envios_gr_diferente
  WHERE entregue = 1
  GROUP BY grupo
)
SELECT grupo, 1 AS ordem, em_risco, CAST(0.0 AS DOUBLE) AS perdidas FROM base
UNION ALL SELECT grupo, 2, em_risco, em_risco * (1 - taxa_global) FROM base
UNION ALL SELECT grupo, 3, em_risco, perda_campanha FROM base
UNION ALL SELECT grupo, 4, em_risco, em_risco * (1 - taxa_historica) FROM base
UNION ALL SELECT grupo, 5, em_risco, CAST(perda_comprovada AS DOUBLE) FROM base
;

CREATE OR REPLACE TEMP VIEW vt_res_07_saldo AS
SELECT
  g.grupo,
  g.ordem,
  g.cenario,
  g.candidatos,
  g.taxa_aplicada,
  g.recuperadas,
  p.em_risco,
  p.perdidas,
  g.recuperadas - p.perdidas                                AS entregas_liquidas,
  (g.recuperadas - p.perdidas) / nullif(v.disparos_com_gr, 0) AS pp_incremental
FROM vt_res_07_ganhos g
JOIN vt_res_07_perdas p ON g.grupo = p.grupo AND g.ordem = p.ordem
JOIN vt_res_04_volume v ON g.grupo = v.grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_07_cpfs AS
WITH status_cpf AS (
  SELECT
    grupo,
    cpf,
    max(entregue)                                                                       AS alguma_entrega,
    max(CASE WHEN entregue = 0 AND classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END) AS insucesso_divergente,
    max(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)                                    AS gr_acionado,
    max(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)                             AS gr_entregou
  FROM vt_experimento
  GROUP BY grupo, cpf
)
SELECT
  grupo,
  count(*)                                                                     AS clientes_com_gr,
  sum(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END)                          AS sem_nenhuma_entrega,
  avg(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END)                          AS fracao_sem_entrega,
  sum(CASE WHEN alguma_entrega = 0 AND insucesso_divergente = 1 AND gr_acionado = 0
           THEN 1 ELSE 0 END)                                                  AS com_telefone_novo,
  sum(CASE WHEN alguma_entrega = 0 AND insucesso_divergente = 1 AND gr_acionado = 1
           THEN 1 ELSE 0 END)                                                  AS gr_ja_falhou,
  sum(CASE WHEN alguma_entrega = 1 AND insucesso_divergente = 1 AND gr_entregou = 1
           THEN 1 ELSE 0 END)                                                  AS gr_comprovado
FROM status_cpf
GROUP BY grupo
;


/* =============================================================================
   SEÇÃO 08  TESTES DE ROBUSTEZ
   =============================================================================
   Verifica se o efeito depende de uma campanha específica, de uma regra de
   comparação ou de um perfil de cliente.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_08_por_campanha AS
WITH s AS (
  SELECT e.*, e.a + e.b AS n1, e.c + e.d AS n0
  FROM vt_estratos_campanha e
  CROSS JOIN vt_param p
  WHERE e.a + e.b >= p.min_envios_braco AND e.c + e.d >= p.min_envios_braco
),
calc AS (
  SELECT *, a / nullif(n1, 0) AS p1, c / nullif(n0, 0) AS p0 FROM s
)
SELECT
  grupo,
  campanha,
  n1, n0, p1, p0,
  CASE WHEN p1 > p0 THEN 'GOLDEN_RECORD'
       WHEN p1 < p0 THEN 'CRM'
       ELSE 'EMPATE' END AS vencedor
FROM calc
;

CREATE OR REPLACE TEMP VIEW vt_res_08_teste_sinal AS
WITH t AS (
  SELECT
    grupo,
    count(*)                                                    AS campanhas,
    sum(CASE WHEN vencedor = 'GOLDEN_RECORD' THEN 1 ELSE 0 END) AS vitorias,
    sum(CASE WHEN vencedor = 'CRM' THEN 1 ELSE 0 END)           AS derrotas,
    sum(CASE WHEN vencedor = 'EMPATE' THEN 1 ELSE 0 END)        AS empates
  FROM vt_res_08_por_campanha
  GROUP BY grupo
)
SELECT
  *,
  vitorias / nullif(vitorias + derrotas, 0) AS fracao_vitorias,
  p_valor_bilateral(
    CASE WHEN vitorias + derrotas > 0
         THEN (vitorias - (vitorias + derrotas) / 2.0)
              / sqrt((vitorias + derrotas) / 4.0) END) AS p_valor
FROM t
;

CREATE OR REPLACE TEMP VIEW vt_res_08_sem_maior AS
WITH maior AS (
  SELECT grupo, campanha
  FROM vt_campanha_volume
  QUALIFY row_number() OVER (PARTITION BY grupo ORDER BY n_envios DESC) = 1
),
agg AS (
  SELECT
    e.grupo,
    max(m.campanha)                                            AS campanha_excluida,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END) AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END) AS k0
  FROM vt_experimento e
  JOIN maior m ON e.grupo = m.grupo
  WHERE e.campanha <> m.campanha
  GROUP BY e.grupo
)
SELECT
  grupo,
  campanha_excluida,
  k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca
FROM agg
;

CREATE OR REPLACE TEMP VIEW vt_res_08_regra_exata AS
WITH agg AS (
  SELECT
    grupo,
    sum(CASE WHEN concordante_exato = 1 THEN 1 ELSE 0 END)        AS n1,
    sum(CASE WHEN concordante_exato = 1 THEN entregue ELSE 0 END) AS k1,
    sum(CASE WHEN concordante_exato = 0 THEN 1 ELSE 0 END)        AS n0,
    sum(CASE WHEN concordante_exato = 0 THEN entregue ELSE 0 END) AS k0
  FROM vt_experimento
  GROUP BY grupo
)
SELECT grupo, k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca FROM agg
;


/* =============================================================================
   SEÇÃO 09  VALUATION PELO CUSTO DE DISPARO
   =============================================================================
   Primeira lente financeira, e a mais conservadora, porque depende de uma única
   premissa: o preço de um disparo.

   A ideia é simples. Um SMS que não chega é dinheiro gasto sem contrapartida.
   Se o Golden Record aumenta a taxa de entrega, o mesmo orçamento passa a
   comprar mais entregas, e o custo por entrega cai. As entregas adicionais
   podem então ser precificadas pelo que custaria comprá-las hoje, em mídia.

   Esta lente não assume nada sobre conversão nem sobre receita. É o piso do
   valuation, e serve para a conversa com quem não aceita premissas comerciais.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_09_custo_atual AS
SELECT
  v.grupo,
  v.disparos,
  v.entregas,
  v.insucessos,
  v.taxa_entrega,
  gp.custo_sms,
  v.disparos   * gp.custo_sms                          AS custo_total,
  v.entregas   * gp.custo_sms                          AS custo_produtivo,
  v.insucessos * gp.custo_sms                          AS custo_desperdicado,
  v.insucessos / nullif(v.disparos, 0)                 AS fracao_desperdicada,
  gp.custo_sms / nullif(v.taxa_entrega, 0)             AS custo_por_entrega,
  gp.custo_sms / nullif(b.p1, 0)                       AS custo_por_entrega_concordante,
  gp.custo_sms / nullif(b.p0, 0)                       AS custo_por_entrega_discordante,
  gp.custo_sms / nullif(b.p0, 0)
    - gp.custo_sms / nullif(b.p1, 0)                   AS sobrecusto_por_entrega
FROM vt_res_04_volume v
JOIN vt_grupo_param gp ON v.grupo = gp.grupo
JOIN vt_res_05_bruto b ON v.grupo = b.grupo
;

/* Valor equivalente de mídia: o que custaria comprar hoje, em disparos
   adicionais, o mesmo número de entregas que o Golden Record entrega de graça.
   custo_por_entrega_projetado mostra a queda do custo unitário de entrega. */
CREATE OR REPLACE TEMP VIEW vt_res_09_custo_cenario AS
SELECT
  s.grupo,
  s.ordem,
  s.cenario,
  s.entregas_liquidas,
  c.custo_por_entrega,
  s.entregas_liquidas * c.custo_por_entrega                          AS valor_equivalente_midia,
  c.custo_total / nullif(c.entregas + s.entregas_liquidas, 0)        AS custo_por_entrega_projetado,
  c.custo_por_entrega
    - c.custo_total / nullif(c.entregas + s.entregas_liquidas, 0)    AS queda_custo_por_entrega
FROM vt_res_07_saldo s
JOIN vt_res_09_custo_atual c ON s.grupo = c.grupo
;


/* =============================================================================
   SEÇÃO 10  VALUATION PELA CONVERSÃO
   =============================================================================
   Segunda lente financeira. Assume que uma fração das entregas gera a conversão
   de interesse e que cada conversão tem um retorno médio.

   ESTA LENTE NÃO SE SOMA À ANTERIOR
   As duas medem o mesmo conjunto de entregas adicionais, por réguas
   diferentes. A lente de custo diz quanto valeria comprar essas entregas em
   mídia. A lente de conversão diz quanto elas geram de receita. Somar as duas
   contaria o mesmo ganho duas vezes. A leitura correta é tratar a lente de
   custo como piso e a de conversão como valor de negócio.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_10_conversao_atual AS
SELECT
  v.grupo,
  gp.taxa_conversao,
  gp.valor_conversao,
  gp.taxa_conversao * gp.valor_conversao                       AS valor_por_entrega,
  v.entregas * gp.taxa_conversao                               AS conversoes_hoje,
  v.entregas * gp.taxa_conversao * gp.valor_conversao          AS receita_hoje,
  v.entregas * gp.taxa_conversao * gp.valor_conversao
    / nullif(c.custo_total, 0)                                 AS retorno_por_real,
  v.disparos_com_gr / 100.0
    * gp.taxa_conversao * gp.valor_conversao                   AS valor_por_ponto_percentual
FROM vt_res_04_volume v
JOIN vt_grupo_param gp        ON v.grupo = gp.grupo
JOIN vt_res_09_custo_atual c  ON v.grupo = c.grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_10_conversao_cenario AS
SELECT
  s.grupo,
  s.ordem,
  s.cenario,
  s.entregas_liquidas,
  s.pp_incremental,
  a.valor_por_entrega,
  s.entregas_liquidas * a.taxa_conversao                      AS conversoes_incrementais,
  s.entregas_liquidas * a.valor_por_entrega                   AS receita_incremental,
  s.entregas_liquidas * a.valor_por_entrega
    / nullif(a.receita_hoje, 0)                               AS crescimento_sobre_receita_atual
FROM vt_res_07_saldo s
JOIN vt_res_10_conversao_atual a ON s.grupo = a.grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_10_sensibilidade AS
SELECT
  c.grupo,
  c.ordem,
  c.cenario,
  s.rotulo_taxa,
  s.rotulo_valor,
  a.taxa_conversao  * s.mult_taxa                                   AS taxa_aplicada,
  a.valor_conversao * s.mult_valor                                  AS ticket_aplicado,
  c.entregas_liquidas,
  c.entregas_liquidas * a.taxa_conversao * s.mult_taxa
    * a.valor_conversao * s.mult_valor                              AS receita_incremental
FROM vt_res_10_conversao_cenario c
JOIN vt_res_10_conversao_atual a ON c.grupo = a.grupo
CROSS JOIN vt_param_sensibilidade s
;


/* =============================================================================
   SEÇÃO 11  APROFUNDAMENTOS
   =============================================================================
   Camada que responde às perguntas que o resumo anterior deixava em aberto:
   se o efeito é uniforme ou concentrado, se ele sobrevive à comparação com uma
   regra simples, quanto do resultado depende de extrapolação, qual o esforço de
   implementação e em que condição o dado foi coletado.

   Todas as views guardam valores brutos. O arredondamento acontece apenas no
   resumo.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   11.1  QUALIDADE DOS REGISTROS RECEBIDOS

   Volume descartado antes do estudo, por motivo. Descarte alto por status
   contraditório ou ausente indica problema de carga na origem e reduz a
   cobertura do estudo, sem invalidar a comparação.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_qualidade AS
WITH total AS (
  SELECT
    count(*)                                                      AS registros,
    sum(CASE WHEN qualidade = 'OK' THEN 1 ELSE 0 END)             AS aproveitados,
    sum(CASE WHEN qualidade <> 'OK' THEN 1 ELSE 0 END)            AS descartados,
    sum(CASE WHEN qualidade = 'STATUS_INCONSISTENTE' THEN 1 ELSE 0 END) AS status_contraditorio,
    sum(CASE WHEN qualidade = 'SEM_STATUS' THEN 1 ELSE 0 END)     AS sem_status,
    sum(CASE WHEN qualidade IN ('SEM_CPF','SEM_TELEFONE') THEN 1 ELSE 0 END) AS chave_invalida
  FROM vt_crm_envios_qualidade
)
SELECT
  gp.grupo,
  t.registros,
  t.aproveitados,
  t.descartados,
  t.descartados / nullif(t.registros, 0) AS fracao_descartada,
  t.status_contraditorio,
  t.sem_status,
  t.chave_invalida
FROM total t
CROSS JOIN (SELECT DISTINCT grupo FROM vt_grupo_param) gp
;


/* -----------------------------------------------------------------------------
   11.2  RETENTATIVAS

   Disparos que representam repetição para o mesmo cliente, campanha e telefone.
   Retentativa é custo de mídia sem novo alcance, e por isso entra como
   oportunidade própria de economia.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_retentativa AS
SELECT
  grupo,
  count(*)                                                        AS envios,
  sum(CASE WHEN registros_originais > 1 THEN 1 ELSE 0 END)        AS envios_com_retentativa,
  avg(CASE WHEN registros_originais > 1 THEN 1 ELSE 0 END)        AS fracao_com_retentativa,
  sum(registros_originais) - count(*)                             AS disparos_repetidos,
  (sum(registros_originais) - count(*)) / nullif(sum(registros_originais), 0) AS fracao_disparos_repetidos
FROM vt_base_grupo
GROUP BY grupo
;


/* -----------------------------------------------------------------------------
   11.3  SAFRA DO CADASTRO

   Entrega do telefone recomendado conforme a idade da carga que o registrou,
   medida em meses até a ingestão mais recente da base.

   Ressalva declarada: sem data de envio na base de campanhas, a idade é medida
   em relação à carga mais recente, e não ao momento do disparo. A leitura
   correta é sobre a safra do registro, e não sobre decaimento no tempo entre
   cadastro e acionamento.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_safra AS
WITH referencia AS (
  SELECT max(try_cast(data_ingestao_gr AS TIMESTAMP)) AS mais_recente
  FROM vt_experimento
),
classificado AS (
  SELECT
    e.grupo,
    e.entregue,
    CASE
      WHEN try_cast(e.data_ingestao_gr AS TIMESTAMP) IS NULL THEN 'INDETERMINADA'
      WHEN months_between(r.mais_recente, try_cast(e.data_ingestao_gr AS TIMESTAMP)) <= 3  THEN '1. ate 3 meses'
      WHEN months_between(r.mais_recente, try_cast(e.data_ingestao_gr AS TIMESTAMP)) <= 6  THEN '2. 3 a 6 meses'
      WHEN months_between(r.mais_recente, try_cast(e.data_ingestao_gr AS TIMESTAMP)) <= 12 THEN '3. 6 a 12 meses'
      ELSE '4. acima de 12 meses'
    END AS safra
  FROM vt_experimento e
  CROSS JOIN referencia r
  WHERE e.concordante = 1
)
SELECT
  grupo,
  safra,
  count(*)      AS envios,
  sum(entregue) AS entregas,
  avg(entregue) AS taxa
FROM classificado
GROUP BY grupo, safra
;

CREATE OR REPLACE TEMP VIEW vt_res_11_safra_contraste AS
SELECT
  nova.grupo,
  nova.taxa   AS taxa_recente,
  nova.envios AS envios_recente,
  velha.taxa  AS taxa_antiga,
  velha.envios AS envios_antiga,
  nova.taxa - velha.taxa AS diferenca
FROM (SELECT * FROM vt_res_11_safra WHERE safra = '1. ate 3 meses') nova
FULL OUTER JOIN (SELECT * FROM vt_res_11_safra WHERE safra = '4. acima de 12 meses') velha
  ON nova.grupo = velha.grupo
;


/* -----------------------------------------------------------------------------
   11.4  COMPARAÇÃO COM UMA REGRA SIMPLES

   Responde à objeção mais dura que o estudo pode receber: quanto do ganho vem
   do Golden Record e quanto viria de qualquer heurística razoável?

   A regra simples usada é o telefone que o próprio CRM mais aciona para aquele
   cliente, que é o candidato natural a substituto sem nenhum investimento em
   cadastro. Os disparos são separados em três grupos mutuamente exclusivos:
   o número recomendado, o número mais acionado quando ele difere do recomendado,
   e os demais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_benchmark AS
WITH classificado AS (
  SELECT
    grupo,
    entregue,
    CASE
      WHEN concordante = 1                              THEN 'RECOMENDADO'
      WHEN heuristica_mais_acionado = 1                 THEN 'REGRA_SIMPLES'
      ELSE                                                   'DEMAIS'
    END AS estrategia
  FROM vt_experimento
),
agg AS (
  SELECT grupo, estrategia, count(*) AS envios, sum(entregue) AS entregas,
         sum(entregue) / nullif(count(*), 0) AS taxa
  FROM classificado
  GROUP BY grupo, estrategia
)
SELECT
  r.grupo,
  r.taxa                                    AS taxa_recomendado,
  r.envios                                  AS envios_recomendado,
  h.taxa                                    AS taxa_regra_simples,
  h.envios                                  AS envios_regra_simples,
  d.taxa                                    AS taxa_demais,
  r.taxa - h.taxa                           AS ganho_sobre_regra_simples,
  h.taxa - d.taxa                           AS ganho_da_regra_simples,
  (r.taxa - h.taxa) / nullif(r.taxa - d.taxa, 0) AS parcela_atribuivel_ao_cadastro
FROM (SELECT * FROM agg WHERE estrategia = 'RECOMENDADO') r
LEFT JOIN (SELECT * FROM agg WHERE estrategia = 'REGRA_SIMPLES') h ON r.grupo = h.grupo
LEFT JOIN (SELECT * FROM agg WHERE estrategia = 'DEMAIS') d ON r.grupo = d.grupo
;


/* -----------------------------------------------------------------------------
   11.5  DISTRIBUIÇÃO DO EFEITO ENTRE CAMPANHAS

   O resumo apresenta uma média ponderada. Esta view mostra a dispersão, que
   protege contra a leitura de que todas as campanhas se comportam como a média.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_distribuicao AS
SELECT
  grupo,
  count(*)                                              AS campanhas,
  percentile_approx(p1 - p0, 0.25)                      AS quartil_inferior,
  percentile_approx(p1 - p0, 0.50)                      AS mediana,
  percentile_approx(p1 - p0, 0.75)                      AS quartil_superior,
  min(p1 - p0)                                          AS minimo,
  max(p1 - p0)                                          AS maximo
FROM vt_res_08_por_campanha
GROUP BY grupo
;


/* -----------------------------------------------------------------------------
   11.6  EFEITO POR PORTE DE CAMPANHA E POR INTENSIDADE DE CONTATO

   Duas segmentações que respondem para quem o efeito é maior, e portanto por
   onde a adoção rende mais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_por_faixa AS
WITH agg AS (
  SELECT
    e.grupo,
    v.faixa_volume,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)          AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END) AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)          AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END) AS k0
  FROM vt_experimento e
  JOIN vt_campanha_volume v ON e.grupo = v.grupo AND e.campanha = v.campanha
  GROUP BY e.grupo, v.faixa_volume
)
SELECT
  grupo, faixa_volume, n1, n0,
  k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca
FROM agg
;

CREATE OR REPLACE TEMP VIEW vt_res_11_por_intensidade AS
WITH freq AS (
  SELECT grupo, cpf, count(*) AS envios_cpf FROM vt_experimento GROUP BY grupo, cpf
),
agg AS (
  SELECT
    e.grupo,
    CASE WHEN f.envios_cpf = 1   THEN '1. um envio'
         WHEN f.envios_cpf <= 3  THEN '2. dois a tres'
         WHEN f.envios_cpf <= 10 THEN '3. quatro a dez'
         ELSE                         '4. acima de dez' END      AS faixa,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)           AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END)  AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)           AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END)  AS k0
  FROM vt_experimento e
  JOIN freq f ON e.grupo = f.grupo AND e.cpf = f.cpf
  GROUP BY e.grupo,
    CASE WHEN f.envios_cpf = 1   THEN '1. um envio'
         WHEN f.envios_cpf <= 3  THEN '2. dois a tres'
         WHEN f.envios_cpf <= 10 THEN '3. quatro a dez'
         ELSE                         '4. acima de dez' END
)
SELECT grupo, faixa, n1, n0,
       k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca
FROM agg
;


/* -----------------------------------------------------------------------------
   11.7  DISPERSÃO REGIONAL

   Efeito calculado dentro de cada código de área, para verificar se o ganho é
   nacional ou concentrado em algumas praças.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_por_ddd AS
WITH agg AS (
  SELECT
    grupo,
    ddd_crm,
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)  AS k1,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN concordante = 0 THEN entregue ELSE 0 END)  AS k0
  FROM vt_experimento
  GROUP BY grupo, ddd_crm
),
calc AS (
  SELECT *, k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca
  FROM agg
  WHERE n1 >= 1000 AND n0 >= 1000
)
SELECT
  grupo,
  count(*)                                                  AS ddds_avaliados,
  avg(CASE WHEN diferenca > 0 THEN 1 ELSE 0 END)            AS fracao_com_ganho,
  percentile_approx(diferenca, 0.50)                        AS mediana,
  min(diferenca)                                            AS minimo,
  max(diferenca)                                            AS maximo
FROM calc
GROUP BY grupo
;


/* -----------------------------------------------------------------------------
   11.8  CONTRAFACTUAL POR CAMPANHA E CONCENTRAÇÃO DO GANHO

   Abre o cenário central em uma linha por campanha e mede quanto do ganho está
   concentrado nas maiores. Se poucas campanhas concentram a maior parte, a
   adoção deve começar dirigida em vez de geral.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_campanha_valor AS
WITH d AS (
  SELECT
    grupo,
    campanha,
    sum(CASE WHEN entregue = 0 THEN taxa_calibracao_campanha ELSE 0 END)       AS recuperadas,
    sum(CASE WHEN entregue = 1 THEN 1 - taxa_calibracao_campanha ELSE 0 END)   AS perdidas
  FROM vt_envios_gr_diferente
  GROUP BY grupo, campanha
)
SELECT
  d.grupo,
  d.campanha,
  v.n_envios,
  d.recuperadas,
  d.perdidas,
  d.recuperadas - d.perdidas AS entregas_liquidas
FROM d
JOIN vt_campanha_volume v ON d.grupo = v.grupo AND d.campanha = v.campanha
;

CREATE OR REPLACE TEMP VIEW vt_res_11_concentracao AS
WITH ordenado AS (
  SELECT
    grupo,
    campanha,
    entregas_liquidas,
    row_number() OVER (PARTITION BY grupo ORDER BY entregas_liquidas DESC) AS posicao,
    sum(entregas_liquidas) OVER (PARTITION BY grupo)                       AS total_liquidas,
    sum(entregas_liquidas) OVER (
      PARTITION BY grupo ORDER BY entregas_liquidas DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                    AS acumulado
  FROM vt_res_11_campanha_valor
  WHERE entregas_liquidas > 0
)
SELECT
  grupo,
  count(*)                                                                   AS campanhas_com_ganho,
  max(total_liquidas)                                                        AS total_liquidas,
  min(CASE WHEN acumulado >= 0.5 * total_liquidas THEN posicao END)          AS campanhas_para_metade,
  max(CASE WHEN posicao <= 10 THEN acumulado END)                            AS ganho_das_dez_maiores,
  max(CASE WHEN posicao <= 10 THEN acumulado END) / nullif(max(total_liquidas), 0) AS fracao_dez_maiores
FROM ordenado
GROUP BY grupo
;


/* -----------------------------------------------------------------------------
   11.9  FAIXA ESTATÍSTICA DO VALOR

   A faixa de cenários da seção 07 representa incerteza de premissa. Esta view
   representa a outra incerteza, a amostral: dado o volume observado, qual a
   margem de erro da própria diferença medida, propagada para reais.

   Usa a diferença bruta e seu erro padrão, aplicados ao volume com cobertura.
   É deliberadamente conservadora, porque a diferença bruta é a estimativa sem
   controle e tem intervalo mais largo que a estratificada.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_faixa_estatistica AS
SELECT
  b.grupo,
  b.diferenca,
  b.se_diff,
  b.diferenca - 1.959964 * b.se_diff                                        AS dif_inf,
  b.diferenca + 1.959964 * b.se_diff                                        AS dif_sup,
  (b.diferenca - 1.959964 * b.se_diff) * v.disparos_com_gr * a.valor_por_entrega AS receita_inf,
  (b.diferenca + 1.959964 * b.se_diff) * v.disparos_com_gr * a.valor_por_entrega AS receita_sup
FROM vt_res_05_bruto b
JOIN vt_res_04_volume v          ON b.grupo = v.grupo
JOIN vt_res_10_conversao_atual a ON b.grupo = a.grupo
;


/* -----------------------------------------------------------------------------
   11.10  ESFORÇO DE IMPLEMENTAÇÃO E ATIVO DE CADASTRO MONETIZADO

   O valuation até aqui mede apenas o benefício. Esta view dimensiona o outro
   lado: quantos cadastros precisariam ser atualizados, e quanto vale o contato
   recuperado dos clientes hoje inalcançáveis.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_esforco AS
SELECT
  e.grupo,
  count(DISTINCT CASE WHEN e.classe_concordancia = 'DIFERENTE' THEN e.cpf END) AS cpfs_a_atualizar,
  count(DISTINCT e.cpf)                                                        AS cpfs_com_cobertura,
  count(DISTINCT CASE WHEN e.classe_concordancia = 'DIFERENTE' THEN e.cpf END)
    / nullif(count(DISTINCT e.cpf), 0)                                         AS fracao_a_atualizar
FROM vt_experimento e
GROUP BY e.grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_11_ativo_cadastro AS
SELECT
  f.grupo,
  f.com_telefone_novo,
  f.gr_comprovado,
  g.taxa_concordante_global                                                   AS taxa_esperada,
  f.com_telefone_novo * g.taxa_concordante_global                             AS contatos_recuperaveis,
  f.com_telefone_novo * g.taxa_concordante_global * a.valor_por_entrega       AS valor_contato_recuperavel,
  f.gr_comprovado * a.valor_por_entrega                                       AS valor_contato_comprovado
FROM vt_res_07_cpfs f
JOIN vt_taxa_global_grupo g      ON f.grupo = g.grupo
JOIN vt_res_10_conversao_atual a ON f.grupo = a.grupo
;


/* -----------------------------------------------------------------------------
   11.11  JANELA DO ESTUDO E VALIDADE TEMPORAL DA RECOMENDAÇÃO

   Com a data do registro de disparo disponível na origem, duas perguntas que
   antes ficavam em aberto passam a ter resposta.

   A primeira é qual período o estudo cobre. Sem isso, nenhum valor do bloco de
   valuation podia ser lido como anual. Com a janela fechada, pode.

   A segunda é mais delicada e diz respeito à validade do contrafactual. Afirmar
   que o Golden Record teria recomendado outro telefone só faz sentido se aquela
   recomendação já existisse quando a campanha ocorreu. Comparando a data de
   ingestão do registro do Golden Record com a data do disparo, é possível
   separar os envios em que a recomendação era anterior daqueles em que ela é
   posterior e portanto anacrônica.

   O efeito recalculado apenas sobre os envios temporalmente válidos é o teste
   de sensibilidade correspondente. Se ele se mantiver próximo do efeito geral,
   a ressalva temporal deixa de ser uma ameaça relevante.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_janela AS
SELECT
  grupo,
  min(data_disparo)                                     AS primeiro_registro,
  max(data_disparo)                                     AS ultimo_registro,
  datediff(max(data_disparo), min(data_disparo)) + 1    AS dias_cobertos,
  count(DISTINCT date_format(data_disparo, 'yyyy-MM'))  AS meses_com_registro,
  count(*)                                              AS disparos
FROM vt_base_grupo
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_11_validade_temporal AS
WITH marcado AS (
  SELECT
    grupo,
    CASE
      WHEN try_cast(data_ingestao_gr AS DATE) IS NULL OR data_disparo IS NULL
        THEN 'INDETERMINADA'
      WHEN try_cast(data_ingestao_gr AS DATE) <= data_disparo
        THEN 'RECOMENDACAO_ANTERIOR'
      ELSE 'RECOMENDACAO_POSTERIOR'
    END AS validade
  FROM vt_experimento
)
SELECT
  grupo,
  count(*)                                                             AS envios,
  sum(CASE WHEN validade = 'RECOMENDACAO_ANTERIOR' THEN 1 ELSE 0 END)  AS anteriores,
  avg(CASE WHEN validade = 'RECOMENDACAO_ANTERIOR' THEN 1 ELSE 0 END)  AS fracao_anteriores,
  sum(CASE WHEN validade = 'RECOMENDACAO_POSTERIOR' THEN 1 ELSE 0 END) AS posteriores,
  sum(CASE WHEN validade = 'INDETERMINADA' THEN 1 ELSE 0 END)          AS indeterminadas
FROM marcado
GROUP BY grupo
;

CREATE OR REPLACE TEMP VIEW vt_res_11_efeito_temporalmente_valido AS
WITH agg AS (
  SELECT
    grupo,
    sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)        AS n1,
    sum(CASE WHEN concordante = 1 THEN entregue ELSE 0 END) AS k1,
    sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)        AS n0,
    sum(CASE WHEN concordante = 0 THEN entregue ELSE 0 END) AS k0
  FROM vt_experimento
  WHERE try_cast(data_ingestao_gr AS DATE) <= data_disparo
  GROUP BY grupo
)
SELECT
  grupo, n1, n0,
  k1 / nullif(n1, 0) - k0 / nullif(n0, 0) AS diferenca
FROM agg
;


/* -----------------------------------------------------------------------------
   11.12  EVOLUÇÃO MENSAL

   Responde a duas perguntas que a leitura agregada não separa.

   A primeira é sobre o cadastro: a vantagem do telefone recomendado cresce,
   encolhe ou fica estável ao longo dos meses? Vantagem que encolhe indica
   cadastro envelhecendo entre as cargas. Vantagem que cresce indica que as
   cargas recentes estão acrescentando informação útil.

   A segunda é sobre a operação, e é independente do cadastro: a entrega está
   melhorando por conta própria? O indicador correto para isso é a taxa do braço
   divergente, ou seja, o que acontece quando o telefone recomendado não é
   usado. Se essa taxa sobe mês a mês, a operação está melhorando sozinha, e o
   ganho atribuível ao Golden Record precisa ser lido contra esse pano de fundo.

   Separar as duas evita a confusão mais comum na leitura de série temporal, que
   é atribuir ao cadastro uma melhora que vem de outra causa, como higienização
   de base, mudança de fornecedor ou sazonalidade de campanha.

   A tendência é medida pela inclinação de uma reta ajustada aos valores
   mensais, expressa em pontos percentuais por mês. O cálculo é feito pela
   fórmula fechada de mínimos quadrados, sem depender de função de regressão.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_11_mensal AS
SELECT
  grupo,
  date_format(data_disparo, 'yyyy-MM')                     AS mes,
  count(*)                                                 AS disparos,
  sum(entregue)                                            AS entregas,
  avg(entregue)                                            AS taxa_geral,
  avg(CASE WHEN tem_gr THEN 1 ELSE 0 END)                  AS cobertura,
  sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)         AS n1,
  sum(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)  AS k1,
  sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)         AS n0,
  sum(CASE WHEN concordante = 0 THEN entregue ELSE 0 END)  AS k0
FROM vt_base_grupo
WHERE data_disparo IS NOT NULL
GROUP BY grupo, date_format(data_disparo, 'yyyy-MM')
;

CREATE OR REPLACE TEMP VIEW vt_res_11_mensal_calc AS
SELECT
  *,
  k1 / nullif(n1, 0)                                       AS taxa_com_recomendado,
  k0 / nullif(n0, 0)                                       AS taxa_sem_recomendado,
  k1 / nullif(n1, 0) - k0 / nullif(n0, 0)                  AS vantagem,
  row_number() OVER (PARTITION BY grupo ORDER BY mes)      AS indice_mes
FROM vt_res_11_mensal
;

/* Inclinação da reta ajustada, em variação por mês, para quatro séries:
   a vantagem do cadastro, a entrega sem o telefone recomendado, a entrega com
   o telefone recomendado e a cobertura da base. */
CREATE OR REPLACE TEMP VIEW vt_res_11_tendencia AS
WITH s AS (
  SELECT
    grupo,
    count(*)                                       AS meses,
    sum(indice_mes)                                AS sx,
    sum(indice_mes * indice_mes)                   AS sxx,
    sum(vantagem)                                  AS sy_vant,
    sum(indice_mes * vantagem)                     AS sxy_vant,
    sum(taxa_sem_recomendado)                      AS sy_sem,
    sum(indice_mes * taxa_sem_recomendado)         AS sxy_sem,
    sum(taxa_com_recomendado)                      AS sy_com,
    sum(indice_mes * taxa_com_recomendado)         AS sxy_com,
    sum(cobertura)                                 AS sy_cob,
    sum(indice_mes * cobertura)                    AS sxy_cob,
    sum(CASE WHEN vantagem > 0 THEN 1 ELSE 0 END)  AS meses_com_ganho
  FROM vt_res_11_mensal_calc
  WHERE vantagem IS NOT NULL
  GROUP BY grupo
)
SELECT
  grupo,
  meses,
  meses_com_ganho,
  (meses * sxy_vant - sx * sy_vant) / nullif(meses * sxx - sx * sx, 0) AS inclinacao_vantagem,
  (meses * sxy_sem  - sx * sy_sem)  / nullif(meses * sxx - sx * sx, 0) AS inclinacao_sem_recomendado,
  (meses * sxy_com  - sx * sy_com)  / nullif(meses * sxx - sx * sx, 0) AS inclinacao_com_recomendado,
  (meses * sxy_cob  - sx * sy_cob)  / nullif(meses * sxx - sx * sx, 0) AS inclinacao_cobertura
FROM s
;

CREATE OR REPLACE TEMP VIEW vt_res_11_primeiro_ultimo AS
WITH marcado AS (
  SELECT
    *,
    row_number() OVER (PARTITION BY grupo ORDER BY mes ASC)  AS rn_ini,
    row_number() OVER (PARTITION BY grupo ORDER BY mes DESC) AS rn_fim
  FROM vt_res_11_mensal_calc
)
SELECT
  i.grupo,
  i.mes                                            AS primeiro_mes,
  f.mes                                            AS ultimo_mes,
  i.disparos                                       AS disparos_inicio,
  f.disparos                                       AS disparos_fim,
  i.taxa_geral                                     AS taxa_geral_inicio,
  f.taxa_geral                                     AS taxa_geral_fim,
  f.taxa_geral - i.taxa_geral                      AS variacao_taxa_geral,
  i.taxa_sem_recomendado                           AS sem_recomendado_inicio,
  f.taxa_sem_recomendado                           AS sem_recomendado_fim,
  f.taxa_sem_recomendado - i.taxa_sem_recomendado  AS variacao_sem_recomendado,
  i.taxa_com_recomendado                           AS com_recomendado_inicio,
  f.taxa_com_recomendado                           AS com_recomendado_fim,
  f.taxa_com_recomendado - i.taxa_com_recomendado  AS variacao_com_recomendado,
  i.vantagem                                       AS vantagem_inicio,
  f.vantagem                                       AS vantagem_fim,
  f.vantagem - i.vantagem                          AS variacao_vantagem,
  i.cobertura                                      AS cobertura_inicio,
  f.cobertura                                      AS cobertura_fim,
  f.cobertura - i.cobertura                        AS variacao_cobertura
FROM (SELECT * FROM marcado WHERE rn_ini = 1) i
JOIN (SELECT * FROM marcado WHERE rn_fim = 1) f ON i.grupo = f.grupo
;


/* =============================================================================
   SEÇÃO 12  RESUMO EXECUTIVO
   =============================================================================
   Única saída exibida por este arquivo. Cada linha traz o indicador, o valor, a
   definição, como o número foi calculado, como lê-lo e um exemplo concreto.

   Blocos, na ordem em que a história deve ser contada:
     A  Base e oportunidade, o tamanho do campo de jogo
     B  Evidência causal, o telefone certo entrega mais
     C  Robustez, o efeito se repete
     D  Valuation pelo custo de disparo, o piso sem premissa comercial
     E  Valuation pela conversão, o valor de negócio
     F  Clientes, o ativo de cadastro

   Os exemplos usam o volume de referência definido em 00.2.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_12_resumo AS

/* ---------------------------------------------------------------- BLOCO A -- */
SELECT
  v.grupo,
  'A. Base e oportunidade'                            AS bloco,
  1                                                   AS ordem,
  'Disparos analisados'                               AS indicador,
  CAST(v.disparos AS DOUBLE)                          AS valor,
  'envios'                                            AS unidade,
  'Volume de SMS que passou pelos filtros de qualidade e entrou no estudo.'  AS definicao,
  'Contagem de combinacoes distintas de cliente, campanha e telefone, apos descartar registros com status contraditorio ou chave invalida.' AS calculo,
  'E o denominador de todas as taxas apresentadas adiante. Quanto maior, mais estavel a estimativa.' AS interpretacao,
  concat('Equivale a ', format_number(v.disparos / 1000000.0, 1), ' campanhas de um milhao de disparos.') AS exemplo,
  'vt_res_04_volume'                                  AS origem
FROM vt_res_04_volume v

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 2, 'Clientes distintos acionados',
  CAST(v.clientes AS DOUBLE), 'CPFs',
  'Quantidade de pessoas diferentes que receberam ao menos um SMS no periodo.',
  'Contagem distinta de CPF na base de disparos valida.',
  'Mostra que o volume de envios nao vem de poucos clientes muito acionados. Compare com a linha 1 para obter a media de disparos por cliente.',
  concat('Media de ', format_number(v.disparos / nullif(v.clientes, 0), 2), ' disparos por cliente no periodo.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 3, 'Campanhas analisadas',
  CAST(v.campanhas AS DOUBLE), 'campanhas',
  'Quantidade de campanhas distintas dentro do escopo.',
  'Contagem distinta do identificador de campanha.',
  'Sustenta a analise estratificada. Muitas campanhas permitem comparar o efeito dentro de cada uma e verificar se ele se repete.',
  concat('Media de ', format_number(v.disparos / nullif(v.campanhas, 0), 0), ' disparos por campanha.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 4, 'Taxa de entrega geral hoje',
  round(CAST(100.0 * v.taxa_entrega AS DOUBLE), 4), '%',
  'Percentual dos disparos que chegaram ao destino, considerando todos os telefones usados.',
  'Entregas divididas por disparos, sobre a base inteira do escopo.',
  'E a linha de base do estudo. Todo ganho estimado adiante deve ser lido como avanco a partir deste patamar.',
  concat('Hoje, ', format_number(100.0 * (1 - v.taxa_entrega), 1), ' por cento dos disparos nao chegam ao destino.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 5, 'Cobertura do Golden Record sobre disparos',
  round(CAST(100.0 * v.cobertura_disparo AS DOUBLE), 4), '%',
  'Percentual dos disparos cujo cliente possui telefone cadastrado no Golden Record.',
  'Disparos com CPF presente no Golden Record divididos pelo total de disparos.',
  'Define o teto de alcance de qualquer iniciativa baseada no Golden Record. O restante dos disparos esta fora do alcance da base atual.',
  concat('Em uma campanha de ', format_number(gp.volume_referencia, 0), ' disparos, cerca de ',
         format_number(v.cobertura_disparo * gp.volume_referencia, 0), ' teriam telefone comparavel.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v JOIN vt_grupo_param gp ON v.grupo = gp.grupo

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 6, 'Cobertura do Golden Record sobre clientes',
  round(CAST(100.0 * v.cobertura_cliente AS DOUBLE), 4), '%',
  'Percentual dos clientes acionados que possuem telefone no Golden Record.',
  'CPFs distintos presentes no Golden Record divididos pelo total de CPFs distintos acionados.',
  'Compare com a linha 5. Quando a cobertura por disparo e maior que a cobertura por cliente, os clientes cobertos sao justamente os mais acionados, o que amplia o efeito pratico.',
  concat('De cada cem clientes acionados, ', format_number(100.0 * v.cobertura_cliente, 0), ' tem telefone no Golden Record.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v

UNION ALL
SELECT c.grupo, 'A. Base e oportunidade', 7, 'Disparos em que o Golden Record indicaria outro numero',
  round(CAST(100.0 * c.fracao_envios AS DOUBLE), 4), '%',
  'Percentual dos disparos com cobertura em que o numero usado difere do telefone de ranking 1.',
  'Envios classificados como divergentes divididos pelo total de envios com cobertura do Golden Record.',
  'E o espaco em que adotar o Golden Record muda alguma coisa. Nos demais disparos a base apenas confirma o numero que ja seria usado, sem efeito pratico.',
  concat('Em ', format_number(100.0 - 100.0 * c.fracao_envios, 1),
         ' por cento dos disparos o CRM ja acerta o telefone recomendado, sem usar a base.'),
  'vt_res_04_concordancia'
FROM vt_res_04_concordancia c WHERE c.classe_concordancia = 'DIFERENTE'

UNION ALL
SELECT a.grupo, 'A. Base e oportunidade', 8, 'Insucessos em que o Golden Record indicaria outro numero',
  round(CAST(100.0 * a.fracao_sobre_com_gr AS DOUBLE), 4), '%',
  'Dos SMS que nao chegaram e tem cobertura, fracao que teria ido para um numero diferente.',
  'Insucessos divergentes divididos pelo total de insucessos com cobertura do Golden Record.',
  'E o tamanho bruto da oportunidade de recuperacao, antes de qualquer ajuste. Ainda nao e uma estimativa de ganho, porque nem todo numero diferente entregaria.',
  concat('Sao ', format_number(a.gr_diferente, 0), ' disparos que falharam e teriam ido para outro telefone.'),
  'vt_res_04_anatomia_insucesso'
FROM vt_res_04_anatomia_insucesso a

/* ---------------------------------------------------------------- BLOCO B -- */
UNION ALL
SELECT b.grupo, 'B. Evidencia causal', 10, 'Entrega com telefone igual ao Golden Record',
  round(CAST(100.0 * b.p1 AS DOUBLE), 4), '%',
  'Taxa de entrega dos disparos em que o numero usado coincidiu com o telefone de ranking 1.',
  'Entregas divididas por envios dentro do braco concordante.',
  'E o braco tratado do experimento natural. A coincidencia ocorre por sobreposicao de cadastros, e nao por decisao de quem conhecia o resultado.',
  concat('Intervalo de 95 por cento entre ', format_number(100.0 * b.ic_inf_conc, 2),
         ' e ', format_number(100.0 * b.ic_sup_conc, 2), ' por cento, sobre ',
         format_number(b.n1, 0), ' disparos.'),
  'vt_res_05_bruto'
FROM vt_res_05_bruto b

UNION ALL
SELECT b.grupo, 'B. Evidencia causal', 11, 'Entrega com telefone diferente do Golden Record',
  round(CAST(100.0 * b.p0 AS DOUBLE), 4), '%',
  'Taxa de entrega dos disparos que usaram um numero diferente do telefone de ranking 1.',
  'Entregas divididas por envios dentro do braco divergente.',
  'E o braco de comparacao. A distancia para a linha 10 e a materia-prima de todo o valuation.',
  concat('Intervalo de 95 por cento entre ', format_number(100.0 * b.ic_inf_disc, 2),
         ' e ', format_number(100.0 * b.ic_sup_disc, 2), ' por cento, sobre ',
         format_number(b.n0, 0), ' disparos.'),
  'vt_res_05_bruto'
FROM vt_res_05_bruto b

UNION ALL
SELECT b.grupo, 'B. Evidencia causal', 12, 'Diferenca bruta entre os dois bracos',
  round(CAST(100.0 * b.diferenca AS DOUBLE), 4), 'p.p.',
  'Diferenca simples de entrega entre usar e nao usar o telefone recomendado.',
  'Taxa do braco concordante menos taxa do braco divergente, sem nenhum controle.',
  'E o ponto de partida. Ainda esta sujeito a diferencas de composicao entre os grupos, corrigidas nas linhas seguintes.',
  concat('Em ', format_number(gp.volume_referencia, 0), ' disparos representa ',
         format_number(b.diferenca * gp.volume_referencia, 0),
         ' entregas a mais. Probabilidade de ser acaso: ', format_number(b.p_valor, 6), '.'),
  'vt_res_05_bruto'
FROM vt_res_05_bruto b JOIN vt_grupo_param gp ON b.grupo = gp.grupo

UNION ALL
SELECT e.grupo, 'B. Evidencia causal', 13, 'Diferenca controlada por campanha',
  round(CAST(100.0 * e.diferenca AS DOUBLE), 4), 'p.p.',
  'A mesma comparacao, feita dentro de cada campanha e depois combinada, ponderando pelo tamanho.',
  'Estimador de Cochran, Mantel e Haenszel, que neutraliza qualquer diferenca de periodo, mensagem ou publico entre campanhas.',
  'E a estimativa principal do estudo e o numero a levar para a discussao executiva. O efeito continuar forte apos esse controle e o que sustenta a leitura causal.',
  concat('Calculado sobre ', format_number(e.campanhas_no_teste, 0), ' campanhas e ',
         format_number(e.envios_no_teste, 0), ' disparos. Probabilidade de ser acaso: ',
         format_number(e.p_valor, 6), '.'),
  'vt_res_05_estratificado'
FROM vt_res_05_estratificado e

UNION ALL
SELECT e.grupo, 'B. Evidencia causal', 14, 'Razao de chances controlada por campanha',
  round(CAST(e.odds_ratio AS DOUBLE), 4), 'vezes',
  'Quantas vezes a chance de entrega e maior ao usar o telefone recomendado, controlando por campanha.',
  'Razao de chances de Mantel e Haenszel, com intervalo pela variancia de Robins, Breslow e Greenland.',
  'Complementa a linha 13. Enquanto a diferenca em pontos percentuais depende do patamar de entrega, a razao de chances e comparavel entre campanhas com patamares distintos.',
  concat('Intervalo de 95 por cento entre ', format_number(e.or_ic_inf, 3), ' e ',
         format_number(e.or_ic_sup, 3), ' vezes.'),
  'vt_res_05_estratificado'
FROM vt_res_05_estratificado e

UNION ALL
SELECT p.grupo, 'B. Evidencia causal', 15, 'Diferenca no mesmo cliente',
  round(CAST(100.0 * p.diferenca AS DOUBLE), 4), 'p.p.',
  'Comparacao do mesmo CPF consigo mesmo, uma vez com o telefone recomendado e outra com um numero diferente.',
  'Teste de McNemar sobre pares discordantes, com um envio sorteado por braco para equilibrar a exposicao.',
  'Elimina qualquer caracteristica fixa da pessoa como explicacao alternativa, porque perfil, regiao e engajamento sao os mesmos nos dois lados.',
  concat('Em ', format_number(p.n_pares, 0), ' clientes comparados, so o telefone recomendado entregou em ',
         format_number(p.so_gr, 0), ' casos, contra ', format_number(p.so_outro, 0), ' do outro numero.'),
  'vt_res_06_pareado'
FROM vt_res_06_pareado p

UNION ALL
SELECT m.grupo, 'B. Evidencia causal', 16, 'Diferenca no mesmo cliente e na mesma campanha',
  round(CAST(100.0 * m.diferenca AS DOUBLE), 4), 'p.p.',
  'Versao mais restritiva, com pessoa e campanha fixas e apenas o telefone variando.',
  'Teste de McNemar restrito aos casos em que o CRM disparou para dois numeros do mesmo cliente dentro da mesma campanha.',
  'E o desenho mais proximo de um teste controlado que a base observacional permite montar. O valor menor que os anteriores e esperado, porque este recorte remove tambem o efeito de tempo entre campanhas.',
  concat('Baseada em ', format_number(m.n_pares, 0), ' pares de disparo. Probabilidade de ser acaso: ',
         format_number(m.p_valor, 6), '.'),
  'vt_res_06_mesma_campanha'
FROM vt_res_06_mesma_campanha m

/* ---------------------------------------------------------------- BLOCO C -- */
UNION ALL
SELECT s.grupo, 'C. Robustez', 20, 'Campanhas em que o Golden Record venceu',
  round(CAST(100.0 * s.fracao_vitorias AS DOUBLE), 4), '%',
  'Percentual das campanhas com volume suficiente em que o telefone recomendado entregou mais.',
  'Teste do sinal. Cada campanha vale um voto, independente do tamanho, o que complementa o estimador ponderado da linha 13.',
  'Percentual alto indica efeito generalizado, e nao concentrado em poucas campanhas grandes. E o argumento mais simples contra a hipotese de coincidencia.',
  concat(format_number(s.vitorias, 0), ' vitorias contra ', format_number(s.derrotas, 0),
         ' derrotas em ', format_number(s.campanhas, 0), ' campanhas avaliadas.'),
  'vt_res_08_teste_sinal'
FROM vt_res_08_teste_sinal s

UNION ALL
SELECT x.grupo, 'C. Robustez', 21, 'Diferenca excluindo a maior campanha',
  round(CAST(100.0 * x.diferenca AS DOUBLE), 4), 'p.p.',
  'Repeticao da comparacao bruta sem a campanha de maior volume.',
  'Mesma conta da linha 12, removendo integralmente a campanha que mais pesa no total.',
  'Valor proximo ao da linha 12 afasta a hipotese de que o resultado depende de uma unica campanha atipica.',
  concat('Campanha removida do calculo: ', x.campanha_excluida, '.'),
  'vt_res_08_sem_maior'
FROM vt_res_08_sem_maior x

UNION ALL
SELECT r.grupo, 'C. Robustez', 22, 'Diferenca com regra exata de comparacao',
  round(CAST(100.0 * r.diferenca AS DOUBLE), 4), 'p.p.',
  'Repeticao da comparacao exigindo numero identico, sem tolerancia de formatacao.',
  'Mesma conta da linha 12, tratando como concordante apenas a coincidencia caractere por caractere.',
  'Valor proximo ao da linha 12 mostra que a conclusao nao e artefato da regra que despreza nono digito e codigo de pais.',
  'Compare diretamente com a linha 12. Uma queda grande indicaria dependencia da regra de comparacao.',
  'vt_res_08_regra_exata'
FROM vt_res_08_regra_exata r

UNION ALL
SELECT sel.grupo, 'C. Robustez', 23, 'Diferenca de entrega entre clientes com e sem Golden Record',
  round(CAST(100.0 * sel.diferenca AS DOUBLE), 4), 'p.p.',
  'Compara a entrega dos dois grupos sem olhar qual telefone foi usado.',
  'Taxa de entrega dos disparos com cobertura menos taxa dos disparos sem cobertura.',
  'Nao invalida o efeito do telefone. Delimita ate onde a conclusao pode ser estendida: um valor alto indica que os clientes cobertos ja sao mais faceis de alcancar, e que extrapolar para os demais e premissa, nao medicao.',
  concat('Sao ', format_number(sel.envios_sem_gr, 0), ' disparos sem cobertura, com taxa de ',
         format_number(100.0 * sel.taxa_sem_gr, 2), ' por cento.'),
  'vt_res_04_selecao'
FROM vt_res_04_selecao sel

/* ---------------------------------------------------------------- BLOCO D -- */
UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 30, 'Custo total dos disparos',
  round(CAST(c.custo_total AS DOUBLE), 2), 'R$',
  'Valor investido em disparos de SMS no periodo analisado.',
  concat('Disparos multiplicados pelo custo unitario de ', format_number(c.custo_sms, 4), ' reais.'),
  'E o denominador da conversa de eficiencia. Todo ganho apresentado adiante deve ser comparado a este montante.',
  concat(format_number(c.disparos, 0), ' disparos ao custo unitario informado no parametro custo_sms.'),
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 31, 'Custo em disparos que nao chegam',
  round(CAST(c.custo_desperdicado AS DOUBLE), 2), 'R$',
  'Parcela do investimento gasta com SMS que nao foram entregues.',
  'Insucessos multiplicados pelo custo unitario.',
  'E dinheiro que sai do caixa sem nenhuma contrapartida. Reduzir esta linha e o objetivo direto de adotar o Golden Record.',
  concat('Sao ', format_number(c.insucessos, 0), ' disparos sem entrega, ou ',
         format_number(100.0 * c.fracao_desperdicada, 1), ' por cento do investimento.'),
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 32, 'Custo por SMS entregue hoje',
  round(CAST(c.custo_por_entrega AS DOUBLE), 6), 'R$',
  'Quanto custa, na pratica, cada SMS que efetivamente chega ao destino.',
  'Custo unitario dividido pela taxa de entrega geral.',
  'E a metrica de eficiencia de midia mais honesta, porque incorpora o desperdicio. O preco de tabela do disparo e menor do que o preco real de uma entrega.',
  concat('O disparo custa ', format_number(c.custo_sms, 4), ' reais, mas cada entrega custa ',
         format_number(c.custo_por_entrega, 4), ' reais.'),
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 33, 'Custo por entrega usando o telefone recomendado',
  round(CAST(c.custo_por_entrega_concordante AS DOUBLE), 6), 'R$',
  'Custo real de uma entrega quando o numero acionado e o telefone de ranking 1.',
  'Custo unitario dividido pela taxa de entrega do braco concordante.',
  'Mostra o patamar de eficiencia alcancavel. Quanto mais disparos migrarem para o telefone recomendado, mais o custo medio da linha 32 se aproxima deste valor.',
  'Compare com a linha seguinte para dimensionar o desperdicio de acionar o numero errado.',
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 34, 'Custo por entrega usando outro telefone',
  round(CAST(c.custo_por_entrega_discordante AS DOUBLE), 6), 'R$',
  'Custo real de uma entrega quando o numero acionado difere do telefone de ranking 1.',
  'Custo unitario dividido pela taxa de entrega do braco divergente.',
  'E quanto a operacao paga hoje, por entrega, na parcela dos disparos que nao usa a recomendacao.',
  concat('Uma entrega por esse caminho custa ',
         format_number(100.0 * (c.custo_por_entrega_discordante / nullif(c.custo_por_entrega_concordante, 0) - 1), 1),
         ' por cento a mais que pelo telefone recomendado.'),
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 35, 'Sobrecusto por entrega ao acionar o numero errado',
  round(CAST(c.sobrecusto_por_entrega AS DOUBLE), 6), 'R$',
  'Diferenca de custo entre alcancar o cliente pelo numero errado e pelo telefone recomendado.',
  'Linha 34 menos linha 33.',
  'E a metrica de bolso do estudo. Multiplicada pelo volume de entregas obtidas fora da recomendacao, dimensiona o desperdicio estrutural do processo atual.',
  concat('A cada cem mil entregas obtidas fora da recomendacao, o sobrecusto e de ',
         format_number(100000 * c.sobrecusto_por_entrega, 2), ' reais.'),
  'vt_res_09_custo_atual'
FROM vt_res_09_custo_atual c

UNION ALL
SELECT cc.grupo, 'D. Valuation pelo custo de disparo', 36 + cc.ordem,
  concat('Valor equivalente em midia, cenario ', cc.cenario),
  round(CAST(cc.valor_equivalente_midia AS DOUBLE), 2), 'R$',
  'Quanto custaria comprar hoje, em disparos adicionais, o mesmo numero de entregas que a adocao do Golden Record produziria.',
  'Entregas liquidas do cenario multiplicadas pelo custo real por entrega da linha 32.',
  CASE cc.cenario
    WHEN 'TETO' THEN 'Limite superior logico, nao previsao. Assume que todo insucesso com telefone divergente viraria entrega, o que nenhum canal alcanca.'
    WHEN 'CALIBRADO_GLOBAL' THEN 'Aplica aos candidatos a taxa que o telefone recomendado de fato tem quando e usado, medida em toda a base do grupo.'
    WHEN 'CALIBRADO_CAMPANHA' THEN 'Cenario central recomendado. Cada candidato recebe a taxa observada do telefone recomendado dentro da propria campanha.'
    WHEN 'EVIDENCIA_EXTRAPOLADA' THEN 'Cenario de estresse, detalhado na linha 61 do bloco E. Costuma ficar abaixo dos demais e pode ficar negativo.'
    ELSE 'Chao de seguranca. Conta apenas o que ja foi observado, sem extrapolar para clientes sem historico.'
  END,
  concat('Entregas liquidas de ', format_number(cc.entregas_liquidas, 0),
         ', levando o custo por entrega de ', format_number(cc.custo_por_entrega, 4),
         ' para ', format_number(cc.custo_por_entrega_projetado, 4), ' reais.'),
  'vt_res_09_custo_cenario'
FROM vt_res_09_custo_cenario cc

UNION ALL
SELECT cc.grupo, 'D. Valuation pelo custo de disparo', 42, 'Queda no custo por entrega, cenario central',
  round(CAST(cc.queda_custo_por_entrega AS DOUBLE), 6), 'R$',
  'Reducao do custo real de cada entrega apos a adocao, no cenario central.',
  'Custo por entrega atual menos custo por entrega projetado, mantendo o mesmo orcamento de disparos.',
  'Traduz o ganho para a linguagem de eficiencia de midia. O orcamento nao muda, o que muda e quantas entregas ele compra.',
  concat('Queda de ', format_number(100.0 * cc.queda_custo_por_entrega / nullif(cc.custo_por_entrega, 0), 2),
         ' por cento no custo por entrega.'),
  'vt_res_09_custo_cenario'
FROM vt_res_09_custo_cenario cc WHERE cc.cenario = 'CALIBRADO_CAMPANHA'

/* ---------------------------------------------------------------- BLOCO E -- */
UNION ALL
SELECT a.grupo, 'E. Valuation pela conversao', 50, 'Conversoes estimadas hoje',
  round(CAST(a.conversoes_hoje AS DOUBLE), 1), 'conversoes',
  'Quantidade de conversoes que as entregas atuais geram, segundo a premissa comercial.',
  concat('Entregas multiplicadas pela taxa de conversao de ', format_number(100.0 * a.taxa_conversao, 4), ' por cento.'),
  'E a base de comparacao do bloco. Se a taxa de conversao adotada nao corresponder a realidade da operacao, todo este bloco se desloca proporcionalmente, mas o bloco D permanece valido.',
  concat('Cada entrega vale ', format_number(a.valor_por_entrega, 4),
         ' reais em valor esperado, combinando taxa e ticket.'),
  'vt_res_10_conversao_atual'
FROM vt_res_10_conversao_atual a

UNION ALL
SELECT a.grupo, 'E. Valuation pela conversao', 51, 'Receita estimada hoje',
  round(CAST(a.receita_hoje AS DOUBLE), 2), 'R$',
  'Retorno gerado pelas entregas atuais, segundo a premissa comercial.',
  concat('Conversoes estimadas multiplicadas pelo ticket de ', format_number(a.valor_conversao, 2), ' reais.'),
  'Serve para dimensionar o ganho incremental em termos relativos, e nao apenas absolutos.',
  concat('Retorno atual de ', format_number(a.retorno_por_real, 2),
         ' reais para cada real investido em disparo.'),
  'vt_res_10_conversao_atual'
FROM vt_res_10_conversao_atual a

UNION ALL
SELECT a.grupo, 'E. Valuation pela conversao', 52, 'Valor de cada ponto percentual de entrega',
  round(CAST(a.valor_por_ponto_percentual AS DOUBLE), 2), 'R$',
  'Quanto vale, em receita, elevar em um ponto percentual a taxa de entrega da base coberta.',
  'Um centesimo dos disparos com cobertura, multiplicado pelo valor esperado de cada entrega.',
  'E a regua para converter qualquer ganho de entrega em dinheiro sem refazer a conta. Multiplique este valor pela diferenca em pontos percentuais que se deseja avaliar.',
  'Aplique sobre a linha 13 para obter o valor do efeito medido com controle por campanha.',
  'vt_res_10_conversao_atual'
FROM vt_res_10_conversao_atual a

UNION ALL
SELECT cv.grupo, 'E. Valuation pela conversao', 53 + cv.ordem,
  concat('Receita incremental, cenario ', cv.cenario),
  round(CAST(cv.receita_incremental AS DOUBLE), 2), 'R$',
  'Retorno adicional gerado pelas entregas que hoje nao acontecem e passariam a acontecer.',
  'Entregas liquidas do cenario multiplicadas pela taxa de conversao e pelo ticket medio.',
  CASE cv.cenario
    WHEN 'TETO' THEN 'Limite superior logico, nao previsao. Use para dizer que nem no melhor caso o ganho passaria deste valor.'
    WHEN 'CALIBRADO_GLOBAL' THEN 'Usa a taxa real do telefone recomendado na base inteira do grupo. Mais realista que o teto, porem mistura campanhas de naturezas distintas numa media unica.'
    WHEN 'CALIBRADO_CAMPANHA' THEN 'Cenario central recomendado para o valuation. Cada candidato recebe a taxa observada do telefone recomendado dentro da propria campanha, o que respeita periodo, mensagem e publico.'
    WHEN 'EVIDENCIA_EXTRAPOLADA' THEN 'Cenario de estresse. Mede a taxa do telefone recomendado apenas entre clientes em que ele ja foi acionado e projeta essa taxa para todos. Esse subgrupo nao e neutro: sao clientes para os quais a operacao ja precisou tentar mais de um numero, ou seja, os mais dificeis. A taxa ali e baixa, entao as recuperacoes encolhem enquanto as perdas, calculadas como um menos essa taxa, incham, e o saldo pode ficar negativo. O numero descreve o subgrupo dificil, nao o desempenho esperado do Golden Record. Leia junto com as linhas 61 e 62.'
    ELSE 'Chao de seguranca. Conta apenas candidatos cujo telefone recomendado ja foi acionado para o mesmo cliente e comprovadamente entregou, descontando perdas igualmente comprovadas. Nao extrapola nada, e por isso e o numero mais dificil de contestar e tambem o mais incompleto.'
  END,
  concat('Entregas liquidas de ', format_number(cv.entregas_liquidas, 0), ', equivalentes a ',
         format_number(cv.conversoes_incrementais, 1), ' conversoes e a ',
         format_number(100.0 * cv.pp_incremental, 2), ' ponto percentual de entrega.'),
  'vt_res_10_conversao_cenario'
FROM vt_res_10_conversao_cenario cv

UNION ALL
SELECT ev.grupo, 'E. Valuation pela conversao', 61,
  'Entrega do telefone recomendado entre clientes em que ele ja foi acionado',
  round(CAST(100.0 * ev.taxa_historica AS DOUBLE), 4), '%',
  'Taxa de entrega observada do telefone de ranking 1, restrita aos clientes com insucesso divergente para os quais esse numero ja foi acionado alguma vez.',
  'Media da taxa de entrega do braco concordante, calculada cliente a cliente dentro desse subgrupo.',
  'Esta linha explica o cenario de evidencia extrapolada. Compare com a linha 10: a distancia entre as duas mostra que o subgrupo com historico e formado por clientes sistematicamente mais dificeis, e que projetar a taxa deles para toda a base subestima o desempenho do Golden Record.',
  concat('Sao ', format_number(ev.candidatos - ev.sem_historico, 0),
         ' candidatos com historico, dos quais ', format_number(ev.com_entrega_provada, 0),
         ' ja tiveram entrega comprovada no numero recomendado.'),
  'vt_res_07_evidencia'
FROM vt_res_07_evidencia ev

UNION ALL
SELECT ev.grupo, 'E. Valuation pela conversao', 62,
  'Candidatos sem historico do telefone recomendado',
  round(CAST(100.0 * ev.fracao_sem_historico AS DOUBLE), 4), '%',
  'Fracao dos insucessos divergentes cujo telefone de ranking 1 nunca foi acionado para aquele cliente.',
  'Candidatos sem nenhum disparo concordante registrado, divididos pelo total de candidatos.',
  'Mede o grau de extrapolacao exigido pelos cenarios calibrados. Quanto maior, mais o resultado depende de projecao e menos de observacao direta, e mais util se torna a leitura conjunta do piso e do teto.',
  concat('De ', format_number(ev.candidatos, 0), ' candidatos, ',
         format_number(ev.sem_historico, 0), ' nunca tiveram o numero recomendado acionado.'),
  'vt_res_07_evidencia'
FROM vt_res_07_evidencia ev

UNION ALL
SELECT sen.grupo, 'E. Valuation pela conversao', 63,
  'Receita incremental com metade da taxa de conversao',
  round(CAST(sen.receita_incremental AS DOUBLE), 2), 'R$',
  'Cenario central recalculado com a taxa de conversao reduzida a metade e o ticket mantido.',
  'Entregas liquidas do cenario central multiplicadas pela taxa reduzida e pelo ticket base.',
  'Mostra a sensibilidade do valuation a premissa comercial mais incerta. Se o projeto continua atrativo aqui, a decisao nao depende de acertar a taxa de conversao.',
  concat('Taxa aplicada de ', format_number(100.0 * sen.taxa_aplicada, 4), ' por cento.'),
  'vt_res_10_sensibilidade'
FROM vt_res_10_sensibilidade sen
WHERE sen.cenario = 'CALIBRADO_CAMPANHA'
  AND sen.rotulo_taxa = 'conversao_metade' AND sen.rotulo_valor = 'ticket_base'

UNION ALL
SELECT sen.grupo, 'E. Valuation pela conversao', 64,
  'Receita incremental com o dobro da taxa de conversao',
  round(CAST(sen.receita_incremental AS DOUBLE), 2), 'R$',
  'Cenario central recalculado com a taxa de conversao dobrada e o ticket mantido.',
  'Entregas liquidas do cenario central multiplicadas pela taxa dobrada e pelo ticket base.',
  'Completa a faixa de sensibilidade. A grade de nove combinacoes de taxa e ticket esta disponivel na view de origem.',
  concat('Taxa aplicada de ', format_number(100.0 * sen.taxa_aplicada, 4), ' por cento.'),
  'vt_res_10_sensibilidade'
FROM vt_res_10_sensibilidade sen
WHERE sen.cenario = 'CALIBRADO_CAMPANHA'
  AND sen.rotulo_taxa = 'conversao_dobro' AND sen.rotulo_valor = 'ticket_base'

/* ---------------------------------------------------------------- BLOCO F -- */
UNION ALL
SELECT f.grupo, 'F. Ativo de cadastro', 70, 'Clientes que nao recebem SMS em nenhum numero',
  CAST(f.sem_nenhuma_entrega AS DOUBLE), 'CPFs',
  'Clientes com cobertura do Golden Record para os quais nenhum disparo, em nenhum telefone, foi entregue.',
  'CPFs cujo maximo de entrega no periodo e zero.',
  'E a populacao hoje inalcancavel pelo canal. Recuperar parte dela vale mais do que o volume de SMS sugere, porque restabelece um canal de contato inteiro.',
  concat('Representam ', format_number(100.0 * f.fracao_sem_entrega, 2),
         ' por cento dos ', format_number(f.clientes_com_gr, 0), ' clientes com cobertura.'),
  'vt_res_07_cpfs'
FROM vt_res_07_cpfs f

UNION ALL
SELECT f.grupo, 'F. Ativo de cadastro', 71, 'Clientes inalcancaveis com telefone novo disponivel',
  CAST(f.com_telefone_novo AS DOUBLE), 'CPFs',
  'Clientes sem nenhuma entrega para os quais o Golden Record aponta um numero que ainda nao foi acionado.',
  'Subconjunto da linha 70 com insucesso em numero divergente e nenhum disparo previo no telefone recomendado.',
  'E a oportunidade mais concreta de recuperacao de contato, porque existe um numero nunca testado a disposicao. Deve ser o primeiro publico de um piloto.',
  concat('Outros ', format_number(f.gr_ja_falhou, 0),
         ' clientes inalcancaveis ja tiveram o numero recomendado acionado sem sucesso, e para esses o Golden Record nao resolve.'),
  'vt_res_07_cpfs'
FROM vt_res_07_cpfs f

UNION ALL
SELECT f.grupo, 'F. Ativo de cadastro', 72, 'Clientes com telefone recomendado ja comprovado',
  CAST(f.gr_comprovado AS DOUBLE), 'CPFs',
  'Clientes que tiveram insucesso em um numero divergente e entrega comprovada no telefone recomendado.',
  'CPFs com ao menos um disparo concordante entregue e ao menos um disparo divergente sem entrega.',
  'E a evidencia mais forte disponivel sem teste controlado, no nivel do cliente: para essas pessoas o numero que falhou nao e o recomendado, e o recomendado ja provou que chega.',
  'Publico natural para a primeira onda de adocao, porque o risco de troca e proximo de zero.',
  'vt_res_07_cpfs'
FROM vt_res_07_cpfs f

UNION ALL
SELECT v.grupo, 'A. Base e oportunidade', 9, 'Disparos que nao chegam ao destino',
  CAST(v.insucessos AS DOUBLE), 'envios',
  'Volume absoluto de SMS que nao foram entregues no escopo analisado.',
  'Disparos menos entregas.',
  'Fecha o funil de oportunidade. Deste volume, a parcela com cobertura e telefone divergente e o que o Golden Record pode atacar.',
  concat('Ao custo unitario informado, representam ', format_number(v.insucessos * gp.custo_sms, 2), ' reais.'),
  'vt_res_04_volume'
FROM vt_res_04_volume v JOIN vt_grupo_param gp ON v.grupo = gp.grupo

UNION ALL
SELECT b.grupo, 'B. Evidencia causal', 17, 'Entrega com a regra simples do proprio CRM',
  round(CAST(100.0 * b.taxa_regra_simples AS DOUBLE), 4), '%',
  'Taxa de entrega quando o numero acionado e o mais usado pelo proprio CRM para aquele cliente, e esse numero difere do recomendado.',
  'Entregas divididas por envios no grupo em que a heuristica de maior uso aponta um numero diferente do telefone de ranking 1.',
  'E o comparativo justo para o Golden Record. Qualquer operacao consegue adotar essa regra sem investir em cadastro, entao o ganho do Golden Record precisa ser medido a partir daqui, e nao a partir do pior caso.',
  concat('Baseada em ', format_number(b.envios_regra_simples, 0), ' disparos.'),
  'vt_res_11_benchmark'
FROM vt_res_11_benchmark b

UNION ALL
SELECT b.grupo, 'B. Evidencia causal', 18, 'Ganho do Golden Record sobre a regra simples',
  round(CAST(100.0 * b.ganho_sobre_regra_simples AS DOUBLE), 4), 'p.p.',
  'Quanto o telefone recomendado entrega a mais do que o numero mais acionado pelo proprio CRM.',
  'Taxa do telefone recomendado menos taxa da regra simples.',
  'E a resposta a objecao mais dura possivel, a de que qualquer heuristica razoavel produziria o mesmo efeito. Ganho positivo aqui significa que o valor vem do cadastro, e nao apenas de deixar de usar numeros ruins.',
  concat('A regra simples ja captura ', format_number(100.0 * (1 - b.parcela_atribuivel_ao_cadastro), 1),
         ' por cento do efeito total, e o cadastro acrescenta os ',
         format_number(100.0 * b.parcela_atribuivel_ao_cadastro, 1), ' por cento restantes.'),
  'vt_res_11_benchmark'
FROM vt_res_11_benchmark b

UNION ALL
SELECT d.grupo, 'B. Evidencia causal', 19, 'Efeito mediano entre campanhas',
  round(CAST(100.0 * d.mediana AS DOUBLE), 4), 'p.p.',
  'Valor central do efeito quando cada campanha e tratada como uma observacao, sem ponderar por tamanho.',
  'Mediana da diferenca entre os dois bracos, calculada campanha a campanha.',
  'Compare com a diferenca ponderada. Se a mediana for proxima dela, o efeito e homogeneo. Se for muito menor, a media esta sendo puxada por poucas campanhas grandes.',
  concat('Metade das campanhas fica entre ', format_number(100.0 * d.quartil_inferior, 2),
         ' e ', format_number(100.0 * d.quartil_superior, 2), ' pontos percentuais, com extremos de ',
         format_number(100.0 * d.minimo, 2), ' a ', format_number(100.0 * d.maximo, 2), '.'),
  'vt_res_11_distribuicao'
FROM vt_res_11_distribuicao d

UNION ALL
SELECT f.grupo, 'C. Robustez', 24, 'Menor efeito entre as faixas de porte de campanha',
  round(CAST(100.0 * min(f.diferenca) AS DOUBLE), 4), 'p.p.',
  'Efeito na faixa de porte em que ele e mais fraco.',
  'Diferenca entre os dois bracos calculada dentro de cada faixa de volume, tomando a menor delas.',
  'Se o menor efeito ainda for positivo e relevante, a adocao nao depende do porte da campanha e pode ser generalizada.',
  concat('Faixa com menor efeito: ', min_by(f.faixa_volume, f.diferenca), '.'),
  'vt_res_11_por_faixa'
FROM vt_res_11_por_faixa f GROUP BY f.grupo

UNION ALL
SELECT f.grupo, 'C. Robustez', 25, 'Maior efeito entre as faixas de porte de campanha',
  round(CAST(100.0 * max(f.diferenca) AS DOUBLE), 4), 'p.p.',
  'Efeito na faixa de porte em que ele e mais forte.',
  'Diferenca entre os dois bracos calculada dentro de cada faixa de volume, tomando a maior delas.',
  'A distancia entre esta linha e a anterior mede o quanto o porte da campanha modifica o efeito, e indica se vale priorizar por porte.',
  concat('Faixa com maior efeito: ', max_by(f.faixa_volume, f.diferenca), '.'),
  'vt_res_11_por_faixa'
FROM vt_res_11_por_faixa f GROUP BY f.grupo

UNION ALL
SELECT i.grupo, 'C. Robustez', 26, 'Menor efeito entre as faixas de intensidade de contato',
  round(CAST(100.0 * min(i.diferenca) AS DOUBLE), 4), 'p.p.',
  'Efeito no perfil de cliente em que ele e mais fraco, considerando quantos SMS o cliente recebeu.',
  'Diferenca entre os dois bracos calculada dentro de cada faixa de quantidade de envios por cliente.',
  'Ataca a hipotese de que a concordancia de telefone apenas identifica clientes mais engajados. Se o efeito persiste em quem recebeu um unico SMS, a explicacao por engajamento perde forca.',
  concat('Faixa com menor efeito: ', min_by(i.faixa, i.diferenca), '.'),
  'vt_res_11_por_intensidade'
FROM vt_res_11_por_intensidade i GROUP BY i.grupo

UNION ALL
SELECT i.grupo, 'C. Robustez', 27, 'Maior efeito entre as faixas de intensidade de contato',
  round(CAST(100.0 * max(i.diferenca) AS DOUBLE), 4), 'p.p.',
  'Efeito no perfil de cliente em que ele e mais forte.',
  'Diferenca entre os dois bracos calculada dentro de cada faixa de quantidade de envios por cliente.',
  'A distancia para a linha anterior indica se o ganho se concentra em um perfil especifico de cliente, o que orientaria a priorizacao.',
  concat('Faixa com maior efeito: ', max_by(i.faixa, i.diferenca), '.'),
  'vt_res_11_por_intensidade'
FROM vt_res_11_por_intensidade i GROUP BY i.grupo

UNION ALL
SELECT r.grupo, 'C. Robustez', 28, 'Regioes em que o Golden Record entrega mais',
  round(CAST(100.0 * r.fracao_com_ganho AS DOUBLE), 4), '%',
  'Percentual dos codigos de area com volume suficiente em que o telefone recomendado entrega mais que os demais.',
  'Diferenca entre os dois bracos calculada dentro de cada codigo de area, considerando apenas areas com pelo menos mil disparos em cada braco.',
  'Verifica se o ganho e nacional ou concentrado em algumas pracas. Percentual alto indica que a adocao nao precisa de recorte geografico.',
  concat('Foram ', format_number(r.ddds_avaliados, 0), ' areas avaliadas, com efeito mediano de ',
         format_number(100.0 * r.mediana, 2), ' e extremos de ',
         format_number(100.0 * r.minimo, 2), ' a ', format_number(100.0 * r.maximo, 2), ' pontos percentuais.'),
  'vt_res_11_por_ddd'
FROM vt_res_11_por_ddd r

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 43, 'Campanhas que concentram metade do ganho',
  CAST(c.campanhas_para_metade AS DOUBLE), 'campanhas',
  'Quantidade de campanhas necessarias, da maior para a menor, para acumular metade das entregas recuperadas.',
  'Ordenacao das campanhas por entregas liquidas do cenario central, com soma acumulada ate cruzar metade do total.',
  'Define a estrategia de adocao. Numero pequeno significa que um piloto dirigido a poucas campanhas captura a maior parte do valor, com muito menos esforco que a adocao geral.',
  concat('De ', format_number(c.campanhas_com_ganho, 0), ' campanhas com ganho positivo.'),
  'vt_res_11_concentracao'
FROM vt_res_11_concentracao c

UNION ALL
SELECT c.grupo, 'D. Valuation pelo custo de disparo', 44, 'Participacao das dez maiores campanhas no ganho',
  round(CAST(100.0 * c.fracao_dez_maiores AS DOUBLE), 4), '%',
  'Fracao das entregas recuperadas que vem das dez campanhas de maior ganho.',
  'Soma acumulada das entregas liquidas das dez primeiras campanhas, dividida pelo total.',
  'Complementa a linha anterior. Participacao alta favorece comecar por essas campanhas e medir resultado antes de generalizar.',
  concat('Sao ', format_number(c.ganho_das_dez_maiores, 0), ' entregas de um total de ',
         format_number(c.total_liquidas, 0), '.'),
  'vt_res_11_concentracao'
FROM vt_res_11_concentracao c

UNION ALL
SELECT s.grupo, 'E. Valuation pela conversao', 65, 'Entregas atuais colocadas em risco',
  CAST(s.em_risco AS DOUBLE), 'envios',
  'Disparos que hoje sao entregues com um numero diferente do recomendado e que a adocao substituiria.',
  'Contagem dos envios entregues cuja classificacao e telefone divergente, no cenario central.',
  'E a primeira pergunta de quem teme a mudanca. O saldo liquido dos cenarios ja desconta a perda esperada sobre este volume, mas o numero bruto precisa estar visivel para a conversa ser honesta.',
  concat('Destes, o cenario central estima ', format_number(s.perdidas, 0),
         ' perdas, ja descontadas das entregas liquidas.'),
  'vt_res_07_saldo'
FROM vt_res_07_saldo s WHERE s.cenario = 'CALIBRADO_CAMPANHA'

UNION ALL
SELECT fe.grupo, 'E. Valuation pela conversao', 66, 'Receita incremental, limite inferior estatistico',
  round(CAST(fe.receita_inf AS DOUBLE), 2), 'R$',
  'Piso da receita incremental considerando a margem de erro da propria medicao.',
  'Limite inferior do intervalo de 95 por cento da diferenca bruta, aplicado ao volume com cobertura e ao valor esperado de cada entrega.',
  'Esta faixa e diferente da faixa de cenarios. Os cenarios variam a premissa sobre o comportamento do telefone recomendado. Esta linha varia apenas o acaso amostral, mantendo a premissa fixa. Um intervalo estreito indica que o volume de dados torna a medicao precisa.',
  concat('A diferenca medida fica entre ', format_number(100.0 * fe.dif_inf, 2), ' e ',
         format_number(100.0 * fe.dif_sup, 2), ' pontos percentuais com 95 por cento de confianca.'),
  'vt_res_11_faixa_estatistica'
FROM vt_res_11_faixa_estatistica fe

UNION ALL
SELECT fe.grupo, 'E. Valuation pela conversao', 67, 'Receita incremental, limite superior estatistico',
  round(CAST(fe.receita_sup AS DOUBLE), 2), 'R$',
  'Teto da receita incremental considerando a margem de erro da propria medicao.',
  'Limite superior do intervalo de 95 por cento da diferenca bruta, aplicado ao volume com cobertura e ao valor esperado de cada entrega.',
  'Leia junto com a linha anterior. A largura entre as duas e a incerteza da medicao, e costuma ser muito menor que a distancia entre o piso e o teto de cenarios, que e a incerteza de premissa.',
  'Quando as duas incertezas sao apresentadas juntas, fica claro que a duvida relevante e sobre premissa, e nao sobre volume de dados.',
  'vt_res_11_faixa_estatistica'
FROM vt_res_11_faixa_estatistica fe

UNION ALL
SELECT a.grupo, 'F. Ativo de cadastro', 73, 'Valor do contato recuperavel',
  round(CAST(a.valor_contato_recuperavel AS DOUBLE), 2), 'R$',
  'Retorno estimado de restabelecer contato com os clientes hoje inalcancaveis que possuem um numero ainda nao acionado.',
  'Clientes inalcancaveis com telefone novo, multiplicados pela taxa de entrega do telefone recomendado e pelo valor esperado de cada entrega.',
  'Diferente do restante do bloco de valuation, esta linha monetiza recuperacao de canal, e nao volume de disparo. E o argumento mais estrategico do estudo, porque um cliente sem canal de contato nao responde a nenhuma acao.',
  concat('Sao ', format_number(a.com_telefone_novo, 0), ' clientes, dos quais cerca de ',
         format_number(a.contatos_recuperaveis, 0), ' seriam efetivamente alcancados.'),
  'vt_res_11_ativo_cadastro'
FROM vt_res_11_ativo_cadastro a

UNION ALL
SELECT a.grupo, 'F. Ativo de cadastro', 74, 'Valor do contato ja comprovado',
  round(CAST(a.valor_contato_comprovado AS DOUBLE), 2), 'R$',
  'Retorno estimado do grupo em que o telefone recomendado ja demonstrou entregar para aquele mesmo cliente.',
  'Clientes com entrega comprovada no numero recomendado e insucesso em outro numero, multiplicados pelo valor esperado de cada entrega.',
  'E o publico de risco zero para a primeira onda de adocao, porque o numero alternativo ja provou funcionar para aquela pessoa. Nao ha premissa envolvida na escolha desse publico.',
  concat('Sao ', format_number(a.gr_comprovado, 0), ' clientes nessa condicao.'),
  'vt_res_11_ativo_cadastro'
FROM vt_res_11_ativo_cadastro a

UNION ALL
SELECT e.grupo, 'F. Ativo de cadastro', 75, 'Cadastros que precisariam ser atualizados',
  CAST(e.cpfs_a_atualizar AS DOUBLE), 'CPFs',
  'Clientes cujo telefone no CRM difere do recomendado em ao menos um disparo, e que portanto exigiriam atualizacao cadastral.',
  'Contagem distinta de CPF com ao menos um envio classificado como telefone divergente.',
  'Dimensiona o esforco de implementacao, que ate aqui o valuation nao considerava. Confronte este volume com a capacidade de carga do CRM para estimar prazo de adocao.',
  concat('Representam ', format_number(100.0 * e.fracao_a_atualizar, 1),
         ' por cento dos ', format_number(e.cpfs_com_cobertura, 0), ' clientes com cobertura.'),
  'vt_res_11_esforco'
FROM vt_res_11_esforco e

UNION ALL
SELECT q.grupo, 'G. Qualidade e contexto do dado', 80, 'Registros descartados antes do estudo',
  round(CAST(100.0 * q.fracao_descartada AS DOUBLE), 4), '%',
  'Fracao dos registros recebidos do CRM que nao entrou no estudo por status contraditorio, status ausente ou chave invalida.',
  'Registros descartados divididos pelo total de registros recebidos, antes de qualquer filtro de escopo.',
  'Nao invalida a comparacao, porque o descarte independe de qual telefone foi usado. Reduz a cobertura do estudo e precisa estar visivel para o leitor calibrar a confianca no volume analisado.',
  concat('Sao ', format_number(q.descartados, 0), ' de ', format_number(q.registros, 0),
         ' registros, sendo ', format_number(q.status_contraditorio, 0),
         ' com status contraditorio, ', format_number(q.sem_status, 0),
         ' sem status e ', format_number(q.chave_invalida, 0), ' com chave invalida.'),
  'vt_res_11_qualidade'
FROM vt_res_11_qualidade q

UNION ALL
SELECT rt.grupo, 'G. Qualidade e contexto do dado', 81, 'Disparos que sao repeticao',
  round(CAST(100.0 * rt.fracao_disparos_repetidos AS DOUBLE), 4), '%',
  'Fracao do volume bruto de disparos que representa nova tentativa para o mesmo cliente, campanha e telefone.',
  'Disparos brutos menos disparos consolidados, divididos pelo volume bruto.',
  'Retentativa e custo de midia sem novo alcance. E uma frente de economia independente do Golden Record, e serve de referencia para dimensionar a ordem de grandeza dos ganhos aqui apresentados.',
  concat('Sao ', format_number(rt.disparos_repetidos, 0), ' disparos repetidos, concentrados em ',
         format_number(rt.envios_com_retentativa, 0), ' combinacoes de cliente, campanha e telefone.'),
  'vt_res_11_retentativa'
FROM vt_res_11_retentativa rt

UNION ALL
SELECT sc.grupo, 'G. Qualidade e contexto do dado', 82, 'Vantagem da carga recente sobre a carga antiga',
  round(CAST(100.0 * sc.diferenca AS DOUBLE), 4), 'p.p.',
  'Diferenca de entrega do telefone recomendado entre registros da carga mais recente e registros com mais de doze meses.',
  'Taxa de entrega do braco concordante para registros ingeridos ha ate tres meses menos a mesma taxa para registros com mais de doze meses.',
  'Indica se a atualizacao do cadastro tem valor proprio, alem da escolha do numero. Valor positivo relevante justifica aumentar a frequencia de reprocessamento do Golden Record. Ressalva: sem data de envio na base de campanhas, a idade e medida em relacao a carga mais recente, e nao ao momento do disparo.',
  concat('Carga recente entrega ', format_number(100.0 * sc.taxa_recente, 2),
         ' por cento sobre ', format_number(sc.envios_recente, 0), ' disparos, contra ',
         format_number(100.0 * sc.taxa_antiga, 2), ' por cento sobre ',
         format_number(sc.envios_antiga, 0), ' disparos da carga antiga.'),
  'vt_res_11_safra_contraste'
FROM vt_res_11_safra_contraste sc

UNION ALL
SELECT j.grupo, 'G. Qualidade e contexto do dado', 83, 'Janela coberta pelo estudo',
  CAST(j.dias_cobertos AS DOUBLE), 'dias',
  'Intervalo entre o primeiro e o ultimo registro de disparo dentro do escopo.',
  'Diferenca em dias entre a data minima e a data maxima de registro, mais um.',
  'Define a unidade de tempo de todo o bloco de valuation. Com a janela fechada em doze meses, os valores de receita e de custo passam a ser leitura anual. Sem esta linha, nenhum numero do estudo pode ser anualizado.',
  concat('De ', CAST(j.primeiro_registro AS STRING), ' a ', CAST(j.ultimo_registro AS STRING),
         ', com registro em ', format_number(j.meses_com_registro, 0), ' meses distintos.'),
  'vt_res_11_janela'
FROM vt_res_11_janela j

UNION ALL
SELECT v.grupo, 'G. Qualidade e contexto do dado', 84, 'Disparos em que a recomendacao ja existia',
  round(CAST(100.0 * v.fracao_anteriores AS DOUBLE), 4), '%',
  'Fracao dos disparos cujo registro do Golden Record foi ingerido em data anterior ou igual a do proprio disparo.',
  'Comparacao entre a data de ingestao do registro do Golden Record e a data do registro de disparo.',
  'Afirmar que o Golden Record teria recomendado outro telefone so faz sentido se a recomendacao existisse na epoca. Esta linha mede quanto do estudo atende a essa condicao. Percentual alto elimina a principal ressalva temporal do desenho.',
  concat('Em ', format_number(v.posteriores, 0), ' disparos a recomendacao e posterior ao envio, e em ',
         format_number(v.indeterminadas, 0), ' a data nao pode ser determinada.'),
  'vt_res_11_validade_temporal'
FROM vt_res_11_validade_temporal v

UNION ALL
SELECT e.grupo, 'G. Qualidade e contexto do dado', 85, 'Efeito restrito aos disparos temporalmente validos',
  round(CAST(100.0 * e.diferenca AS DOUBLE), 4), 'p.p.',
  'Diferenca de entrega entre os dois bracos, considerando apenas os disparos em que a recomendacao ja existia.',
  'Mesma conta da diferenca bruta, restrita aos envios cuja data de ingestao do Golden Record antecede a do disparo.',
  'E o teste de sensibilidade da ressalva temporal. Valor proximo ao da diferenca bruta indica que o resultado nao depende de recomendacoes criadas depois das campanhas, e a ameaca deixa de ser relevante.',
  concat('Calculado sobre ', format_number(e.n1 + e.n0, 0), ' disparos temporalmente validos.'),
  'vt_res_11_efeito_temporalmente_valido'
FROM vt_res_11_efeito_temporalmente_valido e

UNION ALL
SELECT t.grupo, 'H. Evolucao ao longo dos meses', 90, 'Meses com disparo no escopo',
  CAST(t.meses AS DOUBLE), 'meses',
  'Quantidade de meses distintos com registro de disparo dentro da janela do estudo.',
  'Contagem de meses distintos na serie mensal, considerando apenas meses em que os dois bracos existem.',
  'Define a robustez de toda a leitura temporal deste bloco. Com poucos meses, tendencia e ruido se confundem e as inclinacoes devem ser lidas como indicio, nao como conclusao.',
  concat('Serie disponivel para consulta detalhada na view vt_res_11_mensal_calc, com um registro por mes.'),
  'vt_res_11_tendencia'
FROM vt_res_11_tendencia t

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 91, 'Variacao da entrega SEM o telefone recomendado',
  round(CAST(100.0 * pu.variacao_sem_recomendado AS DOUBLE), 4), 'p.p.',
  'Diferenca na taxa de entrega do braco divergente entre o ultimo e o primeiro mes da janela.',
  'Taxa de entrega dos disparos que nao usaram o telefone recomendado, no ultimo mes, menos a mesma taxa no primeiro mes.',
  'Este e o indicador que responde se a operacao esta melhorando por conta propria, sem o cadastro. Valor positivo significa que a entrega subiu por outra causa, como higienizacao de base, mudanca de fornecedor ou perfil de campanha. Nesse caso, o ganho atribuivel ao Golden Record deve ser lido contra esse pano de fundo, e nao como se toda a melhora viesse dele.',
  concat('De ', format_number(100.0 * pu.sem_recomendado_inicio, 2), ' por cento em ', pu.primeiro_mes,
         ' para ', format_number(100.0 * pu.sem_recomendado_fim, 2), ' por cento em ', pu.ultimo_mes, '.'),
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 92, 'Variacao da entrega COM o telefone recomendado',
  round(CAST(100.0 * pu.variacao_com_recomendado AS DOUBLE), 4), 'p.p.',
  'Diferenca na taxa de entrega do braco concordante entre o ultimo e o primeiro mes da janela.',
  'Taxa de entrega dos disparos que coincidiram com o telefone recomendado, no ultimo mes, menos a mesma taxa no primeiro mes.',
  'Compare com a linha anterior. Se as duas subirem juntas, a melhora e da operacao e nao do cadastro. Se apenas esta subir, o cadastro esta ganhando qualidade. Se esta cair enquanto a outra sobe, o cadastro esta envelhecendo.',
  concat('De ', format_number(100.0 * pu.com_recomendado_inicio, 2), ' por cento em ', pu.primeiro_mes,
         ' para ', format_number(100.0 * pu.com_recomendado_fim, 2), ' por cento em ', pu.ultimo_mes, '.'),
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 93, 'Vantagem do Golden Record no primeiro mes',
  round(CAST(100.0 * pu.vantagem_inicio AS DOUBLE), 4), 'p.p.',
  'Diferenca entre os dois bracos no mes mais antigo da janela.',
  'Taxa do braco concordante menos taxa do braco divergente, dentro do primeiro mes.',
  'E o ponto de partida da serie. Serve de referencia para julgar se a vantagem se manteve ao longo do periodo.',
  concat('Mes de referencia: ', pu.primeiro_mes, ', com ', format_number(pu.disparos_inicio, 0), ' disparos.'),
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 94, 'Vantagem do Golden Record no ultimo mes',
  round(CAST(100.0 * pu.vantagem_fim AS DOUBLE), 4), 'p.p.',
  'Diferenca entre os dois bracos no mes mais recente da janela.',
  'Taxa do braco concordante menos taxa do braco divergente, dentro do ultimo mes.',
  'E a leitura mais atual do efeito, e a que melhor representa o que se pode esperar de uma adocao a partir de agora. Se estiver proxima da linha 93, o cadastro esta estavel.',
  concat('Mes de referencia: ', pu.ultimo_mes, ', com ', format_number(pu.disparos_fim, 0), ' disparos.'),
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 95, 'Variacao da vantagem entre o primeiro e o ultimo mes',
  round(CAST(100.0 * pu.variacao_vantagem AS DOUBLE), 4), 'p.p.',
  'Quanto a vantagem do telefone recomendado cresceu ou encolheu ao longo da janela.',
  'Vantagem no ultimo mes menos vantagem no primeiro mes.',
  'Valor negativo indica cadastro perdendo poder de discriminacao, o que justifica aumentar a frequencia de carga. Valor positivo indica que as cargas recentes estao acrescentando informacao. Valor proximo de zero indica estabilidade, que e o cenario mais confortavel para projetar o valuation para frente.',
  'Leia junto com a linha 96, que usa todos os meses em vez de apenas as duas pontas e por isso e menos sensivel a um mes atipico.',
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

UNION ALL
SELECT t.grupo, 'H. Evolucao ao longo dos meses', 96, 'Tendencia mensal da vantagem',
  round(CAST(100.0 * t.inclinacao_vantagem AS DOUBLE), 4), 'p.p. por mes',
  'Inclinacao da reta ajustada a serie mensal da vantagem do telefone recomendado.',
  'Minimos quadrados sobre os valores mensais da diferenca entre os dois bracos, com o mes como variavel independente.',
  'E a leitura de tendencia mais confiavel do bloco, porque usa todos os meses e nao apenas as pontas. Multiplicada por doze, estima quanto a vantagem mudaria em um ano mantido o ritmo atual. Sinal negativo relevante e o gatilho para revisar a periodicidade de atualizacao do cadastro.',
  concat('Mantido o ritmo, a vantagem mudaria ',
         format_number(100.0 * t.inclinacao_vantagem * 12, 2), ' pontos percentuais em doze meses.'),
  'vt_res_11_tendencia'
FROM vt_res_11_tendencia t

UNION ALL
SELECT t.grupo, 'H. Evolucao ao longo dos meses', 97, 'Tendencia mensal da entrega sem o telefone recomendado',
  round(CAST(100.0 * t.inclinacao_sem_recomendado AS DOUBLE), 4), 'p.p. por mes',
  'Inclinacao da reta ajustada a serie mensal da taxa de entrega do braco divergente.',
  'Minimos quadrados sobre os valores mensais da taxa de entrega dos disparos que nao usaram o telefone recomendado.',
  'E a tendencia da operacao sem o cadastro, ou seja, a linha de base contra a qual o Golden Record deve ser julgado. Se ela for positiva e relevante, parte da melhora observada no periodo nao pode ser creditada ao cadastro, e o valuation deve ser apresentado com essa ressalva.',
  concat('Em ', format_number(t.meses, 0), ' meses avaliados, o Golden Record ficou a frente em ',
         format_number(t.meses_com_ganho, 0), ' deles.'),
  'vt_res_11_tendencia'
FROM vt_res_11_tendencia t

UNION ALL
SELECT pu.grupo, 'H. Evolucao ao longo dos meses', 98, 'Variacao da cobertura do Golden Record',
  round(CAST(100.0 * pu.variacao_cobertura AS DOUBLE), 4), 'p.p.',
  'Diferenca na fracao de disparos com telefone cadastrado, entre o ultimo e o primeiro mes.',
  'Cobertura do Golden Record no ultimo mes menos cobertura no primeiro mes.',
  'Cobertura crescente amplia o alcance da iniciativa ao longo do tempo e favorece projetar o valuation para frente. Cobertura decrescente indica que a base de clientes acionados esta se afastando do cadastro, e o valor estimado tende a encolher.',
  concat('De ', format_number(100.0 * pu.cobertura_inicio, 2), ' por cento em ', pu.primeiro_mes,
         ' para ', format_number(100.0 * pu.cobertura_fim, 2), ' por cento em ', pu.ultimo_mes, '.'),
  'vt_res_11_primeiro_ultimo'
FROM vt_res_11_primeiro_ultimo pu

;


/* -----------------------------------------------------------------------------
   12.1  CONTEXTO PARA LEITURA DOS PERCENTUAIS

   Nem todo percentual do resumo tem o mesmo denominador, e ler as linhas em
   sequência induz a erro. Três indicadores do bloco A deixam o problema claro:

     cobertura sobre disparos            incide sobre todos os disparos
     disparos com telefone divergente    incide sobre os disparos com cobertura
     insucessos com telefone divergente  incide sobre os insucessos com cobertura

   Cada um é uma fração de uma base menor que a anterior. Lidos um abaixo do
   outro, o último parece o maior dos três quando na verdade é o menor.

   A saída resolve isso com cinco colunas de contexto:

     base_de_calculo         nomeia o denominador em palavras, que é sempre a
                             etapa imediatamente anterior do funil
     quantidade              numerador absoluto do indicador
     quantidade_base         denominador absoluto, ou seja, o tamanho da etapa
                             anterior
     pct_da_etapa_anterior   quantidade dividida por quantidade_base
     pct_do_total            quantidade dividida pela etapa original, que é o
                             total de disparos analisados

   Quando pct_da_etapa_anterior e pct_do_total coincidem, o indicador já estava
   na base comum. Quando divergem, a distância entre as duas colunas é
   exatamente a fração da fração que causava a confusão.

   O funil completo, com as duas leituras lado a lado, fica assim:

     disparos analisados          etapa original       100 por cento
     com cobertura                do total             pct_do_total = pct anterior
     com telefone divergente      dos com cobertura    pct anterior maior que pct_do_total
     insucessos com cobertura     dos insucessos       idem
     candidatos a recuperacao     dos insucessos com cobertura   idem

   A coluna quantidade da última etapa é o número de candidatos que os cenários
   da seção 07 multiplicam pela taxa de calibração, o que torna o funil e o
   valuation uma conta só.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_12_contexto AS
SELECT
  v.grupo,
  v.disparos                  AS total_disparos,
  v.clientes                  AS total_clientes,
  v.entregas                  AS total_entregas,
  v.insucessos                AS total_insucessos,
  v.disparos_com_gr           AS disparos_com_cobertura,
  v.clientes_com_gr           AS clientes_com_cobertura,
  d.envios                    AS disparos_divergentes,
  a.gr_diferente              AS candidatos_recuperacao,
  a.gr_diferente + a.gr_igual AS insucessos_com_cobertura
FROM vt_res_04_volume v
LEFT JOIN (
  SELECT grupo, envios FROM vt_res_04_concordancia WHERE classe_concordancia = 'DIFERENTE'
) d ON v.grupo = d.grupo
LEFT JOIN vt_res_04_anatomia_insucesso a ON v.grupo = a.grupo
;


/* -----------------------------------------------------------------------------
   12.2  SAÍDA DO ESTUDO 1
----------------------------------------------------------------------------- */
WITH contexto AS (
  SELECT
    r.grupo,
    r.bloco,
    r.ordem,
    r.indicador,
    r.valor,
    r.unidade,
    CASE r.ordem
      WHEN  4 THEN 'todos os disparos do escopo'
      WHEN  5 THEN 'todos os disparos do escopo'
      WHEN  6 THEN 'todos os clientes do escopo'
      WHEN  7 THEN 'apenas os disparos com cobertura do Golden Record'
      WHEN  8 THEN 'apenas os insucessos com cobertura do Golden Record'
      WHEN  9 THEN 'todos os disparos do escopo'
      WHEN 10 THEN 'disparos do braco concordante'
      WHEN 11 THEN 'disparos do braco divergente'
      WHEN 12 THEN 'diferenca entre os dois bracos, sem controle'
      WHEN 13 THEN 'diferenca entre os dois bracos, ponderada dentro de cada campanha'
      WHEN 14 THEN 'razao de chances entre os dois bracos'
      WHEN 15 THEN 'clientes com disparo nos dois bracos'
      WHEN 16 THEN 'pares de disparo do mesmo cliente na mesma campanha'
      WHEN 17 THEN 'disparos no numero mais acionado que difere do recomendado'
      WHEN 18 THEN 'diferenca entre o telefone recomendado e a regra simples'
      WHEN 19 THEN 'campanhas com volume minimo nos dois bracos, uma observacao cada'
      WHEN 20 THEN 'campanhas com volume minimo nos dois bracos'
      WHEN 21 THEN 'diferenca entre os dois bracos, excluida a maior campanha'
      WHEN 22 THEN 'diferenca entre os dois bracos, com regra estrita de comparacao'
      WHEN 23 THEN 'diferenca entre disparos com e sem cobertura'
      WHEN 24 THEN 'faixa de porte de campanha com menor efeito'
      WHEN 25 THEN 'faixa de porte de campanha com maior efeito'
      WHEN 26 THEN 'faixa de intensidade de contato com menor efeito'
      WHEN 27 THEN 'faixa de intensidade de contato com maior efeito'
      WHEN 28 THEN 'codigos de area com pelo menos mil disparos em cada braco'
      WHEN 30 THEN 'todos os disparos do escopo'
      WHEN 31 THEN 'apenas os disparos sem entrega'
      WHEN 32 THEN 'entregas do escopo'
      WHEN 33 THEN 'entregas do braco concordante'
      WHEN 34 THEN 'entregas do braco divergente'
      WHEN 35 THEN 'diferenca de custo entre os dois bracos'
      WHEN 42 THEN 'entregas do escopo, antes e depois da adocao'
      WHEN 43 THEN 'campanhas com ganho positivo no cenario central'
      WHEN 44 THEN 'entregas recuperadas de todas as campanhas'
      WHEN 50 THEN 'entregas do escopo'
      WHEN 51 THEN 'entregas do escopo'
      WHEN 52 THEN 'um centesimo dos disparos com cobertura'
      WHEN 61 THEN 'apenas os candidatos com historico do telefone recomendado'
      WHEN 62 THEN 'todos os candidatos a recuperacao'
      WHEN 63 THEN 'entregas liquidas do cenario central'
      WHEN 64 THEN 'entregas liquidas do cenario central'
      WHEN 65 THEN 'disparos entregues com telefone divergente'
      WHEN 66 THEN 'intervalo de 95 por cento da diferenca, sobre o volume com cobertura'
      WHEN 67 THEN 'intervalo de 95 por cento da diferenca, sobre o volume com cobertura'
      WHEN 70 THEN 'clientes com cobertura do Golden Record'
      WHEN 71 THEN 'clientes com cobertura do Golden Record'
      WHEN 72 THEN 'clientes com cobertura do Golden Record'
      WHEN 73 THEN 'clientes inalcancaveis com telefone ainda nao acionado'
      WHEN 74 THEN 'clientes com entrega comprovada no telefone recomendado'
      WHEN 75 THEN 'clientes com cobertura do Golden Record'
      WHEN 80 THEN 'todos os registros recebidos do CRM, antes do filtro de escopo'
      WHEN 81 THEN 'volume bruto de disparos, antes da consolidacao de retentativas'
      WHEN 82 THEN 'diferenca entre a carga recente e a carga com mais de doze meses'
      WHEN 83 THEN 'contagem absoluta, sem denominador'
      WHEN 84 THEN 'todos os disparos com cobertura do Golden Record'
      WHEN 85 THEN 'diferenca entre os dois bracos, restrita aos disparos validos no tempo'
      WHEN 90 THEN 'contagem absoluta, sem denominador'
      WHEN 91 THEN 'disparos do braco divergente, comparando o ultimo mes com o primeiro'
      WHEN 92 THEN 'disparos do braco concordante, comparando o ultimo mes com o primeiro'
      WHEN 93 THEN 'diferenca entre os dois bracos, dentro do primeiro mes'
      WHEN 94 THEN 'diferenca entre os dois bracos, dentro do ultimo mes'
      WHEN 95 THEN 'diferenca entre a vantagem do ultimo mes e a do primeiro'
      WHEN 96 THEN 'serie mensal da vantagem, reta ajustada por minimos quadrados'
      WHEN 97 THEN 'serie mensal da entrega sem o telefone recomendado, reta ajustada'
      WHEN 98 THEN 'todos os disparos, comparando o ultimo mes com o primeiro'
      ELSE CASE
        WHEN r.ordem BETWEEN 37 AND 41 THEN 'entregas liquidas do cenario'
        WHEN r.ordem BETWEEN 54 AND 58 THEN 'entregas liquidas do cenario'
        ELSE 'contagem absoluta, sem denominador'
      END
    END                                                      AS base_de_calculo,
    CASE r.ordem
      WHEN 4 THEN CAST(c.total_entregas AS DOUBLE)
      WHEN 5 THEN CAST(c.disparos_com_cobertura AS DOUBLE)
      WHEN 6 THEN CAST(c.clientes_com_cobertura AS DOUBLE)
      WHEN 7 THEN CAST(c.disparos_divergentes AS DOUBLE)
      WHEN 8 THEN CAST(c.candidatos_recuperacao AS DOUBLE)
      WHEN 9 THEN CAST(c.total_insucessos AS DOUBLE)
      ELSE NULL
    END                                                      AS quantidade,
    CASE r.ordem
      WHEN 4 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 5 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 6 THEN CAST(c.total_clientes AS DOUBLE)
      WHEN 7 THEN CAST(c.disparos_com_cobertura AS DOUBLE)
      WHEN 8 THEN CAST(c.insucessos_com_cobertura AS DOUBLE)
      WHEN 9 THEN CAST(c.total_disparos AS DOUBLE)
      ELSE NULL
    END                                                      AS quantidade_base,
    CASE r.ordem
      WHEN 6 THEN CAST(c.total_clientes AS DOUBLE)
      WHEN 4 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 5 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 7 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 8 THEN CAST(c.total_disparos AS DOUBLE)
      WHEN 9 THEN CAST(c.total_disparos AS DOUBLE)
      ELSE NULL
    END                                                      AS etapa_original,
    r.definicao,
    r.calculo,
    r.interpretacao,
    r.exemplo,
    r.origem
  FROM vt_res_12_resumo r
  JOIN vt_res_12_contexto c ON r.grupo = c.grupo
)
SELECT
  grupo,
  bloco,
  ordem,
  indicador,
  valor,
  unidade,
  base_de_calculo,
  quantidade,
  quantidade_base,
  round(CAST(100.0 * quantidade / nullif(quantidade_base, 0) AS DOUBLE), 4) AS pct_da_etapa_anterior,
  round(CAST(100.0 * quantidade / nullif(etapa_original, 0)  AS DOUBLE), 4) AS pct_do_total,
  definicao,
  calculo,
  interpretacao,
  exemplo,
  origem
FROM contexto
ORDER BY grupo, ordem
;
