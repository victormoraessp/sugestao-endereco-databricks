/* =============================================================================
   VALUATION DO GOLDEN RECORD DE TELEFONE CELULAR
   Experimento observacional sobre entregabilidade de SMS e simulação de ranking
   =============================================================================

   OBJETIVO
   Medir, sem teste A/B, se o telefone do Golden Record entrega mais SMS do que
   o telefone que o CRM usa hoje, quantificar o efeito em entregas incrementais
   e traduzir esse efeito em valor financeiro, considerando custo de disparo e
   retorno por conversão.

   ESTRUTURA DO ARQUIVO
     00  Parâmetros do experimento e do valuation
     01  Funções estatísticas auxiliares
     02  Fontes, normalização e base analítica
     03  Diagnóstico de cobertura e qualidade
     04  Validação do ranking do Golden Record
     05  Experimento natural: concordância de telefone
     06  Desenho pareado dentro do mesmo CPF
     07  Simulação de substituição de ranking
     08  Contrafactual dos insucessos
     09  Calculadora de valuation
     10  Testes de robustez
     11  Resumo executivo

   EXECUÇÃO
   Arquivo único, para rodar de ponta a ponta em uma sessão do Databricks SQL.
   As views temporárias e as funções temporárias vivem enquanto a sessão existir.
   Cada seção depende das anteriores, então a ordem dos comandos deve ser
   preservada.

   CONTRATO DE DADOS
   Golden Record, uma linha por CPF e ranking de telefone:
     cpf, ranking, ddi, ddd, telefone, data_ingestao
   Campanhas de SMS do CRM, uma linha por disparo:
     cpf, campanha, telefone_bruto, bol_entregue, bol_nao_entregue
     prioridade_crm é opcional e representa a ordem do slot de telefone no
     cadastro de origem. Quando não existir, a ordem é inferida pelo padrão de
     uso do número, conforme documentado na seção 02.

   GRÃO DE ANÁLISE
   Um envio é a combinação de CPF, campanha e telefone. Retentativas para o
   mesmo trio são consolidadas em uma única observação.
   ============================================================================= */


/* =============================================================================
   SEÇÃO 00  PARÂMETROS DO EXPERIMENTO E DO VALUATION
   =============================================================================
   Concentra todas as variáveis de decisão em um único ponto. Nenhum número
   mágico aparece nas seções seguintes.

   [JÚNIOR]    Este é o painel de controle. Mudar um valor aqui muda todos os
               resultados abaixo, sem precisar mexer em nenhuma consulta.
   [SÊNIOR]    Separar parâmetros de lógica permite rodar cenários de
               sensibilidade sem reescrever o pipeline e mantém a análise
               auditável, porque toda premissa fica declarada em um só lugar.
   [EXECUTIVO] As premissas financeiras do estudo estão nesta seção. Custo de
               disparo, taxa de conversão esperada e valor de cada conversão
               são as três alavancas que determinam o valor final.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   00.1  PARÂMETROS GERAIS

   custo_sms             Custo unitário de um disparo de SMS, em reais. Incide
                         sobre todo disparo, entregue ou não.
   taxa_conversao        Fração dos SMS entregues que geram a conversão de
                         interesse. Valor padrão de 0,50 por cento.
   valor_conversao       Retorno financeiro médio de cada conversão, em reais.
   profundidade_ranking  Até qual posição de ranking o plano do Golden Record
                         substitui o telefone do CRM. Posições além desta são
                         mapeadas para o ranking 1.
   z_95                  Quantil da Normal padrão para intervalos de 95 por cento.
   min_envios_braco      Mínimo de envios em cada braço para uma campanha ser
                         testada isoladamente na seção 10.
   min_n_estrato         Mínimo de envios para um estrato entrar no teste
                         estratificado da seção 05.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param AS
SELECT
  CAST(0.04     AS DOUBLE) AS custo_sms,
  CAST(0.0050   AS DOUBLE) AS taxa_conversao,
  CAST(150.00   AS DOUBLE) AS valor_conversao,
  CAST(4        AS INT)    AS profundidade_ranking,
  CAST(1.959964 AS DOUBLE) AS z_95,
  CAST(50       AS INT)    AS min_envios_braco,
  CAST(2        AS INT)    AS min_n_estrato,
  CAST(0.05     AS DOUBLE) AS alpha
;


/* -----------------------------------------------------------------------------
   00.2  GRUPOS DE CAMPANHAS

   Define até três recortes de campanhas analisados em paralelo. Cada grupo
   produz sua própria linha em todas as tabelas de resultado, e o rótulo TOTAL
   consolida o conjunto.

   REGRA DE ESCOPO
     Quando ao menos um grupo tem campanhas informadas, a análise roda apenas
     sobre as campanhas informadas, e TOTAL é a união delas.
     Quando nenhum grupo tem campanhas informadas, a análise roda sobre a base
     completa, sob o rótulo TOTAL. Essa é a configuração padrão do arquivo.

   COMO INFORMAR AS CAMPANHAS
   Há duas formas equivalentes, e basta usar uma delas por grupo.
     campanhas         vetor de nomes, por exemplo array('CAMPANHA_A', 'CAMPANHA_B')
     campanhas_texto   nomes separados por vírgula, por exemplo 'CAMPANHA_A, CAMPANHA_B'
   O vetor tem precedência quando os dois estão preenchidos. Espaços em volta
   dos nomes são removidos e nomes repetidos são desconsiderados.

   COMO DESLIGAR UM GRUPO
   Deixe as duas colunas nulas, ou informe um vetor vazio, ou um texto em
   branco. Qualquer uma dessas formas desativa o grupo sem gerar erro. Com os
   três grupos desligados, o estudo roda sobre a base inteira.

   Uma mesma campanha pode aparecer em mais de um grupo. Nesse caso ela é
   contabilizada em cada grupo a que pertence e uma única vez em TOTAL.
   A view 02.9 reporta quantas campanhas informadas foram de fato encontradas
   na base, o que revela erro de digitação antes de qualquer análise.

   taxa_conversao_grupo e valor_conversao_grupo permitem premissas financeiras
   distintas por recorte. Quando ficam nulas, valem os parâmetros gerais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param_grupos AS
SELECT
  'GRUPO_1'                        AS grupo,
  'Recorte 1'                      AS descricao,
  CAST(NULL AS ARRAY<STRING>)      AS campanhas,
  CAST(NULL AS STRING)             AS campanhas_texto,
  CAST(NULL AS DOUBLE)             AS taxa_conversao_grupo,
  CAST(NULL AS DOUBLE)             AS valor_conversao_grupo
UNION ALL
SELECT
  'GRUPO_2',
  'Recorte 2',
  CAST(NULL AS ARRAY<STRING>),
  CAST(NULL AS STRING),
  CAST(NULL AS DOUBLE),
  CAST(NULL AS DOUBLE)
UNION ALL
SELECT
  'GRUPO_3',
  'Recorte 3',
  CAST(NULL AS ARRAY<STRING>),
  CAST(NULL AS STRING),
  CAST(NULL AS DOUBLE),
  CAST(NULL AS DOUBLE)
;


/* -----------------------------------------------------------------------------
   00.3  GRADE DE SENSIBILIDADE DO VALUATION

   Multiplicadores aplicados sobre a taxa de conversão e sobre o valor por
   conversão, para produzir uma superfície de valor em vez de um número único.
   A combinação 1,0 por 1,0 reproduz exatamente os parâmetros gerais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_param_sensibilidade AS
SELECT
  m_taxa.mult   AS mult_taxa_conversao,
  m_taxa.rotulo AS rotulo_taxa,
  m_valor.mult   AS mult_valor_conversao,
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
   SEÇÃO 01  FUNÇÕES ESTATÍSTICAS AUXILIARES
   =============================================================================
   O Databricks SQL não expõe nativamente a distribuição Normal acumulada nem
   intervalos de confiança de proporção. Estas funções suprem essa lacuna e são
   usadas por todas as seções de inferência.

   [JÚNIOR]    São calculadoras reutilizáveis. norm_cdf transforma um escore z
               em probabilidade, p_valor diz se uma diferença pode ser acaso e
               as funções de Wilson devolvem a faixa provável de uma taxa.
   [SÊNIOR]    norm_cdf usa a aproximação de Zelen e Severo, com erro absoluto
               abaixo de 7,5 vezes dez elevado a menos oito. Wilson é preferido
               a Wald por manter cobertura nominal em amostras pequenas e em
               taxas próximas de zero ou de um.
   [EXECUTIVO] Esta seção instala instrumentos de medição e não produz nenhum
               número de negócio.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   01.1  DISTRIBUIÇÃO NORMAL ACUMULADA

   Decomposta em três funções porque uma função SQL não admite variáveis locais.
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
   01.2  P-VALORES

   p_valor_bilateral   teste z bicaudal, duas vezes um menos a acumulada de |z|
   p_valor_qui2_1gl    qui-quadrado com um grau de liberdade, equivalente ao
                       quadrado de um escore z
   Interpretação: quanto menor, menos plausível que a diferença seja acaso.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMPORARY FUNCTION p_valor_bilateral(z DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN z IS NULL THEN NULL ELSE 2.0 * (1.0 - norm_cdf(abs(z))) END;

CREATE OR REPLACE TEMPORARY FUNCTION p_valor_qui2_1gl(chi2 DOUBLE)
RETURNS DOUBLE
RETURN CASE WHEN chi2 IS NULL OR chi2 < 0 THEN NULL
            ELSE 2.0 * (1.0 - norm_cdf(sqrt(chi2))) END;


/* -----------------------------------------------------------------------------
   01.3  INTERVALO DE CONFIANÇA DE WILSON PARA UMA PROPORÇÃO

   Recebe o número de sucessos e o total, devolve os limites de 95 por cento.
----------------------------------------------------------------------------- */
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


/* -----------------------------------------------------------------------------
   01.4  VERIFICAÇÃO DAS FUNÇÕES

   Valores esperados, com tolerância de um milionésimo:
     norm_cdf(1,959964)          igual a 0,975
     norm_cdf(-1,959964)         igual a 0,025
     p_valor_bilateral(1,959964) igual a 0,050
     p_valor_qui2_1gl(3,841459)  igual a 0,050
     wilson_inf(50, 100)         igual a 0,4038
     wilson_sup(50, 100)         igual a 0,5962
   Divergência nestes valores invalida todos os p-valores das seções seguintes.
----------------------------------------------------------------------------- */
SELECT
  norm_cdf(1.959964)          AS esperado_0_975,
  norm_cdf(-1.959964)         AS esperado_0_025,
  p_valor_bilateral(1.959964) AS esperado_0_050_z,
  p_valor_qui2_1gl(3.841459)  AS esperado_0_050_qui2,
  wilson_inf(50, 100)         AS esperado_0_4038,
  wilson_sup(50, 100)         AS esperado_0_5962
;


/* =============================================================================
   SEÇÃO 02  FONTES, NORMALIZAÇÃO E BASE ANALÍTICA
   =============================================================================
   Constrói a base sobre a qual todo o estudo roda: cada envio de SMS do CRM,
   com o resultado observado, o telefone que o Golden Record indicaria e a
   posição desse telefone no ranking do Golden Record.

   [JÚNIOR]    Três movimentos. Primeiro, organizar o Golden Record com um
               telefone por CPF e por ranking. Segundo, limpar a base do CRM e
               descobrir a ordem em que os telefones de cada cliente foram
               usados. Terceiro, juntar as duas por CPF.
   [SÊNIOR]    A comparação de telefones acontece em dois níveis. O nível exato
               compara a string completa de país, área e número. O nível
               tolerante compara área mais os oito dígitos finais, o que
               neutraliza variação de nono dígito e de código de país. O CPF é
               normalizado antes da deduplicação do Golden Record, e não depois,
               para que duas grafias diferentes do mesmo documento não gerem
               dois registros de ranking 1.
   [EXECUTIVO] Esta seção prepara a mesa de comparação. Para cada SMS enviado
               passa a ser possível responder se ele foi para o telefone que o
               Golden Record recomendaria e se chegou ao destino.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   02.1  FONTES DE DADOS E NORMALIZAÇÃO DE NOMES

   Estas duas views são o único ponto de contato com as tabelas de origem. Cada
   coluna da origem é renomeada aqui para o nome canônico usado no restante do
   arquivo. Para apontar o estudo para outras tabelas, altere apenas o nome da
   tabela no FROM e a expressão à esquerda de cada AS. Nenhuma outra parte do
   arquivo precisa ser tocada, desde que os tipos de dado sejam equivalentes.

   NOMES CANÔNICOS DO GOLDEN RECORD
     cpf            identificador do cliente, em qualquer formatação
     ranking        posição de qualidade do telefone, sendo 1 a melhor
     ddi            código do país
     ddd            código de área
     telefone       número sem país e sem área
     data_ingestao  momento da carga, usado para escolher o registro mais
                    recente quando existe mais de um para o mesmo cpf e
                    ranking. Precisa apenas ser ordenável, seja data,
                    timestamp ou texto em formato ordenável.

   NOMES CANÔNICOS DAS CAMPANHAS DE SMS
     cpf               identificador do cliente, em qualquer formatação
     campanha          identificador da campanha
     telefone_bruto    país, área e número concatenados
     bol_entregue      indicador de entrega
     bol_nao_entregue  indicador de falha de entrega
     prioridade_crm    ordem do slot de telefone no cadastro de origem. Campo
                       opcional. Quando a origem não possui esse dado, o valor
                       permanece nulo e a ordem é inferida conforme 02.7.

   Quando um nome canônico coincidir com o nome de origem, os dois lados do AS
   ficam iguais. Isso é intencional e mantém o mapeamento visível.
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
  CAST(NULL AS INT)  AS prioridade_crm
FROM temp_view_crm_sms
;


/* -----------------------------------------------------------------------------
   02.2  GOLDEN RECORD, TODOS OS RANKINGS

   Um telefone por CPF e por posição de ranking, sempre o de ingestão mais
   recente. A normalização do CPF acontece antes da deduplicação, de modo que
   o par CPF normalizado mais ranking é único no resultado.

   telefone_gr  país, área e número concatenados, apenas dígitos
   chave_gr     área e oito dígitos finais, usada na comparação tolerante
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_todos_rankings AS
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
   02.3  GOLDEN RECORD, RANKING 1

   Telefone recomendado em primeiro lugar para cada CPF. É a referência do
   experimento principal das seções 05 e 06.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_rank1 AS
SELECT
  cpf,
  telefone_gr,
  ddd_gr,
  chave_gr,
  data_ingestao_gr
FROM vt_gr_todos_rankings
WHERE ranking = 1
;


/* -----------------------------------------------------------------------------
   02.4  PROFUNDIDADE DO GOLDEN RECORD POR CPF

   Quantas posições de ranking existem para cada CPF. Um CPF com apenas uma
   posição não oferece alternativa quando o plano de substituição pede um
   ranking mais profundo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_gr_profundidade_cpf AS
SELECT
  cpf,
  count(*)                 AS rankings_disponiveis,
  max(ranking)             AS ranking_maximo,
  count(DISTINCT telefone_gr) AS telefones_distintos
FROM vt_gr_todos_rankings
GROUP BY cpf
;


/* -----------------------------------------------------------------------------
   02.5  CRM, NORMALIZAÇÃO E CHAVES DE COMPARAÇÃO

   telefone_crm  apenas dígitos do campo bruto
   chave_crm     área e oito dígitos finais. Quando o número tem doze ou mais
                 dígitos e começa com o código do Brasil, o país é removido
                 antes de extrair a área.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios_raw AS
WITH base AS (
  SELECT
    lpad(regexp_replace(CAST(cpf AS STRING), '[^0-9]', ''), 11, '0')  AS cpf,
    CAST(campanha AS STRING)                                          AS campanha,
    regexp_replace(CAST(telefone_bruto AS STRING), '[^0-9]', '')      AS telefone_crm,
    coalesce(CAST(bol_entregue     AS BOOLEAN), false)                AS flag_entregue,
    coalesce(CAST(bol_nao_entregue AS BOOLEAN), false)                AS flag_nao_entregue,
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
  cpf,
  campanha,
  telefone_crm,
  flag_entregue,
  flag_nao_entregue,
  prioridade_crm,
  left(telefone_crm_local, 2)                                              AS ddd_crm,
  concat(left(telefone_crm_local, 2), '-', right(telefone_crm_local, 8))   AS chave_crm
FROM sem_pais
;


/* -----------------------------------------------------------------------------
   02.6  CRM, CLASSIFICAÇÃO DE QUALIDADE E VARIÁVEL RESPOSTA

   entregue assume 1 quando o registro indica entrega, 0 quando indica falha e
   nulo quando os dois indicadores se contradizem ou estão ambos ausentes.
   Apenas registros classificados como OK entram no experimento. O volume
   descartado é reportado na seção 03.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios_qualidade AS
SELECT
  *,
  CASE
    WHEN cpf IS NULL OR cpf = '00000000000' OR length(cpf) <> 11   THEN 'SEM_CPF'
    WHEN telefone_crm IS NULL OR length(telefone_crm) < 10         THEN 'SEM_TELEFONE'
    WHEN flag_entregue AND flag_nao_entregue                       THEN 'STATUS_INCONSISTENTE'
    WHEN NOT flag_entregue AND NOT flag_nao_entregue               THEN 'SEM_STATUS'
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
   02.7  ORDEM DE USO DOS TELEFONES DENTRO DO CRM

   O ranking do CRM representa a posição do telefone no cadastro de origem.
   Quando a coluna prioridade_crm está preenchida, ela é respeitada.
   Quando não está, a ordem é inferida pelo padrão de uso do número: o telefone
   acionado no maior número de campanhas do CPF é tratado como principal, o
   segundo mais acionado como secundário, e assim por diante. O critério final
   de desempate é o próprio número, o que torna a ordem reprodutível entre
   execuções.

   [SÊNIOR] A inferência assume que o slot principal do cadastro é o mais
            acionado ao longo do histórico. É uma proxy, não uma leitura direta
            do campo de origem, e está declarada como limitação no resumo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_perfil_telefone AS
SELECT
  cpf,
  telefone_crm,
  min(prioridade_crm)      AS prioridade_declarada,
  count(DISTINCT campanha) AS campanhas_com_uso,
  count(*)                 AS envios_totais
FROM vt_crm_envios_qualidade
WHERE qualidade = 'OK'
GROUP BY cpf, telefone_crm
;


/* -----------------------------------------------------------------------------
   02.8  CRM, GRÃO FINAL DE ENVIO

   Uma linha por CPF, campanha e telefone. Retentativas do mesmo trio são
   consolidadas, e o envio é considerado entregue se qualquer tentativa entregou.
   ranking_crm indica a posição do telefone dentro daquela campanha, segundo a
   ordem definida em 02.7.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_crm_envios AS
WITH consolidado AS (
  SELECT
    cpf,
    campanha,
    telefone_crm,
    ddd_crm,
    chave_crm,
    max(entregue) AS entregue,
    count(*)      AS registros_originais
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
   02.9  ESCOPO DE CAMPANHAS E GRUPOS DE ANÁLISE

   Materializa a regra descrita em 00.2 em três passos. Primeiro normaliza a
   lista de cada grupo, aceitando indiferentemente vetor, texto separado por
   vírgula, vetor vazio, texto em branco ou nulo. Depois atribui a cada campanha
   os rótulos de grupo a que pertence, mais o rótulo TOTAL. Por fim confere se
   as campanhas informadas existem na base.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_grupo_lista AS
SELECT
  grupo,
  descricao,
  taxa_conversao_grupo,
  valor_conversao_grupo,
  CASE
    WHEN campanhas IS NOT NULL AND size(campanhas) > 0
      THEN array_distinct(
             filter(transform(campanhas, x -> trim(x)), x -> length(x) > 0))
    WHEN campanhas_texto IS NOT NULL AND length(trim(campanhas_texto)) > 0
      THEN array_distinct(
             filter(transform(split(campanhas_texto, ','), x -> trim(x)),
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
  SELECT DISTINCT campanha FROM vt_crm_envios
),
total_sem_lista AS (
  SELECT 'TOTAL' AS grupo, u.campanha
  FROM universo u
  CROSS JOIN contagem c
  WHERE c.listadas = 0
),
total_com_lista AS (
  SELECT DISTINCT 'TOTAL' AS grupo, campanha FROM definido
)
SELECT grupo, campanha FROM definido
UNION ALL
SELECT grupo, campanha FROM total_com_lista
UNION ALL
SELECT grupo, campanha FROM total_sem_lista
;

CREATE OR REPLACE TEMP VIEW vt_grupo_param AS
SELECT
  g.grupo,
  g.descricao,
  coalesce(g.taxa_conversao_grupo,  p.taxa_conversao)  AS taxa_conversao,
  coalesce(g.valor_conversao_grupo, p.valor_conversao) AS valor_conversao,
  p.custo_sms
FROM vt_grupo_lista g
CROSS JOIN vt_param p
WHERE g.campanhas IS NOT NULL AND size(g.campanhas) > 0
UNION ALL
SELECT
  'TOTAL',
  'Consolidado das campanhas em escopo',
  p.taxa_conversao,
  p.valor_conversao,
  p.custo_sms
FROM vt_param p
;


/* -----------------------------------------------------------------------------
   02.9.1  CONFERÊNCIA DO ESCOPO

   Reporta o modo de operação de cada grupo e quantas das campanhas informadas
   foram localizadas na base. Campanhas não encontradas indicam divergência de
   grafia entre a lista e o cadastro, e são listadas pelo nome para correção.
   Um grupo em modo DESLIGADO não aparece em nenhuma tabela de resultado.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_02_escopo AS
WITH listadas AS (
  SELECT grupo, explode(campanhas) AS campanha
  FROM vt_grupo_lista
  WHERE campanhas IS NOT NULL AND size(campanhas) > 0
),
universo AS (
  SELECT DISTINCT campanha FROM vt_crm_envios
),
conferencia AS (
  SELECT l.grupo, l.campanha, (u.campanha IS NOT NULL) AS existe
  FROM listadas l
  LEFT JOIN universo u ON l.campanha = u.campanha
),
por_grupo AS (
  SELECT
    grupo,
    'LISTA_INFORMADA'                                          AS modo,
    count(*)                                                   AS campanhas_informadas,
    sum(CASE WHEN existe THEN 1 ELSE 0 END)                    AS campanhas_encontradas,
    sum(CASE WHEN existe THEN 0 ELSE 1 END)                    AS campanhas_nao_encontradas,
    concat_ws(', ', collect_list(CASE WHEN NOT existe THEN campanha END)) AS nomes_nao_encontrados
  FROM conferencia
  GROUP BY grupo
),
desligados AS (
  SELECT
    g.grupo,
    'DESLIGADO' AS modo,
    0 AS campanhas_informadas,
    0 AS campanhas_encontradas,
    0 AS campanhas_nao_encontradas,
    CAST(NULL AS STRING) AS nomes_nao_encontrados
  FROM vt_grupo_lista g
  WHERE g.campanhas IS NULL OR size(g.campanhas) = 0
),
consolidado AS (
  SELECT
    'TOTAL' AS grupo,
    CASE WHEN c.listadas = 0 THEN 'BASE_INTEIRA' ELSE 'UNIAO_DAS_LISTAS' END AS modo,
    count(DISTINCT g.campanha)                                              AS campanhas_informadas,
    count(DISTINCT CASE WHEN u.campanha IS NOT NULL THEN g.campanha END)    AS campanhas_encontradas,
    count(DISTINCT CASE WHEN u.campanha IS NULL     THEN g.campanha END)    AS campanhas_nao_encontradas,
    concat_ws(', ', collect_set(CASE WHEN u.campanha IS NULL THEN g.campanha END)) AS nomes_nao_encontrados
  FROM vt_grupo_campanha g
  LEFT JOIN universo u ON g.campanha = u.campanha
  CROSS JOIN (SELECT count(*) AS listadas FROM listadas) c
  WHERE g.grupo = 'TOTAL'
  GROUP BY CASE WHEN c.listadas = 0 THEN 'BASE_INTEIRA' ELSE 'UNIAO_DAS_LISTAS' END
)
SELECT * FROM por_grupo
UNION ALL
SELECT * FROM desligados
UNION ALL
SELECT * FROM consolidado
;
SELECT * FROM vt_res_02_escopo ORDER BY grupo;


/* -----------------------------------------------------------------------------
   02.10  BASE ANALÍTICA

   Um envio por linha, com o telefone do Golden Record ao lado e a classificação
   de concordância.

   classe_concordancia
     SEM_GR           CPF ausente do Golden Record, sem contrafactual possível
     IGUAL_EXATO      o CRM usou exatamente o telefone de ranking 1
     IGUAL_TOLERANTE  mesmo número, com diferença apenas de formatação
     DIFERENTE        o Golden Record indicaria outro telefone

   ranking_gr_do_telefone_usado informa em que posição do Golden Record está o
   telefone que o CRM de fato usou. Fica nulo quando o número não aparece em
   nenhuma posição do ranking daquele CPF.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_base_analitica AS
WITH com_rank1 AS (
  SELECT
    e.cpf,
    e.campanha,
    e.telefone_crm,
    e.chave_crm,
    e.entregue,
    e.registros_originais,
    e.ranking_crm,
    e.telefones_na_campanha,
    g.telefone_gr,
    g.chave_gr,
    g.data_ingestao_gr,
    (g.cpf IS NOT NULL) AS tem_gr,
    coalesce(prof.rankings_disponiveis, 0) AS rankings_disponiveis
  FROM vt_crm_envios e
  LEFT JOIN vt_gr_rank1 g            ON e.cpf = g.cpf
  LEFT JOIN vt_gr_profundidade_cpf prof ON e.cpf = prof.cpf
),
com_posicao AS (
  SELECT
    c.*,
    t.ranking AS ranking_gr_do_telefone_usado
  FROM com_rank1 c
  LEFT JOIN vt_gr_todos_rankings t
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
    WHEN NOT tem_gr                      THEN 'SEM_GR'
    WHEN telefone_crm = telefone_gr      THEN 'IGUAL_EXATO'
    WHEN chave_crm    = chave_gr         THEN 'IGUAL_TOLERANTE'
    ELSE                                      'DIFERENTE'
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
   02.11  UNIVERSO DO EXPERIMENTO

   vt_experimento  envios das campanhas em escopo cujo CPF existe no Golden
                   Record, replicados por grupo de análise. Uma campanha
                   presente em dois grupos gera duas linhas por envio, uma para
                   cada rótulo, mais a linha de TOTAL.
   vt_base_grupo   todos os envios das campanhas em escopo, com e sem Golden
                   Record, usado nos diagnósticos de cobertura e de custo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_experimento AS
SELECT
  g.grupo,
  b.*
FROM vt_base_analitica b
JOIN vt_grupo_campanha g ON b.campanha = g.campanha
WHERE b.tem_gr
;

CREATE OR REPLACE TEMP VIEW vt_base_grupo AS
SELECT
  g.grupo,
  b.*
FROM vt_base_analitica b
JOIN vt_grupo_campanha g ON b.campanha = g.campanha
;


/* -----------------------------------------------------------------------------
   02.12  VOLUMETRIA POR CAMPANHA

   Insumo das análises estratificadas e dos recortes por porte de campanha.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_campanha_volume AS
SELECT
  grupo,
  campanha,
  count(*)                                          AS n_envios,
  sum(entregue)                                     AS n_entregues,
  avg(entregue)                                     AS taxa_entrega,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)           AS n_com_gr,
  sum(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)  AS n_concordante,
  sum(CASE WHEN concordante = 0 THEN 1 ELSE 0 END)  AS n_discordante,
  CASE
    WHEN count(*) <      100 THEN '1. ate 100'
    WHEN count(*) <     1000 THEN '2. 100 a 1 mil'
    WHEN count(*) <    10000 THEN '3. 1 mil a 10 mil'
    WHEN count(*) <   100000 THEN '4. 10 mil a 100 mil'
    WHEN count(*) <  1000000 THEN '5. 100 mil a 1 milhao'
    ELSE                          '6. acima de 1 milhao'
  END                                               AS faixa_volume
FROM vt_base_grupo
GROUP BY grupo, campanha
;


/* -----------------------------------------------------------------------------
   02.13  CONFERÊNCIA DA BASE ANALÍTICA
----------------------------------------------------------------------------- */
SELECT
  grupo,
  count(*)                                                  AS envios_validos,
  count(DISTINCT cpf)                                       AS cpfs_distintos,
  count(DISTINCT campanha)                                  AS campanhas,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)                   AS envios_com_gr,
  round(100.0 * avg(CASE WHEN tem_gr THEN 1 ELSE 0 END), 4) AS pct_envios_com_gr,
  round(100.0 * avg(entregue), 4)                           AS taxa_entrega_pct,
  round(avg(telefones_na_campanha), 3)                      AS media_telefones_por_cpf_campanha
FROM vt_base_grupo
GROUP BY grupo
ORDER BY grupo
;


/* =============================================================================
   SEÇÃO 03  DIAGNÓSTICO DE COBERTURA E QUALIDADE
   =============================================================================
   Estabelece o terreno antes de qualquer inferência: quanto foi descartado,
   quanto o Golden Record alcança, quanto o CRM já concorda com ele e se o
   grupo estudado é comparável ao restante da base.

   [JÚNIOR]    São contagens e percentuais. Nenhuma linha aqui prova que o
               Golden Record é bom, apenas mede o tamanho do campo de jogo.
   [SÊNIOR]    O bloco 03.5 é o teste de validade externa. Se CPFs com Golden
               Record já entregam de forma muito diferente dos demais, o
               resultado do experimento vale para a população coberta e a
               extrapolação precisa ser declarada como premissa.
   [EXECUTIVO] Responde a duas perguntas de dimensionamento: o Golden Record
               cobre quantos por cento dos clientes que o CRM tenta contatar,
               e em quantos por cento dos disparos ele discorda do número usado.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   03.1  QUALIDADE DOS REGISTROS RECEBIDOS DO CRM

   Volume que entra no experimento e volume descartado, por motivo.
   Status inconsistente e ausência de status indicam problema de carga na
   origem. Não invalidam o experimento, reduzem sua cobertura.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_qualidade AS
SELECT
  qualidade,
  count(*)                                            AS registros,
  round(100.0 * count(*) / sum(count(*)) OVER (), 4)  AS pct_registros
FROM vt_crm_envios_qualidade
GROUP BY qualidade
;
SELECT * FROM vt_res_03_qualidade ORDER BY registros DESC;


/* -----------------------------------------------------------------------------
   03.2  COBERTURA DO GOLDEN RECORD

   Medida em dois grãos. O grão de envio pondera por volume de disparo e o grão
   de CPF pondera por cliente. A diferença entre os dois indica se os clientes
   cobertos são os mais acionados.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_cobertura AS
SELECT
  grupo,
  'ENVIO' AS grao,
  count(*)                                                   AS total,
  sum(CASE WHEN tem_gr THEN 1 ELSE 0 END)                    AS com_gr,
  round(100.0 * avg(CASE WHEN tem_gr THEN 1 ELSE 0 END), 4)  AS pct_com_gr
FROM vt_base_grupo
GROUP BY grupo
UNION ALL
SELECT
  grupo,
  'CPF' AS grao,
  count(DISTINCT cpf)                                              AS total,
  count(DISTINCT CASE WHEN tem_gr THEN cpf END)                    AS com_gr,
  round(100.0 * count(DISTINCT CASE WHEN tem_gr THEN cpf END)
              / nullif(count(DISTINCT cpf), 0), 4)                 AS pct_com_gr
FROM vt_base_grupo
GROUP BY grupo
;
SELECT * FROM vt_res_03_cobertura ORDER BY grupo, grao;


/* -----------------------------------------------------------------------------
   03.3  CONCORDÂNCIA ATUAL ENTRE CRM E GOLDEN RECORD

   Quanto o CRM já acerta o telefone de ranking 1 sem usar o Golden Record, e
   quanto da divergência é apenas formatação. A classe DIFERENTE delimita o
   espaço em que a troca de telefone pode alterar o resultado.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_concordancia AS
SELECT
  grupo,
  classe_concordancia,
  count(*)                                                        AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY grupo), 4) AS pct_envios,
  count(DISTINCT cpf)                                             AS cpfs,
  round(100.0 * avg(entregue), 4)                                 AS taxa_entrega_pct
FROM vt_experimento
GROUP BY grupo, classe_concordancia
;
SELECT * FROM vt_res_03_concordancia ORDER BY grupo, envios DESC;


/* -----------------------------------------------------------------------------
   03.4  PORTE DAS CAMPANHAS

   Distribuição de campanhas e de volume por faixa. Concentração alta em poucas
   campanhas justifica a análise estratificada da seção 05, que pondera cada
   campanha pelo próprio tamanho.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_faixas_campanha AS
SELECT
  grupo,
  faixa_volume,
  count(*)                                                                AS n_campanhas,
  sum(n_envios)                                                           AS n_envios,
  round(100.0 * sum(n_envios) / sum(sum(n_envios)) OVER (PARTITION BY grupo), 4) AS pct_envios,
  round(100.0 * sum(n_entregues) / nullif(sum(n_envios), 0), 4)           AS taxa_entrega_pct,
  round(100.0 * sum(n_com_gr) / nullif(sum(n_envios), 0), 4)              AS pct_com_gr,
  sum(CASE WHEN n_concordante > 0 AND n_discordante > 0 THEN 1 ELSE 0 END) AS campanhas_com_ambos_bracos
FROM vt_campanha_volume
GROUP BY grupo, faixa_volume
;
SELECT * FROM vt_res_03_faixas_campanha ORDER BY grupo, faixa_volume;


/* -----------------------------------------------------------------------------
   03.5  VERIFICAÇÃO DE SELEÇÃO

   Compara a entrega de quem tem Golden Record contra quem não tem, sem olhar
   qual telefone foi usado. Uma diferença pequena indica que o experimento pode
   ser extrapolado para a base inteira. Uma diferença grande restringe a
   conclusão à população coberta.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_selecao AS
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
    k_com / nullif(n_com, 0)                AS p_com,
    k_sem / nullif(n_sem, 0)                AS p_sem,
    (k_com + k_sem) / nullif(n_com + n_sem, 0) AS p_pool
  FROM agg
),
z AS (
  SELECT
    *,
    CASE WHEN n_sem > 0 AND n_com > 0 AND p_pool NOT IN (0, 1)
         THEN (p_com - p_sem)
              / sqrt(p_pool * (1 - p_pool) * (1.0 / nullif(n_com, 0) + 1.0 / nullif(n_sem, 0)))
    END AS z_score
  FROM calc
)
SELECT
  grupo,
  n_com                                       AS envios_com_gr,
  round(100.0 * p_com, 4)                     AS taxa_com_gr_pct,
  round(100.0 * wilson_inf(k_com, n_com), 4)  AS ic95_inf_com_gr,
  round(100.0 * wilson_sup(k_com, n_com), 4)  AS ic95_sup_com_gr,
  n_sem                                       AS envios_sem_gr,
  round(100.0 * p_sem, 4)                     AS taxa_sem_gr_pct,
  round(100.0 * wilson_inf(k_sem, n_sem), 4)  AS ic95_inf_sem_gr,
  round(100.0 * wilson_sup(k_sem, n_sem), 4)  AS ic95_sup_sem_gr,
  round(100.0 * (p_com - p_sem), 4)           AS diferenca_pp,
  round(z_score, 3)                           AS z,
  p_valor_bilateral(z_score)                  AS p_valor,
  CASE
    WHEN n_sem = 0 THEN 'Todos os envios do grupo tem Golden Record, nao ha grupo de comparacao.'
    WHEN abs(p_com - p_sem) < 0.02 THEN 'Grupos equivalentes, extrapolacao para a base inteira e razoavel.'
    ELSE 'Grupos distintos, o resultado vale para a populacao coberta pelo Golden Record.'
  END                                         AS leitura
FROM z
;
SELECT * FROM vt_res_03_selecao ORDER BY grupo;


/* -----------------------------------------------------------------------------
   03.6  DIVERGÊNCIAS DE FORMATAÇÃO

   Anatomia dos casos em que o número é o mesmo mas escrito de outra forma.
   Volume alto aqui confirma que a comparação tolerante é a regra correta para
   o negócio, e que a comparação exata subestimaria a concordância real.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_formato AS
SELECT
  grupo,
  length(telefone_crm)                                                    AS tamanho_crm,
  length(telefone_gr)                                                     AS tamanho_gr,
  count(*)                                                                AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY grupo), 4)    AS pct
FROM vt_experimento
WHERE classe_concordancia = 'IGUAL_TOLERANTE'
GROUP BY grupo, length(telefone_crm), length(telefone_gr)
;
SELECT * FROM vt_res_03_formato ORDER BY grupo, envios DESC;


/* -----------------------------------------------------------------------------
   03.7  MULTIPLICIDADE DE TELEFONES POR CLIENTE E CAMPANHA

   Quantos números distintos o CRM aciona para o mesmo CPF dentro da mesma
   campanha. É a matéria-prima da simulação de ranking da seção 07: só existe
   substituição de posição quando existe mais de um telefone.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_03_multiplicidade AS
SELECT
  grupo,
  CASE WHEN telefones_na_campanha >= 5 THEN '5 ou mais'
       ELSE CAST(telefones_na_campanha AS STRING) END        AS telefones_no_disparo,
  count(DISTINCT concat(cpf, '|', campanha))                 AS pares_cpf_campanha,
  count(*)                                                   AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY grupo), 4) AS pct_envios,
  round(100.0 * avg(entregue), 4)                            AS taxa_entrega_pct
FROM vt_base_grupo
GROUP BY grupo,
  CASE WHEN telefones_na_campanha >= 5 THEN '5 ou mais'
       ELSE CAST(telefones_na_campanha AS STRING) END
;
SELECT * FROM vt_res_03_multiplicidade ORDER BY grupo, telefones_no_disparo;


/* =============================================================================
   SEÇÃO 04  VALIDAÇÃO DO RANKING DO GOLDEN RECORD
   =============================================================================
   Antes de simular a substituição, é preciso saber se o ranking do Golden
   Record carrega informação de verdade. A pergunta desta seção é direta: o
   telefone de ranking 1 entrega mais que o de ranking 2, que por sua vez
   entrega mais que o de ranking 3, e assim por diante?

   [JÚNIOR]    Pegamos cada SMS enviado e verificamos em que posição do Golden
               Record está o número que foi usado. Depois comparamos a taxa de
               entrega de cada posição. Se o ranking presta, a taxa cai à medida
               que a posição piora.
   [SÊNIOR]    É um teste de monotonicidade do escore de qualidade. O resultado
               é a evidência mais direta de que o ranking é um preditor válido
               de entregabilidade, e não apenas uma ordenação arbitrária. A
               comparação usa o telefone efetivamente disparado, portanto não
               depende de nenhuma suposição contrafactual.
   [EXECUTIVO] Esta seção responde se o ranking do Golden Record separa telefone
               bom de telefone ruim. Se a taxa de entrega cair de forma
               ordenada da posição 1 para as seguintes, o ranking está
               calibrado e pode ser usado como régua de decisão.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   04.1  ENTREGA POR POSIÇÃO DO TELEFONE NO GOLDEN RECORD

   Cada envio é classificado pela posição do número usado dentro do ranking do
   Golden Record daquele CPF. FORA_DO_GR indica número que não consta em
   nenhuma posição.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_04_entrega_por_ranking AS
WITH classificado AS (
  SELECT
    grupo,
    CASE
      WHEN ranking_gr_do_telefone_usado IS NULL THEN 'FORA_DO_GR'
      WHEN ranking_gr_do_telefone_usado >= 5    THEN 'RANKING_5_OU_MAIS'
      ELSE concat('RANKING_', CAST(ranking_gr_do_telefone_usado AS STRING))
    END                                          AS posicao_no_gr,
    ranking_gr_do_telefone_usado,
    entregue
  FROM vt_experimento
),
agg AS (
  SELECT
    grupo,
    posicao_no_gr,
    min(coalesce(ranking_gr_do_telefone_usado, 99)) AS ordem,
    count(*)                                        AS envios,
    sum(entregue)                                   AS entregues
  FROM classificado
  GROUP BY grupo, posicao_no_gr
)
SELECT
  grupo,
  posicao_no_gr,
  ordem,
  envios,
  entregues,
  round(100.0 * envios / sum(envios) OVER (PARTITION BY grupo), 4)   AS pct_envios,
  round(100.0 * entregues / nullif(envios, 0), 4)                    AS taxa_entrega_pct,
  round(100.0 * wilson_inf(entregues, envios), 4)                    AS ic95_inf_pct,
  round(100.0 * wilson_sup(entregues, envios), 4)                    AS ic95_sup_pct
FROM agg
;
SELECT * FROM vt_res_04_entrega_por_ranking ORDER BY grupo, ordem;


/* -----------------------------------------------------------------------------
   04.2  TESTE DE MONOTONICIDADE DO RANKING

   Compara cada posição do ranking com a posição imediatamente anterior. Um
   ranking bem calibrado produz diferenças positivas e significantes em favor
   da posição melhor colocada.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_04_monotonicidade AS
WITH base AS (
  SELECT
    grupo,
    ordem,
    posicao_no_gr,
    envios,
    entregues,
    taxa_entrega_pct / 100.0 AS p
  FROM vt_res_04_entrega_por_ranking
  WHERE ordem <= 5
),
pares AS (
  SELECT
    b.grupo,
    b.posicao_no_gr                                       AS posicao_melhor,
    b.envios                                              AS envios_melhor,
    b.entregues                                           AS entregues_melhor,
    b.p                                                   AS p_melhor,
    s.posicao_no_gr                                       AS posicao_pior,
    s.envios                                              AS envios_pior,
    s.entregues                                           AS entregues_pior,
    s.p                                                   AS p_pior
  FROM base b
  JOIN base s
    ON b.grupo = s.grupo
   AND s.ordem = b.ordem + 1
),
z AS (
  SELECT
    *,
    (entregues_melhor + entregues_pior) / nullif(envios_melhor + envios_pior, 0) AS p_pool
  FROM pares
)
SELECT
  grupo,
  posicao_melhor,
  posicao_pior,
  envios_melhor,
  envios_pior,
  round(100.0 * p_melhor, 4)                AS taxa_melhor_pct,
  round(100.0 * p_pior, 4)                  AS taxa_pior_pct,
  round(100.0 * (p_melhor - p_pior), 4)     AS diferenca_pp,
  round((p_melhor - p_pior)
        / sqrt(p_pool * (1 - p_pool)
               * (1.0 / nullif(envios_melhor, 0) + 1.0 / nullif(envios_pior, 0))), 3) AS z,
  p_valor_bilateral(
    (p_melhor - p_pior)
    / sqrt(p_pool * (1 - p_pool)
           * (1.0 / nullif(envios_melhor, 0) + 1.0 / nullif(envios_pior, 0)))
  )                                          AS p_valor,
  CASE
    WHEN p_melhor > p_pior THEN 'Ordenacao respeitada, a posicao melhor entrega mais.'
    ELSE 'Ordenacao invertida neste par, revisar o criterio de ranking.'
  END                                        AS leitura
FROM z
;
SELECT * FROM vt_res_04_monotonicidade ORDER BY grupo, posicao_melhor;


/* -----------------------------------------------------------------------------
   04.3  DISPONIBILIDADE DE ALTERNATIVAS NO GOLDEN RECORD

   Quantas posições de ranking existem por CPF acionado. Um CPF com uma única
   posição não oferece plano alternativo quando a substituição pede o segundo
   ou o terceiro número.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_04_profundidade AS
SELECT
  e.grupo,
  CASE WHEN p.rankings_disponiveis >= 4 THEN '4 ou mais'
       ELSE CAST(coalesce(p.rankings_disponiveis, 0) AS STRING) END AS rankings_disponiveis,
  count(DISTINCT e.cpf)                                             AS cpfs,
  count(*)                                                          AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY e.grupo), 4) AS pct_envios,
  round(100.0 * avg(e.entregue), 4)                                 AS taxa_entrega_pct
FROM vt_experimento e
LEFT JOIN vt_gr_profundidade_cpf p ON e.cpf = p.cpf
GROUP BY e.grupo,
  CASE WHEN p.rankings_disponiveis >= 4 THEN '4 ou mais'
       ELSE CAST(coalesce(p.rankings_disponiveis, 0) AS STRING) END
;
SELECT * FROM vt_res_04_profundidade ORDER BY grupo, rankings_disponiveis;


/* =============================================================================
   SEÇÃO 05  EXPERIMENTO NATURAL, CONCORDÂNCIA DE TELEFONE
   =============================================================================
   Compara a entrega de SMS quando o CRM usou, por coincidência, o telefone de
   ranking 1 do Golden Record contra quando usou outro número.

   POR QUE ISSO SE APROXIMA DE UM EXPERIMENTO
   O Golden Record foi construído a partir de fontes que não alimentam o CRM e
   não observam o resultado dos disparos. A coincidência entre os dois telefones
   ocorre por sobreposição de cadastros, não por decisão de quem conhecia o
   desfecho. A alocação aos braços é, portanto, independente do resultado.
   A ressalva honesta é que clientes cujos telefones coincidem entre fontes
   podem ter cadastro mais estável. As seções 05.2, 06 e 10 atacam essa ressalva
   controlando por campanha, por pessoa e por recortes alternativos.

   [JÚNIOR]    Duas taxas de entrega e um p-valor. Abaixo de 0,05 a diferença
               não é acaso. A versão estratificada repete a conta dentro de cada
               campanha e soma, e é o número que sustenta a conclusão.
   [SÊNIOR]    O estimador principal é Cochran, Mantel e Haenszel, com razão de
               chances combinada, intervalo pela variância de Robins, Breslow e
               Greenland, e diferença de risco ponderada pelos pesos usuais.
               Estratos com um único braço não contribuem por construção.
   [EXECUTIVO] O número de decisão é a diferença em pontos percentuais
               controlada por campanha, acompanhada do p-valor.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   05.1  COMPARAÇÃO DIRETA ENTRE OS DOIS BRAÇOS
----------------------------------------------------------------------------- */
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
    k1 / nullif(n1, 0)               AS p1,
    k0 / nullif(n0, 0)               AS p0,
    (k1 + k0) / nullif(n1 + n0, 0)   AS p_pool
  FROM agg
),
z AS (
  SELECT
    *,
    (p1 - p0) / sqrt(p_pool * (1 - p_pool)
                     * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))  AS z_score,
    sqrt(p1 * (1 - p1) / nullif(n1, 0) + p0 * (1 - p0) / nullif(n0, 0)) AS se_diff
  FROM calc
)
SELECT
  grupo,
  n1                                               AS envios_concordante,
  k1                                               AS entregues_concordante,
  round(100.0 * p1, 4)                             AS taxa_concordante_pct,
  round(100.0 * wilson_inf(k1, n1), 4)             AS ic95_inf_concordante,
  round(100.0 * wilson_sup(k1, n1), 4)             AS ic95_sup_concordante,
  n0                                               AS envios_discordante,
  k0                                               AS entregues_discordante,
  round(100.0 * p0, 4)                             AS taxa_discordante_pct,
  round(100.0 * wilson_inf(k0, n0), 4)             AS ic95_inf_discordante,
  round(100.0 * wilson_sup(k0, n0), 4)             AS ic95_sup_discordante,
  round(100.0 * (p1 - p0), 4)                      AS diferenca_pp,
  round(100.0 * (p1 - p0 - 1.959964 * se_diff), 4) AS diferenca_ic95_inf_pp,
  round(100.0 * (p1 - p0 + 1.959964 * se_diff), 4) AS diferenca_ic95_sup_pp,
  round(100.0 * (p1 - p0) / nullif(p0, 0), 4)      AS lift_relativo_pct,
  round((k1 / nullif(n1 - k1, 0))
        / nullif(k0 / nullif(n0 - k0, 0), 0), 4)   AS odds_ratio_bruta,
  round(z_score, 3)                                AS z,
  p_valor_bilateral(z_score)                       AS p_valor,
  CASE
    WHEN p_valor_bilateral(z_score) < 0.05 AND p1 > p0
      THEN 'Telefone do Golden Record entrega mais, diferenca significante.'
    WHEN p_valor_bilateral(z_score) < 0.05 AND p1 < p0
      THEN 'Telefone do Golden Record entrega menos, investigar antes de adotar.'
    ELSE 'Sem diferenca estatisticamente detectavel.'
  END                                              AS leitura
FROM z
;
SELECT * FROM vt_res_05_bruto ORDER BY grupo;


/* -----------------------------------------------------------------------------
   05.2  ESTRATOS POR CAMPANHA

   Tabela de contingência de cada campanha dentro de cada grupo.
     a  concordante e entregue        b  concordante e não entregue
     c  discordante e entregue        d  discordante e não entregue
   Os valores são convertidos para ponto flutuante porque o cálculo da variância
   envolve o cubo do total do estrato.
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


/* -----------------------------------------------------------------------------
   05.3  ESTIMADOR ESTRATIFICADO POR CAMPANHA

   Fórmulas aplicadas a cada estrato e somadas dentro do grupo:
     esperado de a         igual a n1 vezes m1 dividido por n
     variancia de a        igual a n1 n0 m1 m0 dividido por n ao quadrado vezes n menos um
     razao de chances      igual a soma de a d sobre n dividida pela soma de b c sobre n
     diferenca ponderada   pesos iguais a n1 n0 sobre n
   O intervalo da razão de chances usa a variância de Robins, Breslow e
   Greenland, consistente tanto para poucos estratos grandes quanto para muitos
   estratos pequenos, situação típica de uma base com mais de mil campanhas.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_estratificado AS
WITH s AS (
  SELECT
    e.*,
    a + b         AS n1,
    c + d         AS n0,
    a + c         AS m1,
    b + d         AS m0,
    a + b + c + d AS n
  FROM vt_estratos_campanha e
  CROSS JOIN vt_param p
  WHERE a + b > 0
    AND c + d > 0
    AND a + b + c + d >= p.min_n_estrato
),
t AS (
  SELECT
    *,
    n1 * m1 / n                             AS e_a,
    n1 * n0 * m1 * m0 / (n * n * (n - 1))   AS v_a,
    a * d / n                               AS r_k,
    b * c / n                               AS s_k,
    (a + d) / n                             AS p_k,
    (b + c) / n                             AS q_k,
    n1 * n0 / n                             AS w_rd,
    (a / n1) - (c / n0)                     AS rd_k
  FROM s
),
agg AS (
  SELECT
    grupo,
    count(*)                        AS n_estratos,
    sum(n)                          AS n_envios,
    sum(a)                          AS soma_a,
    sum(e_a)                        AS soma_e_a,
    sum(v_a)                        AS soma_v_a,
    sum(r_k)                        AS soma_r,
    sum(s_k)                        AS soma_s,
    sum(p_k * r_k)                  AS soma_pr,
    sum(p_k * s_k + q_k * r_k)      AS soma_ps_qr,
    sum(q_k * s_k)                  AS soma_qs,
    sum(w_rd * rd_k) / nullif(sum(w_rd), 0) AS rd_mh
  FROM t
  GROUP BY grupo
),
calc AS (
  SELECT
    *,
    soma_r / nullif(soma_s, 0)                                 AS or_mh,
    power(soma_a - soma_e_a, 2) / nullif(soma_v_a, 0)          AS chi2_cmh,
    soma_pr / nullif(2 * soma_r * soma_r, 0)
      + soma_ps_qr / nullif(2 * soma_r * soma_s, 0)
      + soma_qs / nullif(2 * soma_s * soma_s, 0)               AS var_ln_or
  FROM agg
)
SELECT
  grupo,
  n_estratos                                                    AS campanhas_no_teste,
  CAST(n_envios AS BIGINT)                                      AS envios_no_teste,
  round(100.0 * rd_mh, 4)                                       AS diferenca_pp_estratificada,
  round(or_mh, 4)                                               AS odds_ratio,
  round(exp(ln(or_mh) - 1.959964 * sqrt(var_ln_or)), 4)         AS odds_ratio_ic95_inf,
  round(exp(ln(or_mh) + 1.959964 * sqrt(var_ln_or)), 4)         AS odds_ratio_ic95_sup,
  round(chi2_cmh, 3)                                            AS qui2,
  p_valor_qui2_1gl(chi2_cmh)                                    AS p_valor,
  CASE
    WHEN p_valor_qui2_1gl(chi2_cmh) < 0.05 AND or_mh > 1
      THEN 'Controlando por campanha, o telefone do Golden Record entrega mais.'
    WHEN p_valor_qui2_1gl(chi2_cmh) < 0.05 AND or_mh < 1
      THEN 'Controlando por campanha, o telefone do Golden Record entrega menos.'
    ELSE 'Controlando por campanha nao ha diferenca detectavel.'
  END                                                           AS leitura
FROM calc
;
SELECT * FROM vt_res_05_estratificado ORDER BY grupo;


/* -----------------------------------------------------------------------------
   05.4  APROVEITAMENTO DOS ESTRATOS

   Campanhas com um único braço não informam sobre a diferença e ficam fora do
   estimador. Esta tabela mostra quanto volume isso representa.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_05_estratos_diag AS
SELECT
  grupo,
  CASE WHEN a + b > 0 AND c + d > 0 THEN 'AMBOS_BRACOS'
       WHEN a + b > 0                THEN 'SOMENTE_CONCORDANTE'
       ELSE                               'SOMENTE_DISCORDANTE' END AS situacao,
  count(*)                                                          AS n_campanhas,
  CAST(sum(a + b + c + d) AS BIGINT)                                AS n_envios,
  round(100.0 * sum(a + b + c + d)
        / sum(sum(a + b + c + d)) OVER (PARTITION BY grupo), 4)     AS pct_envios
FROM vt_estratos_campanha
GROUP BY grupo,
  CASE WHEN a + b > 0 AND c + d > 0 THEN 'AMBOS_BRACOS'
       WHEN a + b > 0                THEN 'SOMENTE_CONCORDANTE'
       ELSE                               'SOMENTE_DISCORDANTE' END
;
SELECT * FROM vt_res_05_estratos_diag ORDER BY grupo, n_envios DESC;


/* -----------------------------------------------------------------------------
   05.5  TAXAS POR CAMPANHA PARA CALIBRAÇÃO

   Taxa de entrega de cada braço dentro de cada campanha. É o insumo do
   contrafactual da seção 08, que projeta o desempenho do telefone do Golden
   Record usando a taxa observada na mesma campanha do disparo.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_taxa_por_campanha AS
SELECT
  grupo,
  campanha,
  a + b                                        AS n_concordante,
  CASE WHEN a + b > 0 THEN a / (a + b) END     AS taxa_concordante,
  c + d                                        AS n_discordante,
  CASE WHEN c + d > 0 THEN c / (c + d) END     AS taxa_discordante
FROM vt_estratos_campanha
;


/* =============================================================================
   SEÇÃO 06  DESENHO PAREADO DENTRO DO MESMO CPF
   =============================================================================
   Compara o mesmo cliente consigo mesmo. Existem CPFs que receberam SMS no
   telefone do Golden Record em um momento e em outro número em outro momento.
   Para esses casos, qualquer característica fixa da pessoa é idêntica nos dois
   lados da comparação, e o que resta como explicação da diferença é o telefone.

   [JÚNIOR]    Contamos em quantos clientes só o telefone do Golden Record
               entregou e em quantos só o outro número entregou. Se o primeiro
               for bem maior, o Golden Record é melhor.
   [SÊNIOR]    Teste de McNemar sobre pares discordantes. Para não deixar a
               exposição desbalanceada quando um CPF tem muitos envios de um
               braço e poucos do outro, sorteia-se um envio por braço com
               ordenação por hash, o que torna o sorteio reprodutível.
   [EXECUTIVO] É a evidência mais intuitiva do estudo, porque compara cada
               cliente com ele mesmo e dispensa qualquer ajuste estatístico.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   06.1  UNIVERSO PAREADO
----------------------------------------------------------------------------- */
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

CREATE OR REPLACE TEMP VIEW vt_res_06_universo AS
SELECT
  p.grupo,
  count(*)                    AS cpfs_pareados,
  CAST(sum(p.n_conc) AS BIGINT) AS envios_concordantes,
  CAST(sum(p.n_disc) AS BIGINT) AS envios_discordantes,
  round(avg(p.n_conc), 2)     AS media_envios_conc_por_cpf,
  round(avg(p.n_disc), 2)     AS media_envios_disc_por_cpf,
  max(t.cpfs_no_grupo)        AS cpfs_no_experimento,
  round(100.0 * count(*) / nullif(max(t.cpfs_no_grupo), 0), 4) AS pct_cpfs_pareados
FROM vt_pareado_cpf p
JOIN (
  SELECT grupo, count(DISTINCT cpf) AS cpfs_no_grupo
  FROM vt_experimento GROUP BY grupo
) t ON p.grupo = t.grupo
GROUP BY p.grupo
;
SELECT * FROM vt_res_06_universo ORDER BY grupo;


/* -----------------------------------------------------------------------------
   06.2  TESTE PAREADO COM UM ENVIO POR BRAÇO

   Tabela de pares:
     b  o telefone do Golden Record entregou e o outro não
     c  o outro entregou e o do Golden Record não
   Pares em que os dois entregaram ou os dois falharam não carregam informação
   sobre a diferença e são excluídos do teste, embora apareçam na contagem.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_pareado_um_por_braco AS
WITH selecionado AS (
  SELECT
    e.grupo, e.cpf, e.concordante, e.entregue
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
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS ambos_entregaram,
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS b_so_gr,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS c_so_outro,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS nenhum_entregou,
    avg(entregue_gr)                                                        AS taxa_gr,
    avg(entregue_outro)                                                     AS taxa_outro
  FROM vt_pareado_um_por_braco
  GROUP BY grupo
),
calc AS (
  SELECT
    *,
    CASE WHEN b_so_gr + c_so_outro > 0
         THEN power(b_so_gr - c_so_outro, 2) / (b_so_gr + c_so_outro) END AS chi2
  FROM tab
)
SELECT
  grupo,
  n_pares,
  ambos_entregaram,
  b_so_gr                                       AS so_golden_record_entregou,
  c_so_outro                                    AS so_outro_telefone_entregou,
  nenhum_entregou,
  round(100.0 * taxa_gr, 4)                     AS taxa_telefone_gr_pct,
  round(100.0 * taxa_outro, 4)                  AS taxa_outro_telefone_pct,
  round(100.0 * (taxa_gr - taxa_outro), 4)      AS diferenca_pp,
  round(b_so_gr / nullif(c_so_outro, 0), 4)     AS razao_favoravel,
  round(chi2, 3)                                AS qui2,
  p_valor_qui2_1gl(chi2)                        AS p_valor,
  CASE
    WHEN p_valor_qui2_1gl(chi2) < 0.05 AND b_so_gr > c_so_outro
      THEN 'Para o mesmo cliente, o telefone do Golden Record entrega mais.'
    WHEN p_valor_qui2_1gl(chi2) < 0.05
      THEN 'Para o mesmo cliente, o telefone do Golden Record entrega menos.'
    ELSE 'Sem diferenca detectavel no desenho pareado.'
  END                                           AS leitura
FROM calc
;
SELECT * FROM vt_res_06_pareado ORDER BY grupo;


/* -----------------------------------------------------------------------------
   06.3  DIFERENÇA MÉDIA PAREADA COM TODOS OS ENVIOS

   Usa toda a informação disponível de cada CPF, e não apenas um envio por
   braço. Complementa 06.2 ao custo de exposição desigual entre os braços.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_diferenca_media AS
WITH d AS (
  SELECT grupo, cpf, taxa_conc - taxa_disc AS dif FROM vt_pareado_cpf
),
agg AS (
  SELECT grupo, count(*) AS n, avg(dif) AS media_dif, stddev_samp(dif) AS dp_dif
  FROM d GROUP BY grupo
)
SELECT
  grupo,
  n                                                                    AS cpfs_pareados,
  round(100.0 * media_dif, 4)                                          AS diferenca_media_pp,
  round(100.0 * (media_dif - 1.959964 * dp_dif / sqrt(n)), 4)          AS ic95_inf_pp,
  round(100.0 * (media_dif + 1.959964 * dp_dif / sqrt(n)), 4)          AS ic95_sup_pp,
  round(media_dif / nullif(dp_dif / sqrt(n), 0), 3)                    AS z,
  p_valor_bilateral(media_dif / nullif(dp_dif / sqrt(n), 0))           AS p_valor
FROM agg
;
SELECT * FROM vt_res_06_diferenca_media ORDER BY grupo;


/* -----------------------------------------------------------------------------
   06.4  VERSÃO ESTRITA, MESMO CPF E MESMA CAMPANHA

   Exige que os dois braços ocorram dentro da mesma campanha, o que elimina
   qualquer efeito de período, mensagem ou público. É o desenho mais próximo de
   um teste controlado que a base observacional permite montar.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_06_pareado_mesma_campanha AS
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
    sum(CASE WHEN entregue_gr = 1 AND entregue_outro = 0 THEN 1 ELSE 0 END) AS b_so_gr,
    sum(CASE WHEN entregue_gr = 0 AND entregue_outro = 1 THEN 1 ELSE 0 END) AS c_so_outro,
    avg(entregue_gr)                                                        AS taxa_gr,
    avg(entregue_outro)                                                     AS taxa_outro
  FROM pares
  GROUP BY grupo
),
calc AS (
  SELECT *,
    CASE WHEN b_so_gr + c_so_outro > 0
         THEN power(b_so_gr - c_so_outro, 2) / (b_so_gr + c_so_outro) END AS chi2
  FROM tab
)
SELECT
  grupo,
  n_pares,
  b_so_gr                                    AS so_golden_record_entregou,
  c_so_outro                                 AS so_outro_telefone_entregou,
  round(100.0 * taxa_gr, 4)                  AS taxa_telefone_gr_pct,
  round(100.0 * taxa_outro, 4)               AS taxa_outro_telefone_pct,
  round(100.0 * (taxa_gr - taxa_outro), 4)   AS diferenca_pp,
  round(chi2, 3)                             AS qui2,
  p_valor_qui2_1gl(chi2)                     AS p_valor,
  CASE
    WHEN n_pares < 500 THEN 'Amostra reduzida, tratar como ilustrativo.'
    WHEN p_valor_qui2_1gl(chi2) < 0.05 AND b_so_gr > c_so_outro
      THEN 'Mesma campanha e mesmo cliente, o telefone do Golden Record entrega mais.'
    WHEN p_valor_qui2_1gl(chi2) < 0.05
      THEN 'Mesma campanha e mesmo cliente, o telefone do Golden Record entrega menos.'
    ELSE 'Sem diferenca detectavel.'
  END                                        AS leitura
FROM calc
;
SELECT * FROM vt_res_06_pareado_mesma_campanha ORDER BY grupo;


/* =============================================================================
   SEÇÃO 07  SIMULAÇÃO DE SUBSTITUIÇÃO DE RANKING
   =============================================================================
   Responde à pergunta central desta versão do estudo: se, em vez de acionar os
   telefones na ordem do cadastro do CRM, a operação acionasse os telefones na
   ordem do Golden Record, o que mudaria?

   REGRA DE SUBSTITUIÇÃO
   Cada disparo ocupa uma posição dentro da campanha, do primeiro ao enésimo
   telefone acionado para aquele CPF. A regra mapeia posição por posição:
     posição 1 do CRM recebe o telefone de ranking 1 do Golden Record
     posição 2 do CRM recebe o telefone de ranking 2
     posição 3 do CRM recebe o telefone de ranking 3
     posição 4 do CRM recebe o telefone de ranking 4
     posições 5 em diante recebem novamente o telefone de ranking 1
   Quando o CPF não possui a posição pedida no Golden Record, o plano recorre ao
   ranking 1, e essa ocorrência fica registrada como uso de reserva.

   COMO O DESEMPENHO DO PLANO É AVALIADO
   Sempre que o telefone indicado pelo plano também foi acionado pelo CRM na
   mesma campanha, o desfecho daquele número é um fato observado, não uma
   estimativa. Isso cria um subconjunto em que a comparação entre a ordem do
   CRM e a ordem do Golden Record é feita inteiramente com dados reais, sem
   nenhuma suposição. Esse subconjunto é tratado como o experimento controlado
   desta seção.

   [JÚNIOR]    Para cada SMS, descobrimos qual número o Golden Record mandaria
               usar naquela posição. Quando esse número também foi disparado na
               mesma campanha, já sabemos se ele chegou, então dá para comparar
               os dois lado a lado sem chutar nada.
   [SÊNIOR]    Dois estimadores independentes. O primeiro é um teste pareado
               posição a posição, restrito aos casos de desfecho observado, que
               mede se o telefone do plano supera o telefone efetivamente usado.
               O segundo é uma simulação de sequência por CPF e campanha, que
               mede em que posição cada ordenação alcança a primeira entrega e,
               com isso, quantos disparos seriam poupados.
   [EXECUTIVO] Duas perguntas de negócio saem daqui. A primeira é se a ordem do
               Golden Record acerta o telefone mais cedo. A segunda é quantos
               disparos deixariam de ser pagos por chegar ao número certo antes.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   07.1  RESULTADO OBSERVADO POR TELEFONE

   Consolida o que já se sabe sobre cada número acionado, no nível do CPF e no
   nível do CPF com campanha. É a fonte de verdade usada para avaliar o plano
   sem recorrer a estimativas.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_resultado_por_telefone_cpf AS
SELECT
  cpf,
  chave_crm,
  max(entregue)            AS ja_entregou,
  count(*)                 AS tentativas,
  avg(entregue)            AS taxa_observada,
  count(DISTINCT campanha) AS campanhas
FROM vt_crm_envios
GROUP BY cpf, chave_crm
;


/* -----------------------------------------------------------------------------
   07.2  PLANO DE SUBSTITUIÇÃO POSIÇÃO A POSIÇÃO

   Uma linha por disparo, com o telefone que o plano do Golden Record usaria
   naquela posição e com a informação disponível sobre o desfecho desse número.

   classe_substituicao
     PLANO_IGUAL_AO_USADO           o plano confirmaria o número já acionado
     PLANO_OBSERVADO_NA_CAMPANHA    o plano trocaria por um número que também
                                    foi acionado na mesma campanha, portanto com
                                    desfecho conhecido
     PLANO_OBSERVADO_EM_OUTRA_CAMPANHA  o número do plano foi acionado para o
                                    mesmo CPF em outra campanha
     PLANO_NAO_OBSERVADO            o número do plano nunca foi acionado para
                                    aquele CPF
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_plano_substituicao AS
WITH alvo AS (
  SELECT
    e.grupo,
    e.cpf,
    e.campanha,
    e.telefone_crm,
    e.chave_crm,
    e.entregue,
    e.ranking_crm,
    e.telefones_na_campanha,
    e.ranking_gr_do_telefone_usado,
    CASE WHEN e.ranking_crm <= p.profundidade_ranking THEN e.ranking_crm ELSE 1 END AS ranking_gr_alvo
  FROM vt_experimento e
  CROSS JOIN vt_param p
),
com_plano AS (
  SELECT
    a.*,
    ga.telefone_gr                                   AS telefone_alvo,
    ga.chave_gr                                      AS chave_alvo,
    g1.telefone_gr                                   AS telefone_reserva,
    g1.chave_gr                                      AS chave_reserva,
    coalesce(ga.telefone_gr, g1.telefone_gr)         AS telefone_plano,
    coalesce(ga.chave_gr, g1.chave_gr)               AS chave_plano,
    CASE WHEN ga.cpf IS NOT NULL THEN 'RANKING_EXATO'
         WHEN g1.cpf IS NOT NULL THEN 'RESERVA_RANKING_1'
         ELSE 'SEM_PLANO' END                        AS origem_plano
  FROM alvo a
  LEFT JOIN vt_gr_todos_rankings ga
    ON a.cpf = ga.cpf AND ga.ranking = a.ranking_gr_alvo
  LEFT JOIN vt_gr_rank1 g1
    ON a.cpf = g1.cpf
),
com_desfecho AS (
  SELECT
    c.*,
    r.entregue      AS entregue_plano_campanha,
    h.ja_entregou   AS plano_ja_entregou_algum_dia,
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
    WHEN telefone_plano IS NULL                THEN 'SEM_PLANO'
    WHEN chave_plano = chave_crm               THEN 'PLANO_IGUAL_AO_USADO'
    WHEN entregue_plano_campanha IS NOT NULL   THEN 'PLANO_OBSERVADO_NA_CAMPANHA'
    WHEN plano_ja_entregou_algum_dia IS NOT NULL THEN 'PLANO_OBSERVADO_EM_OUTRA_CAMPANHA'
    ELSE                                            'PLANO_NAO_OBSERVADO'
  END AS classe_substituicao
FROM com_desfecho
;


/* -----------------------------------------------------------------------------
   07.3  COMPOSIÇÃO DO PLANO DE SUBSTITUIÇÃO

   Quanto do plano confirma o número já usado, quanto troca por um número de
   desfecho conhecido e quanto troca por um número sem histórico. A soma das
   duas primeiras classes define o volume que pode ser avaliado sem suposição.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_composicao AS
SELECT
  grupo,
  classe_substituicao,
  origem_plano,
  count(*)                                                             AS envios,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY grupo), 4) AS pct_envios,
  round(100.0 * avg(entregue), 4)                                      AS taxa_entrega_observada_pct
FROM vt_plano_substituicao
GROUP BY grupo, classe_substituicao, origem_plano
;
SELECT * FROM vt_res_07_composicao ORDER BY grupo, envios DESC;


/* -----------------------------------------------------------------------------
   07.4  SUBSTITUIÇÃO POR POSIÇÃO DO DISPARO

   Mostra, para cada posição de acionamento, com que frequência o plano do
   Golden Record confirma ou troca o número, e qual a taxa de entrega observada
   naquela posição. Posições mais profundas tendem a concentrar números de pior
   qualidade no cadastro do CRM.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_por_posicao AS
SELECT
  grupo,
  CASE WHEN ranking_crm >= 5 THEN '5 ou mais'
       ELSE CAST(ranking_crm AS STRING) END                            AS posicao_disparo,
  count(*)                                                             AS envios,
  round(100.0 * avg(entregue), 4)                                      AS taxa_entrega_pct,
  sum(CASE WHEN classe_substituicao = 'PLANO_IGUAL_AO_USADO' THEN 1 ELSE 0 END) AS plano_confirma,
  round(100.0 * avg(CASE WHEN classe_substituicao = 'PLANO_IGUAL_AO_USADO' THEN 1 ELSE 0 END), 4) AS pct_plano_confirma,
  sum(CASE WHEN classe_substituicao <> 'PLANO_IGUAL_AO_USADO' THEN 1 ELSE 0 END) AS plano_troca,
  round(100.0 * avg(CASE WHEN origem_plano = 'RESERVA_RANKING_1' THEN 1 ELSE 0 END), 4) AS pct_uso_de_reserva
FROM vt_plano_substituicao
GROUP BY grupo,
  CASE WHEN ranking_crm >= 5 THEN '5 ou mais' ELSE CAST(ranking_crm AS STRING) END
;
SELECT * FROM vt_res_07_por_posicao ORDER BY grupo, posicao_disparo;


/* -----------------------------------------------------------------------------
   07.5  TESTE PAREADO DA SUBSTITUIÇÃO, DESFECHO OBSERVADO

   Restringe a comparação aos disparos em que o plano trocaria o número por
   outro que também foi acionado na mesma campanha. Nesses casos os dois
   desfechos são fatos registrados, e a comparação não depende de nenhuma
   premissa.

     b  o telefone do plano entregou e o telefone usado não entregou
     c  o telefone usado entregou e o do plano não entregou
   O teste de McNemar avalia se o placar entre b e c é desequilibrado além do
   acaso.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_pareado_substituicao AS
WITH base AS (
  SELECT
    grupo,
    entregue                AS entregue_usado,
    entregue_plano_campanha AS entregue_plano
  FROM vt_plano_substituicao
  WHERE classe_substituicao = 'PLANO_OBSERVADO_NA_CAMPANHA'
),
tab AS (
  SELECT
    grupo,
    count(*)                                                             AS n_comparacoes,
    sum(CASE WHEN entregue_plano = 1 AND entregue_usado = 1 THEN 1 ELSE 0 END) AS ambos_entregaram,
    sum(CASE WHEN entregue_plano = 1 AND entregue_usado = 0 THEN 1 ELSE 0 END) AS b_so_plano,
    sum(CASE WHEN entregue_plano = 0 AND entregue_usado = 1 THEN 1 ELSE 0 END) AS c_so_usado,
    sum(CASE WHEN entregue_plano = 0 AND entregue_usado = 0 THEN 1 ELSE 0 END) AS nenhum_entregou,
    avg(entregue_plano)                                                  AS taxa_plano,
    avg(entregue_usado)                                                  AS taxa_usado
  FROM base
  GROUP BY grupo
),
calc AS (
  SELECT *,
    CASE WHEN b_so_plano + c_so_usado > 0
         THEN power(b_so_plano - c_so_usado, 2) / (b_so_plano + c_so_usado) END AS chi2
  FROM tab
)
SELECT
  grupo,
  n_comparacoes,
  ambos_entregaram,
  b_so_plano                                     AS so_plano_entregou,
  c_so_usado                                     AS so_telefone_usado_entregou,
  nenhum_entregou,
  round(100.0 * taxa_plano, 4)                   AS taxa_plano_pct,
  round(100.0 * taxa_usado, 4)                   AS taxa_telefone_usado_pct,
  round(100.0 * (taxa_plano - taxa_usado), 4)    AS diferenca_pp,
  round(chi2, 3)                                 AS qui2,
  p_valor_qui2_1gl(chi2)                         AS p_valor,
  CASE
    WHEN p_valor_qui2_1gl(chi2) < 0.05 AND b_so_plano > c_so_usado
      THEN 'A ordem do Golden Record acerta o telefone com mais frequencia nesta posicao.'
    WHEN p_valor_qui2_1gl(chi2) < 0.05
      THEN 'A ordem do CRM acerta com mais frequencia nesta posicao.'
    ELSE 'Sem diferenca detectavel entre as duas ordens.'
  END                                            AS leitura
FROM calc
;
SELECT * FROM vt_res_07_pareado_substituicao ORDER BY grupo;


/* -----------------------------------------------------------------------------
   07.6  TESTE PAREADO RESTRITO AO PRIMEIRO DISPARO

   O primeiro acionamento é o de maior valor operacional, porque define se a
   campanha vai precisar de tentativas adicionais. Este recorte isola essa
   posição.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_primeiro_disparo AS
WITH base AS (
  SELECT
    grupo,
    entregue                AS entregue_usado,
    entregue_plano_campanha AS entregue_plano
  FROM vt_plano_substituicao
  WHERE classe_substituicao = 'PLANO_OBSERVADO_NA_CAMPANHA'
    AND ranking_crm = 1
),
tab AS (
  SELECT
    grupo,
    count(*)                                                             AS n_comparacoes,
    sum(CASE WHEN entregue_plano = 1 AND entregue_usado = 0 THEN 1 ELSE 0 END) AS b_so_plano,
    sum(CASE WHEN entregue_plano = 0 AND entregue_usado = 1 THEN 1 ELSE 0 END) AS c_so_usado,
    avg(entregue_plano)                                                  AS taxa_plano,
    avg(entregue_usado)                                                  AS taxa_usado
  FROM base
  GROUP BY grupo
),
calc AS (
  SELECT *,
    CASE WHEN b_so_plano + c_so_usado > 0
         THEN power(b_so_plano - c_so_usado, 2) / (b_so_plano + c_so_usado) END AS chi2
  FROM tab
)
SELECT
  grupo,
  n_comparacoes,
  b_so_plano                                   AS so_plano_entregou,
  c_so_usado                                   AS so_telefone_usado_entregou,
  round(100.0 * taxa_plano, 4)                 AS taxa_plano_pct,
  round(100.0 * taxa_usado, 4)                 AS taxa_telefone_usado_pct,
  round(100.0 * (taxa_plano - taxa_usado), 4)  AS diferenca_pp,
  round(chi2, 3)                               AS qui2,
  p_valor_qui2_1gl(chi2)                       AS p_valor
FROM calc
;
SELECT * FROM vt_res_07_primeiro_disparo ORDER BY grupo;


/* -----------------------------------------------------------------------------
   07.7  SIMULAÇÃO DE SEQUÊNCIA POR CLIENTE E CAMPANHA

   Reconstrói, para cada par de CPF e campanha, duas trajetórias de
   acionamento: a que de fato ocorreu, na ordem do CRM, e a que teria ocorrido
   na ordem do Golden Record. Para cada trajetória identifica em que posição a
   primeira entrega acontece.

   posicoes_nao_observadas conta as posições do plano cujo número não foi
   acionado naquela campanha, portanto sem desfecho conhecido. Quando esse
   contador é zero, a comparação entre as duas ordens é integralmente
   observada, e o par entra no conjunto controlado.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_simulacao_sequencia AS
WITH agregado AS (
  SELECT
    grupo,
    cpf,
    campanha,
    count(*)                                                                AS tentativas,
    min(CASE WHEN entregue = 1 THEN ranking_crm END)                        AS pos_sucesso_crm,
    min(CASE WHEN entregue_plano_campanha = 1 THEN ranking_crm END)         AS pos_sucesso_plano,
    sum(CASE WHEN entregue_plano_campanha IS NULL THEN 1 ELSE 0 END)        AS posicoes_nao_observadas,
    max(CASE WHEN origem_plano = 'RESERVA_RANKING_1' THEN 1 ELSE 0 END)     AS usou_reserva
  FROM vt_plano_substituicao
  GROUP BY grupo, cpf, campanha
)
SELECT
  *,
  coalesce(pos_sucesso_crm, tentativas)                                     AS disparos_crm,
  coalesce(pos_sucesso_plano, tentativas)                                   AS disparos_plano,
  coalesce(pos_sucesso_crm, tentativas)
    - coalesce(pos_sucesso_plano, tentativas)                               AS economia_disparos,
  CASE
    WHEN pos_sucesso_crm IS NOT NULL AND pos_sucesso_plano IS NOT NULL THEN 'AMBOS_ENTREGAM'
    WHEN pos_sucesso_plano IS NOT NULL                                 THEN 'SOMENTE_PLANO_ENTREGA'
    WHEN pos_sucesso_crm IS NOT NULL                                   THEN 'SOMENTE_CRM_ENTREGA'
    ELSE                                                                    'NENHUM_ENTREGA'
  END                                                                       AS desfecho_comparado,
  (posicoes_nao_observadas = 0)                                             AS totalmente_observado
FROM agregado
;


/* -----------------------------------------------------------------------------
   07.8  RESULTADO DA SIMULAÇÃO NO CONJUNTO CONTROLADO

   Restringe a leitura aos pares de CPF e campanha integralmente observados.
   Nesse recorte, tanto a ordem do CRM quanto a ordem do Golden Record são
   avaliadas apenas com desfechos reais.

   O QUE ESTE RECORTE PODE E NÃO PODE MEDIR
   Um par só é integralmente observado quando todos os números do plano também
   foram acionados pelo CRM naquela campanha. Isso significa que, aqui, o plano
   trabalha sobre um subconjunto dos números que a operação já tentou. A
   consequência é direta e precisa ser explicitada: neste recorte a reordenação
   não pode conquistar cobertura nova, porque não existe número inédito em jogo.
   O que ela pode fazer é alcançar mais cedo o número que funciona, e é isso que
   a economia de disparos mede. O ganho de cobertura, que depende de números
   ainda não acionados, é estimado na seção 08 e não aqui.

   O caminho inverso, porém, é observável: quando o número que resolveu o
   contato no CRM está fora da profundidade do plano, a reordenação perde esse
   contato. Essa perda aparece em pares_com_perda_de_cobertura e é o principal
   risco da política de truncamento.

   economia_media_disparos é o número médio de acionamentos poupados por par.
   Multiplicado pelo custo unitário na seção 09, vira economia direta de mídia.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_sequencia AS
SELECT
  grupo,
  count(*)                                                          AS pares_avaliados,
  CAST(sum(tentativas) AS BIGINT)                                   AS disparos_realizados,
  CAST(sum(disparos_crm) AS BIGINT)                                 AS disparos_ate_desfecho_crm,
  CAST(sum(disparos_plano) AS BIGINT)                               AS disparos_ate_desfecho_plano,
  CAST(sum(economia_disparos) AS BIGINT)                            AS economia_disparos,
  round(avg(economia_disparos), 4)                                  AS economia_media_disparos,
  round(100.0 * sum(economia_disparos)
        / nullif(sum(disparos_crm), 0), 4)                          AS pct_reducao_disparos,
  sum(CASE WHEN economia_disparos > 0 THEN 1 ELSE 0 END)            AS pares_com_ganho,
  sum(CASE WHEN economia_disparos < 0 THEN 1 ELSE 0 END)            AS pares_com_atraso,
  sum(CASE WHEN desfecho_comparado = 'SOMENTE_CRM_ENTREGA' THEN 1 ELSE 0 END) AS pares_com_perda_de_cobertura,
  round(100.0 * avg(CASE WHEN desfecho_comparado = 'SOMENTE_CRM_ENTREGA' THEN 1 ELSE 0 END), 4) AS pct_perda_de_cobertura,
  sum(CASE WHEN desfecho_comparado = 'AMBOS_ENTREGAM' THEN 1 ELSE 0 END)      AS pares_com_entrega_nas_duas_ordens,
  sum(CASE WHEN desfecho_comparado = 'NENHUM_ENTREGA' THEN 1 ELSE 0 END)      AS pares_sem_entrega
FROM vt_simulacao_sequencia
WHERE totalmente_observado
GROUP BY grupo
;
SELECT * FROM vt_res_07_sequencia ORDER BY grupo;


/* -----------------------------------------------------------------------------
   07.9  RISCO DE TRUNCAMENTO DO PLANO

   Detalha os casos em que a ordem do CRM alcançou entrega e a ordem do Golden
   Record não alcançaria, abertos pela posição em que o CRM obteve sucesso.
   Concentração nas posições mais profundas indica que a perda decorre do limite
   de profundidade do plano, e não da qualidade do ranking. Nesse caso, ampliar
   a profundidade resolve.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_risco_truncamento AS
SELECT
  grupo,
  CASE WHEN pos_sucesso_crm >= 5 THEN '5 ou mais'
       ELSE CAST(pos_sucesso_crm AS STRING) END                     AS posicao_de_sucesso_no_crm,
  count(*)                                                          AS pares,
  sum(CASE WHEN desfecho_comparado = 'SOMENTE_CRM_ENTREGA' THEN 1 ELSE 0 END) AS pares_perdidos_pelo_plano,
  round(100.0 * avg(CASE WHEN desfecho_comparado = 'SOMENTE_CRM_ENTREGA' THEN 1 ELSE 0 END), 4) AS pct_perda,
  round(avg(economia_disparos), 4)                                  AS economia_media_disparos
FROM vt_simulacao_sequencia
WHERE totalmente_observado
  AND pos_sucesso_crm IS NOT NULL
GROUP BY grupo,
  CASE WHEN pos_sucesso_crm >= 5 THEN '5 ou mais'
       ELSE CAST(pos_sucesso_crm AS STRING) END
;
SELECT * FROM vt_res_07_risco_truncamento ORDER BY grupo, posicao_de_sucesso_no_crm;


/* -----------------------------------------------------------------------------
   07.10  ABRANGÊNCIA DA SIMULAÇÃO

   Proporção dos pares de CPF e campanha que puderam ser avaliados sem
   suposição. Quanto maior, mais representativo é o resultado da seção 07.8.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_07_abrangencia AS
SELECT
  grupo,
  count(*)                                                                AS pares_totais,
  sum(CASE WHEN totalmente_observado THEN 1 ELSE 0 END)                   AS pares_observados,
  round(100.0 * avg(CASE WHEN totalmente_observado THEN 1 ELSE 0 END), 4) AS pct_observados,
  CAST(sum(tentativas) AS BIGINT)                                         AS disparos_totais,
  CAST(sum(CASE WHEN totalmente_observado THEN tentativas ELSE 0 END) AS BIGINT) AS disparos_observados,
  round(100.0 * sum(CASE WHEN totalmente_observado THEN tentativas ELSE 0 END)
        / nullif(sum(tentativas), 0), 4)                                  AS pct_disparos_observados
FROM vt_simulacao_sequencia
GROUP BY grupo
;
SELECT * FROM vt_res_07_abrangencia ORDER BY grupo;


/* =============================================================================
   SEÇÃO 08  CONTRAFACTUAL DOS INSUCESSOS
   =============================================================================
   Responde à pergunta de negócio original: dado um SMS que não foi entregue, o
   telefone do Golden Record seria diferente do que foi usado? E se fosse,
   quantas entregas teriam sido recuperadas?

   COMO A PREMISSA OTIMISTA É TRATADA
   Assumir que todo insucesso com telefone divergente viraria sucesso é o limite
   superior lógico, não uma estimativa. Esse cenário aparece nomeado como teto e
   sempre acompanhado de quatro alternativas mais conservadoras, entre elas uma
   que só conta desfechos já observados. A faixa entre o piso e o teto é o
   argumento, e o cenário calibrado por campanha é o número central.

   AS PERDAS ENTRAM NA CONTA
   Adotar o Golden Record também substitui números que hoje funcionam. Cada
   cenário estima quantas entregas atuais seriam colocadas em risco, e o saldo
   líquido é sempre a diferença entre recuperações e perdas.

   [JÚNIOR]    Filtramos os SMS que falharam e verificamos em quais o Golden
               Record apontaria outro número. Esses são os candidatos. Depois
               multiplicamos os candidatos por uma taxa de sucesso, que muda
               conforme o cenário.
   [SÊNIOR]    O contrafactual correto para um insucesso na campanha k é a taxa
               de entrega do braço concordante na mesma campanha k, com reserva
               na taxa global quando a campanha não possui esse braço. A
               evidência direta usa o CPF como controle e é a menos atacável,
               porém cobre apenas quem já teve o número do Golden Record
               acionado.
   [EXECUTIVO] A tabela 08.5 é a base do valuation. Ela informa quantas entregas
               líquidas cada premissa produz.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   08.1  INSUMOS DO CONTRAFACTUAL
----------------------------------------------------------------------------- */
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
  e.telefone_crm,
  e.telefone_gr,
  e.entregue,
  o.gr_taxa_entrega,
  CASE
    WHEN o.cpf IS NULL           THEN 'GR_NUNCA_ACIONADO'
    WHEN o.gr_alguma_entrega = 1 THEN 'GR_ACIONADO_E_ENTREGOU'
    ELSE                              'GR_ACIONADO_SEM_ENTREGA'
  END                                                       AS evidencia_direta,
  coalesce(t.taxa_concordante, g.taxa_concordante_global)   AS taxa_calibracao_campanha,
  g.taxa_concordante_global
FROM vt_experimento e
LEFT JOIN vt_gr_observado_no_crm o
  ON e.grupo = o.grupo AND e.cpf = o.cpf
LEFT JOIN vt_taxa_por_campanha t
  ON e.grupo = t.grupo AND e.campanha = t.campanha
JOIN vt_taxa_global_grupo g
  ON e.grupo = g.grupo
WHERE e.classe_concordancia = 'DIFERENTE'
;


/* -----------------------------------------------------------------------------
   08.2  ANATOMIA DO INSUCESSO

   Dos SMS não entregues, quantos teriam ido para outro número. A leitura por
   CPF complementa a leitura por envio ao mostrar quantos clientes distintos
   estão por trás do volume.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_08_anatomia AS
SELECT
  grupo,
  'ENVIO' AS grao,
  count(*)                                                                    AS insucessos,
  sum(CASE WHEN NOT tem_gr THEN 1 ELSE 0 END)                                 AS sem_gr,
  sum(CASE WHEN classe_concordancia IN ('IGUAL_EXATO','IGUAL_TOLERANTE') THEN 1 ELSE 0 END) AS gr_igual,
  sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)          AS gr_diferente,
  round(100.0 * sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)
        / nullif(count(*), 0), 4)                                             AS pct_sobre_total,
  round(100.0 * sum(CASE WHEN classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)
        / nullif(sum(CASE WHEN tem_gr THEN 1 ELSE 0 END), 0), 4)              AS pct_sobre_com_gr
FROM vt_base_grupo
WHERE entregue = 0
GROUP BY grupo
UNION ALL
SELECT
  grupo,
  'CPF' AS grao,
  count(DISTINCT cpf),
  count(DISTINCT CASE WHEN NOT tem_gr THEN cpf END),
  count(DISTINCT CASE WHEN classe_concordancia IN ('IGUAL_EXATO','IGUAL_TOLERANTE') THEN cpf END),
  count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END),
  round(100.0 * count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END)
        / nullif(count(DISTINCT cpf), 0), 4),
  round(100.0 * count(DISTINCT CASE WHEN classe_concordancia = 'DIFERENTE' THEN cpf END)
        / nullif(count(DISTINCT CASE WHEN tem_gr THEN cpf END), 0), 4)
FROM vt_base_grupo
WHERE entregue = 0
GROUP BY grupo
;
SELECT * FROM vt_res_08_anatomia ORDER BY grupo, grao;


/* -----------------------------------------------------------------------------
   08.3  EVIDÊNCIA DIRETA SOBRE OS CANDIDATOS

   Para os insucessos com telefone divergente, verifica se o número do Golden
   Record já foi acionado para aquele CPF em outra campanha e com que resultado.
   A classe em que o número já entregou é a prova mais forte disponível sem
   teste controlado.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_08_evidencia AS
SELECT
  grupo,
  evidencia_direta,
  count(*)                                                             AS insucessos_candidatos,
  round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY grupo), 4) AS pct,
  count(DISTINCT cpf)                                                  AS cpfs,
  round(100.0 * avg(gr_taxa_entrega), 4)                               AS taxa_media_do_telefone_gr_pct
FROM vt_envios_gr_diferente
WHERE entregue = 0
GROUP BY grupo, evidencia_direta
;
SELECT * FROM vt_res_08_evidencia ORDER BY grupo, insucessos_candidatos DESC;


/* -----------------------------------------------------------------------------
   08.4  RECUPERAÇÕES E PERDAS POR CENÁRIO

   Cenários, do mais otimista ao mais conservador:
     1 TETO                    todo candidato vira entrega
     2 CALIBRADO_GLOBAL        taxa do braço concordante na base do grupo
     3 CALIBRADO_CAMPANHA      taxa do braço concordante na mesma campanha
     4 EVIDENCIA_EXTRAPOLADA   taxa observada do número do Golden Record entre
                               os CPFs em que ele já foi acionado
     5 PISO_OBSERVADO          apenas candidatos cujo número do Golden Record já
                               foi acionado e entregou

   As perdas espelham a mesma lógica sobre os SMS que hoje são entregues com
   número divergente do Golden Record.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_08_ganhos AS
WITH base AS (
  SELECT
    grupo,
    count(*)                                                                       AS candidatos,
    max(taxa_concordante_global)                                                   AS taxa_global,
    sum(taxa_calibracao_campanha)                                                  AS recup_campanha,
    sum(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN 1 ELSE 0 END)       AS candidatos_com_historico,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN gr_taxa_entrega END) AS taxa_historica,
    sum(CASE WHEN evidencia_direta = 'GR_ACIONADO_E_ENTREGOU' THEN 1 ELSE 0 END)   AS candidatos_com_entrega_provada
  FROM vt_envios_gr_diferente
  WHERE entregue = 0
  GROUP BY grupo
)
SELECT grupo, 1 AS ordem, 'TETO' AS cenario,
       'Todo insucesso com telefone divergente vira entrega. Limite superior logico.' AS premissa,
       candidatos, CAST(1.0 AS DOUBLE) AS taxa_aplicada,
       CAST(candidatos AS DOUBLE) AS entregas_recuperadas
FROM base
UNION ALL
SELECT grupo, 2, 'CALIBRADO_GLOBAL',
       'Candidatos multiplicados pela taxa de entrega do telefone do Golden Record na base do grupo.',
       candidatos, taxa_global, candidatos * taxa_global
FROM base
UNION ALL
SELECT grupo, 3, 'CALIBRADO_CAMPANHA',
       'Cada candidato multiplicado pela taxa do telefone do Golden Record na propria campanha.',
       candidatos, recup_campanha / nullif(candidatos, 0), recup_campanha
FROM base
UNION ALL
SELECT grupo, 4, 'EVIDENCIA_EXTRAPOLADA',
       'Taxa observada do telefone do Golden Record entre CPFs em que ele ja foi acionado.',
       candidatos, taxa_historica, candidatos * taxa_historica
FROM base
UNION ALL
SELECT grupo, 5, 'PISO_OBSERVADO',
       'Apenas candidatos cujo telefone do Golden Record ja foi acionado e entregou. Sem extrapolacao.',
       candidatos_com_historico,
       candidatos_com_entrega_provada / nullif(candidatos_com_historico, 0),
       CAST(candidatos_com_entrega_provada AS DOUBLE)
FROM base
;

CREATE OR REPLACE TEMP VIEW vt_res_08_perdas AS
WITH base AS (
  SELECT
    grupo,
    count(*)                                                                        AS sucessos_em_risco,
    max(taxa_concordante_global)                                                    AS taxa_global,
    sum(1 - taxa_calibracao_campanha)                                               AS perda_campanha,
    avg(CASE WHEN evidencia_direta <> 'GR_NUNCA_ACIONADO' THEN gr_taxa_entrega END) AS taxa_historica,
    sum(CASE WHEN evidencia_direta = 'GR_ACIONADO_SEM_ENTREGA' THEN 1 ELSE 0 END)   AS perda_comprovada
  FROM vt_envios_gr_diferente
  WHERE entregue = 1
  GROUP BY grupo
)
SELECT grupo, 1 AS ordem, sucessos_em_risco, CAST(0.0 AS DOUBLE) AS taxa_perda,
       CAST(0.0 AS DOUBLE) AS entregas_perdidas
FROM base
UNION ALL
SELECT grupo, 2, sucessos_em_risco, 1 - taxa_global, sucessos_em_risco * (1 - taxa_global)
FROM base
UNION ALL
SELECT grupo, 3, sucessos_em_risco, perda_campanha / nullif(sucessos_em_risco, 0), perda_campanha
FROM base
UNION ALL
SELECT grupo, 4, sucessos_em_risco, 1 - taxa_historica, sucessos_em_risco * (1 - taxa_historica)
FROM base
UNION ALL
SELECT grupo, 5, sucessos_em_risco,
       perda_comprovada / nullif(sucessos_em_risco, 0), CAST(perda_comprovada AS DOUBLE)
FROM base
;


/* -----------------------------------------------------------------------------
   08.5  SALDO LÍQUIDO POR CENÁRIO

   entregas_liquidas é recuperações menos perdas. É o insumo direto do cálculo
   de receita incremental na seção 09.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_08_saldo AS
SELECT
  g.grupo,
  g.ordem,
  g.cenario,
  g.premissa,
  g.candidatos                                            AS insucessos_candidatos,
  round(100.0 * g.taxa_aplicada, 4)                       AS taxa_aplicada_pct,
  round(g.entregas_recuperadas, 0)                        AS entregas_recuperadas,
  p.sucessos_em_risco,
  round(p.entregas_perdidas, 0)                           AS entregas_perdidas,
  round(g.entregas_recuperadas - p.entregas_perdidas, 0)  AS entregas_liquidas,
  round(100.0 * (g.entregas_recuperadas - p.entregas_perdidas)
        / nullif(v.envios_no_grupo, 0), 4)                AS pp_incremental,
  v.envios_no_grupo
FROM vt_res_08_ganhos g
JOIN vt_res_08_perdas p ON g.grupo = p.grupo AND g.ordem = p.ordem
JOIN (SELECT grupo, count(*) AS envios_no_grupo FROM vt_experimento GROUP BY grupo) v
  ON g.grupo = v.grupo
;
SELECT * FROM vt_res_08_saldo ORDER BY grupo, ordem;


/* -----------------------------------------------------------------------------
   08.6  CLIENTES SEM NENHUMA ENTREGA

   Visão por CPF, para valorar recuperação de contato e não apenas volume de
   disparo. Um CPF é considerado inalcançável quando nenhum envio, em nenhum
   telefone, foi entregue.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_08_cpfs_recuperaveis AS
WITH status_cpf AS (
  SELECT
    grupo,
    cpf,
    max(entregue)                                                                        AS alguma_entrega,
    max(CASE WHEN entregue = 0 AND classe_concordancia = 'DIFERENTE' THEN 1 ELSE 0 END)  AS tem_insucesso_divergente,
    max(CASE WHEN concordante = 1 THEN 1 ELSE 0 END)                                     AS gr_acionado,
    max(CASE WHEN concordante = 1 THEN entregue ELSE 0 END)                              AS gr_entregou
  FROM vt_experimento
  GROUP BY grupo, cpf
)
SELECT
  grupo,
  count(*)                                                                          AS cpfs_com_gr,
  sum(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END)                               AS cpfs_sem_nenhuma_entrega,
  round(100.0 * avg(CASE WHEN alguma_entrega = 0 THEN 1 ELSE 0 END), 4)             AS pct_sem_entrega,
  sum(CASE WHEN alguma_entrega = 0 AND tem_insucesso_divergente = 1 AND gr_acionado = 0
           THEN 1 ELSE 0 END)                                                       AS com_telefone_gr_nao_testado,
  sum(CASE WHEN alguma_entrega = 0 AND tem_insucesso_divergente = 1 AND gr_acionado = 1
           THEN 1 ELSE 0 END)                                                       AS com_telefone_gr_ja_falhou,
  sum(CASE WHEN alguma_entrega = 1 AND tem_insucesso_divergente = 1 AND gr_entregou = 1
           THEN 1 ELSE 0 END)                                                       AS com_telefone_gr_provado
FROM status_cpf
GROUP BY grupo
;
SELECT * FROM vt_res_08_cpfs_recuperaveis ORDER BY grupo;


/* =============================================================================
   SEÇÃO 09  CALCULADORA DE VALUATION
   =============================================================================
   Traduz os resultados estatísticos em valor financeiro, usando três variáveis
   declaradas na seção 00: custo por disparo, taxa de conversão sobre entregas e
   retorno médio por conversão.

   AS DUAS CAMADAS DE VALOR, E POR QUE ELAS NÃO SE SOMAM POR ENGANO
   A primeira camada é a economia de mídia obtida ao acertar o telefone mais
   cedo. Ela vem da simulação de sequência da seção 07, é integralmente
   observada e representa disparos que simplesmente deixariam de existir. É
   dinheiro que não sai do caixa.
   A segunda camada é a receita adicional gerada por entregas que hoje não
   acontecem. Ela vem do contrafactual da seção 08 e depende do cenário
   escolhido. É dinheiro que entra no caixa.
   As duas camadas medem coisas diferentes e por isso são somadas no valor
   total. Já a mídia requalificada, que é o custo de disparo hoje desperdiçado
   em insucessos que passariam a ser entregues, aparece como indicador de
   qualidade de investimento e não entra no total, para evitar dupla contagem
   com a receita incremental.

   [JÚNIOR]    Cada entrega a mais vale a taxa de conversão multiplicada pelo
               retorno de uma conversão. Cada disparo poupado vale o custo do
               SMS. Somando os dois, chega-se ao valor do Golden Record.
   [SÊNIOR]    A calculadora é paramétrica em três eixos e oferece uma grade de
               sensibilidade sobre taxa de conversão e ticket, para expor a
               superfície de valor em vez de um ponto único.
   [EXECUTIVO] A tabela 09.4 traz o valor consolidado por cenário. A tabela 09.5
               mostra como esse valor se comporta quando as premissas comerciais
               mudam para metade ou para o dobro.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   09.1  RETRATO FINANCEIRO DA OPERAÇÃO ATUAL

   Fotografia do que já é gasto e do que já é gerado, sem nenhuma intervenção.
   Serve de denominador para todos os ganhos calculados adiante.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_base_atual AS
SELECT
  b.grupo,
  count(*)                                                        AS disparos,
  sum(b.entregue)                                                 AS entregas,
  count(*) - sum(b.entregue)                                      AS insucessos,
  round(100.0 * avg(b.entregue), 4)                               AS taxa_entrega_pct,
  round(count(*) * max(gp.custo_sms), 2)                          AS custo_total_disparos,
  round((count(*) - sum(b.entregue)) * max(gp.custo_sms), 2)      AS custo_em_insucesso,
  round(100.0 * (count(*) - sum(b.entregue)) / nullif(count(*), 0), 4) AS pct_custo_desperdicado,
  round(sum(b.entregue) * max(gp.taxa_conversao), 2)              AS conversoes_estimadas,
  round(sum(b.entregue) * max(gp.taxa_conversao) * max(gp.valor_conversao), 2) AS receita_estimada,
  max(gp.custo_sms)                                               AS custo_sms_aplicado,
  max(gp.taxa_conversao)                                          AS taxa_conversao_aplicada,
  max(gp.valor_conversao)                                         AS valor_conversao_aplicado
FROM vt_base_grupo b
JOIN vt_grupo_param gp ON b.grupo = gp.grupo
GROUP BY b.grupo
;
SELECT * FROM vt_res_09_base_atual ORDER BY grupo;


/* -----------------------------------------------------------------------------
   09.2  CAMADA DE ECONOMIA DE MÍDIA

   Valor dos disparos que deixariam de ser feitos ao acertar o telefone mais
   cedo, medido no conjunto controlado da seção 07 e projetado para o volume
   total do grupo pela proporção de disparos observados.

   economia_projetada aplica a taxa de redução observada ao volume completo,
   assumindo que os pares não observados se comportam como os observados. Essa
   projeção é declarada e pode ser desprezada em favor da economia observada.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_economia_midia AS
SELECT
  s.grupo,
  s.pares_avaliados,
  s.economia_disparos                                                    AS economia_observada_disparos,
  round(s.economia_disparos * gp.custo_sms, 2)                           AS economia_observada_reais,
  a.pct_disparos_observados,
  round(s.economia_disparos / nullif(a.pct_disparos_observados / 100.0, 0), 0) AS economia_projetada_disparos,
  round(s.economia_disparos / nullif(a.pct_disparos_observados / 100.0, 0)
        * gp.custo_sms, 2)                                               AS economia_projetada_reais,
  s.pct_reducao_disparos,
  s.pares_com_perda_de_cobertura,
  s.pct_perda_de_cobertura
FROM vt_res_07_sequencia s
JOIN vt_res_07_abrangencia a ON s.grupo = a.grupo
JOIN vt_grupo_param gp       ON s.grupo = gp.grupo
;
SELECT * FROM vt_res_09_economia_midia ORDER BY grupo;


/* -----------------------------------------------------------------------------
   09.3  CAMADA DE RECEITA INCREMENTAL

   Converte entregas líquidas em conversões e conversões em receita, cenário a
   cenário.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_receita AS
SELECT
  s.grupo,
  s.ordem,
  s.cenario,
  s.entregas_liquidas,
  gp.taxa_conversao,
  gp.valor_conversao,
  gp.custo_sms,
  round(s.entregas_liquidas * gp.taxa_conversao, 2)                          AS conversoes_incrementais,
  round(s.entregas_liquidas * gp.taxa_conversao * gp.valor_conversao, 2)     AS receita_incremental,
  round(s.entregas_liquidas * gp.custo_sms, 2)                               AS midia_requalificada
FROM vt_res_08_saldo s
JOIN vt_grupo_param gp ON s.grupo = gp.grupo
;
SELECT * FROM vt_res_09_receita ORDER BY grupo, ordem;


/* -----------------------------------------------------------------------------
   09.4  VALOR CONSOLIDADO POR CENÁRIO

   valor_total soma a economia de mídia da camada observada com a receita
   incremental da camada estimada. retorno_sobre_custo compara esse valor com o
   custo total de disparo da operação atual.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_valuation AS
SELECT
  r.grupo,
  r.ordem,
  r.cenario,
  r.entregas_liquidas,
  r.conversoes_incrementais,
  r.receita_incremental,
  e.economia_observada_reais,
  round(r.receita_incremental + e.economia_observada_reais, 2)         AS valor_total,
  r.midia_requalificada,
  b.custo_total_disparos,
  round(100.0 * (r.receita_incremental + e.economia_observada_reais)
        / nullif(b.custo_total_disparos, 0), 4)                        AS valor_sobre_custo_pct,
  round((r.receita_incremental + e.economia_observada_reais)
        / nullif(b.disparos, 0), 6)                                    AS valor_por_disparo,
  round((r.receita_incremental + e.economia_observada_reais)
        / nullif(b.entregas, 0), 6)                                    AS valor_por_entrega_atual
FROM vt_res_09_receita r
JOIN vt_res_09_economia_midia e ON r.grupo = e.grupo
JOIN vt_res_09_base_atual b     ON r.grupo = b.grupo
;
SELECT * FROM vt_res_09_valuation ORDER BY grupo, ordem;


/* -----------------------------------------------------------------------------
   09.5  GRADE DE SENSIBILIDADE

   Recalcula o valor variando taxa de conversão e retorno por conversão em
   metade, base e dobro. Nove combinações por cenário e por grupo. A célula em
   que os dois multiplicadores valem um reproduz a tabela 09.4.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_sensibilidade AS
SELECT
  r.grupo,
  r.ordem,
  r.cenario,
  s.rotulo_taxa,
  s.rotulo_valor,
  round(r.taxa_conversao * s.mult_taxa_conversao, 6)                 AS taxa_conversao_aplicada,
  round(r.valor_conversao * s.mult_valor_conversao, 2)               AS valor_conversao_aplicado,
  r.entregas_liquidas,
  round(r.entregas_liquidas * r.taxa_conversao * s.mult_taxa_conversao, 2) AS conversoes_incrementais,
  round(r.entregas_liquidas * r.taxa_conversao * s.mult_taxa_conversao
        * r.valor_conversao * s.mult_valor_conversao, 2)             AS receita_incremental,
  e.economia_observada_reais,
  round(r.entregas_liquidas * r.taxa_conversao * s.mult_taxa_conversao
        * r.valor_conversao * s.mult_valor_conversao
        + e.economia_observada_reais, 2)                             AS valor_total
FROM vt_res_09_receita r
CROSS JOIN vt_param_sensibilidade s
JOIN vt_res_09_economia_midia e ON r.grupo = e.grupo
;
SELECT * FROM vt_res_09_sensibilidade
WHERE cenario = 'CALIBRADO_CAMPANHA'
ORDER BY grupo, rotulo_taxa, rotulo_valor;


/* -----------------------------------------------------------------------------
   09.6  VALUATION POR CAMPANHA

   Abre o cenário calibrado por campanha em uma linha por campanha, para
   priorizar onde a adoção do Golden Record rende mais.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_09_por_campanha AS
WITH d AS (
  SELECT
    grupo,
    campanha,
    sum(CASE WHEN entregue = 0 THEN 1 ELSE 0 END)                   AS insucessos_divergentes,
    sum(CASE WHEN entregue = 1 THEN 1 ELSE 0 END)                   AS sucessos_em_risco,
    max(taxa_calibracao_campanha)                                   AS taxa_calibracao,
    sum(CASE WHEN entregue = 0 AND evidencia_direta = 'GR_ACIONADO_E_ENTREGOU'
             THEN 1 ELSE 0 END)                                     AS recuperacao_comprovada
  FROM vt_envios_gr_diferente
  GROUP BY grupo, campanha
)
SELECT
  v.grupo,
  v.campanha,
  v.faixa_volume,
  v.n_envios,
  round(100.0 * v.taxa_entrega, 4)                                        AS taxa_entrega_pct,
  v.n_envios - v.n_entregues                                              AS insucessos,
  coalesce(d.insucessos_divergentes, 0)                                   AS insucessos_divergentes,
  round(100.0 * d.taxa_calibracao, 4)                                     AS taxa_calibracao_pct,
  round(coalesce(d.insucessos_divergentes, 0) * d.taxa_calibracao, 1)     AS recuperadas,
  round(coalesce(d.sucessos_em_risco, 0) * (1 - d.taxa_calibracao), 1)    AS perdidas,
  round(coalesce(d.insucessos_divergentes, 0) * d.taxa_calibracao
        - coalesce(d.sucessos_em_risco, 0) * (1 - d.taxa_calibracao), 1)  AS entregas_liquidas,
  coalesce(d.recuperacao_comprovada, 0)                                   AS recuperacao_comprovada,
  round((coalesce(d.insucessos_divergentes, 0) * d.taxa_calibracao
         - coalesce(d.sucessos_em_risco, 0) * (1 - d.taxa_calibracao))
        * gp.taxa_conversao * gp.valor_conversao, 2)                      AS receita_incremental,
  round(v.n_envios * gp.custo_sms, 2)                                     AS custo_disparos_campanha
FROM vt_campanha_volume v
LEFT JOIN d            ON v.grupo = d.grupo AND v.campanha = d.campanha
JOIN vt_grupo_param gp ON v.grupo = gp.grupo
;
SELECT * FROM vt_res_09_por_campanha ORDER BY grupo, receita_incremental DESC NULLS LAST;


/* =============================================================================
   SEÇÃO 10  TESTES DE ROBUSTEZ
   =============================================================================
   Verifica se o efeito medido nas seções 05 e 07 depende de uma campanha
   específica, de uma regra de comparação ou de um perfil de cliente.

   [JÚNIOR]    A tabela por campanha funciona como um placar. O teste do sinal
               conta em quantas campanhas o Golden Record venceu. Os demais
               recortes repetem a comparação em fatias diferentes da base.
   [SÊNIOR]    O teste do sinal é um binomial sobre a direção do efeito por
               campanha, restrito a campanhas com volume mínimo em ambos os
               braços. Como cada campanha vale um voto, ele complementa o
               estimador estratificado, que pondera por volume.
   [EXECUTIVO] A pergunta é se o resultado se repete em toda parte. Percentual
               alto de campanhas vencidas e mesmo sinal em todos os recortes
               significa que sim.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   10.1  PLACAR POR CAMPANHA

   Campanhas abaixo do volume mínimo por braço permanecem no estimador
   estratificado da seção 05 e saem apenas desta tabela, onde um p-valor
   individual seria ruído.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_por_campanha AS
WITH s AS (
  SELECT e.*, e.a + e.b AS n1, e.c + e.d AS n0
  FROM vt_estratos_campanha e
  CROSS JOIN vt_param p
  WHERE e.a + e.b >= p.min_envios_braco
    AND e.c + e.d >= p.min_envios_braco
),
calc AS (
  SELECT *,
    a / nullif(n1, 0)            AS p1,
    c / nullif(n0, 0)            AS p0,
    (a + c) / nullif(n1 + n0, 0) AS p_pool
  FROM s
),
z AS (
  SELECT *,
    CASE WHEN p_pool NOT IN (0, 1)
         THEN (p1 - p0) / sqrt(p_pool * (1 - p_pool)
                               * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))) END AS z_score
  FROM calc
)
SELECT
  z.grupo,
  z.campanha,
  v.faixa_volume,
  CAST(z.n1 AS BIGINT)                   AS envios_concordante,
  round(100.0 * z.p1, 4)                 AS taxa_concordante_pct,
  CAST(z.n0 AS BIGINT)                   AS envios_discordante,
  round(100.0 * z.p0, 4)                 AS taxa_discordante_pct,
  round(100.0 * (z.p1 - z.p0), 4)        AS diferenca_pp,
  round(z.z_score, 3)                    AS z,
  p_valor_bilateral(z.z_score)           AS p_valor,
  CASE WHEN z.p1 > z.p0 THEN 'GOLDEN_RECORD'
       WHEN z.p1 < z.p0 THEN 'CRM'
       ELSE 'EMPATE' END                 AS vencedor,
  CASE WHEN p_valor_bilateral(z.z_score) < 0.05 THEN 'SIGNIFICANTE'
       ELSE 'NAO_SIGNIFICANTE' END       AS significancia
FROM z
JOIN vt_campanha_volume v
  ON z.grupo = v.grupo AND z.campanha = v.campanha
;
SELECT * FROM vt_res_10_por_campanha ORDER BY grupo, envios_concordante + envios_discordante DESC;


/* -----------------------------------------------------------------------------
   10.2  TESTE DO SINAL ENTRE CAMPANHAS

   Sob a hipótese de ausência de efeito, o Golden Record venceria metade das
   campanhas. O teste avalia o desvio dessa proporção.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_teste_sinal AS
WITH t AS (
  SELECT
    grupo,
    count(*)                                                   AS campanhas_avaliadas,
    sum(CASE WHEN vencedor = 'GOLDEN_RECORD' THEN 1 ELSE 0 END) AS vitorias,
    sum(CASE WHEN vencedor = 'CRM' THEN 1 ELSE 0 END)           AS derrotas,
    sum(CASE WHEN vencedor = 'EMPATE' THEN 1 ELSE 0 END)        AS empates,
    sum(CASE WHEN vencedor = 'GOLDEN_RECORD' AND significancia = 'SIGNIFICANTE'
             THEN 1 ELSE 0 END)                                 AS vitorias_significantes,
    sum(CASE WHEN vencedor = 'CRM' AND significancia = 'SIGNIFICANTE'
             THEN 1 ELSE 0 END)                                 AS derrotas_significantes
  FROM vt_res_10_por_campanha
  GROUP BY grupo
),
z AS (
  SELECT *,
    vitorias + derrotas AS decididas,
    CASE WHEN vitorias + derrotas > 0
         THEN (vitorias - (vitorias + derrotas) / 2.0)
              / sqrt((vitorias + derrotas) / 4.0) END AS z_score
  FROM t
)
SELECT
  grupo,
  campanhas_avaliadas,
  vitorias,
  derrotas,
  empates,
  round(100.0 * vitorias / nullif(decididas, 0), 4) AS pct_vitorias,
  vitorias_significantes,
  derrotas_significantes,
  round(z_score, 3)                                 AS z,
  p_valor_bilateral(z_score)                        AS p_valor,
  CASE
    WHEN p_valor_bilateral(z_score) < 0.05 AND vitorias > derrotas
      THEN 'O Golden Record vence na maioria das campanhas, alem do acaso.'
    WHEN p_valor_bilateral(z_score) < 0.05
      THEN 'O cadastro do CRM vence na maioria das campanhas.'
    ELSE 'Vitorias e derrotas equilibradas entre campanhas.'
  END                                               AS leitura
FROM z
;
SELECT * FROM vt_res_10_teste_sinal ORDER BY grupo;


/* -----------------------------------------------------------------------------
   10.3  EFEITO POR PORTE DE CAMPANHA
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_por_faixa AS
WITH agg AS (
  SELECT
    e.grupo,
    v.faixa_volume,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)         AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END) AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)         AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END) AS k0
  FROM vt_experimento e
  JOIN vt_campanha_volume v ON e.grupo = v.grupo AND e.campanha = v.campanha
  GROUP BY e.grupo, v.faixa_volume
),
calc AS (
  SELECT *,
    k1 / nullif(n1, 0)             AS p1,
    k0 / nullif(n0, 0)             AS p0,
    (k1 + k0) / nullif(n1 + n0, 0) AS p_pool
  FROM agg
)
SELECT
  grupo,
  faixa_volume,
  n1                              AS envios_concordante,
  round(100.0 * p1, 4)            AS taxa_concordante_pct,
  n0                              AS envios_discordante,
  round(100.0 * p0, 4)            AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4)     AS diferenca_pp,
  round((p1 - p0) / sqrt(p_pool * (1 - p_pool)
        * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))), 3) AS z,
  p_valor_bilateral((p1 - p0) / sqrt(p_pool * (1 - p_pool)
        * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0))))    AS p_valor
FROM calc
;
SELECT * FROM vt_res_10_por_faixa ORDER BY grupo, faixa_volume;


/* -----------------------------------------------------------------------------
   10.4  EFEITO SEM A MAIOR CAMPANHA
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_sem_maior AS
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
),
calc AS (
  SELECT *,
    k1 / nullif(n1, 0)             AS p1,
    k0 / nullif(n0, 0)             AS p0,
    (k1 + k0) / nullif(n1 + n0, 0) AS p_pool
  FROM agg
)
SELECT
  grupo,
  campanha_excluida,
  n1                          AS envios_concordante,
  round(100.0 * p1, 4)        AS taxa_concordante_pct,
  n0                          AS envios_discordante,
  round(100.0 * p0, 4)        AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  p_valor_bilateral((p1 - p0) / sqrt(p_pool * (1 - p_pool)
        * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))) AS p_valor
FROM calc
;
SELECT * FROM vt_res_10_sem_maior ORDER BY grupo;


/* -----------------------------------------------------------------------------
   10.5  EFEITO COM REGRA EXATA DE CONCORDÂNCIA

   Repete a comparação exigindo igualdade caractere por caractere. Resultado
   próximo ao da regra tolerante indica que a conclusão não é artefato de
   formatação de número.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_regra_exata AS
WITH agg AS (
  SELECT
    grupo,
    sum(CASE WHEN concordante_exato = 1 THEN 1 ELSE 0 END)        AS n1,
    sum(CASE WHEN concordante_exato = 1 THEN entregue ELSE 0 END) AS k1,
    sum(CASE WHEN concordante_exato = 0 THEN 1 ELSE 0 END)        AS n0,
    sum(CASE WHEN concordante_exato = 0 THEN entregue ELSE 0 END) AS k0
  FROM vt_experimento
  GROUP BY grupo
),
calc AS (
  SELECT *,
    k1 / nullif(n1, 0)             AS p1,
    k0 / nullif(n0, 0)             AS p0,
    (k1 + k0) / nullif(n1 + n0, 0) AS p_pool
  FROM agg
)
SELECT
  grupo,
  'EXATA' AS regra,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  p_valor_bilateral((p1 - p0) / sqrt(p_pool * (1 - p_pool)
        * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))) AS p_valor
FROM calc
UNION ALL
SELECT
  grupo, 'TOLERANTE',
  envios_concordante, taxa_concordante_pct,
  envios_discordante, taxa_discordante_pct,
  diferenca_pp, p_valor
FROM vt_res_05_bruto
;
SELECT * FROM vt_res_10_regra_exata ORDER BY grupo, regra;


/* -----------------------------------------------------------------------------
   10.6  EFEITO POR INTENSIDADE DE CONTATO

   Recorte por número de envios recebidos pelo CPF, usado como aproximação de
   engajamento. Consistência entre as faixas afasta a hipótese de que a
   concordância de telefone apenas identifica clientes mais ativos.
----------------------------------------------------------------------------- */
CREATE OR REPLACE TEMP VIEW vt_res_10_por_intensidade AS
WITH freq AS (
  SELECT grupo, cpf, count(*) AS envios_cpf
  FROM vt_experimento GROUP BY grupo, cpf
),
agg AS (
  SELECT
    e.grupo,
    CASE WHEN f.envios_cpf = 1  THEN '1. um envio'
         WHEN f.envios_cpf <= 3 THEN '2. dois a tres'
         WHEN f.envios_cpf <= 10 THEN '3. quatro a dez'
         ELSE '4. acima de dez' END                              AS faixa_intensidade,
    sum(CASE WHEN e.concordante = 1 THEN 1 ELSE 0 END)           AS n1,
    sum(CASE WHEN e.concordante = 1 THEN e.entregue ELSE 0 END)  AS k1,
    sum(CASE WHEN e.concordante = 0 THEN 1 ELSE 0 END)           AS n0,
    sum(CASE WHEN e.concordante = 0 THEN e.entregue ELSE 0 END)  AS k0
  FROM vt_experimento e
  JOIN freq f ON e.grupo = f.grupo AND e.cpf = f.cpf
  GROUP BY e.grupo,
    CASE WHEN f.envios_cpf = 1  THEN '1. um envio'
         WHEN f.envios_cpf <= 3 THEN '2. dois a tres'
         WHEN f.envios_cpf <= 10 THEN '3. quatro a dez'
         ELSE '4. acima de dez' END
),
calc AS (
  SELECT *,
    k1 / nullif(n1, 0)             AS p1,
    k0 / nullif(n0, 0)             AS p0,
    (k1 + k0) / nullif(n1 + n0, 0) AS p_pool
  FROM agg
)
SELECT
  grupo,
  faixa_intensidade,
  n1 AS envios_concordante, round(100.0 * p1, 4) AS taxa_concordante_pct,
  n0 AS envios_discordante, round(100.0 * p0, 4) AS taxa_discordante_pct,
  round(100.0 * (p1 - p0), 4) AS diferenca_pp,
  p_valor_bilateral((p1 - p0) / sqrt(p_pool * (1 - p_pool)
        * (1.0 / nullif(n1, 0) + 1.0 / nullif(n0, 0)))) AS p_valor
FROM calc
;
SELECT * FROM vt_res_10_por_intensidade ORDER BY grupo, faixa_intensidade;


/* =============================================================================
   SEÇÃO 11  RESUMO EXECUTIVO
   =============================================================================
   Reúne em uma tabela única os números que sustentam a decisão, na ordem em que
   devem ser apresentados. Cada linha traz o indicador, o valor, uma explicação
   do que ele significa, um exemplo numérico concreto e a orientação de uso.

   Blocos:
     A  Oportunidade, quanto o Golden Record alcança
     B  Qualidade do ranking, se a ordenação separa telefone bom de ruim
     C  Evidência causal, se o telefone certo entrega mais
     D  Reordenação, o que muda ao acionar na ordem do Golden Record
     E  Robustez, se o resultado se repete
     F  Valuation, quanto isso vale em reais

   Os exemplos usam uma campanha de referência de um milhão de disparos, para
   tornar cada percentual tangível.
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_11_resumo AS

/* Bloco A, oportunidade */
SELECT
  grupo, 'A. Oportunidade' AS bloco, 1 AS ordem,
  'Disparos analisados' AS indicador,
  CAST(total AS DOUBLE) AS valor, 'envios' AS unidade,
  'Volume de SMS que passou pelos filtros de qualidade e entrou no estudo.' AS o_que_significa,
  concat('Equivale a ', format_number(total / 1000000.0, 2), ' campanhas de um milhao de disparos.') AS exemplo,
  'Denominador de todas as taxas apresentadas adiante.' AS como_usar,
  'vt_res_03_cobertura' AS origem
FROM vt_res_03_cobertura WHERE grao = 'ENVIO'
UNION ALL
SELECT
  grupo, 'A. Oportunidade', 2,
  'Cobertura do Golden Record sobre disparos',
  pct_com_gr, '%',
  'Percentual dos disparos cujo CPF possui telefone cadastrado no Golden Record.',
  concat('Em uma campanha de um milhao de disparos, cerca de ',
         format_number(pct_com_gr * 10000, 0), ' teriam telefone comparavel.'),
  'Define o teto de alcance de qualquer iniciativa baseada no Golden Record.',
  'vt_res_03_cobertura'
FROM vt_res_03_cobertura WHERE grao = 'ENVIO'
UNION ALL
SELECT
  grupo, 'A. Oportunidade', 3,
  'Cobertura do Golden Record sobre clientes',
  pct_com_gr, '%',
  'Percentual dos CPFs acionados que possuem telefone no Golden Record.',
  concat('Em uma base de cem mil clientes acionados, cerca de ',
         format_number(pct_com_gr * 1000, 0), ' teriam telefone no Golden Record.'),
  'Compare com a cobertura por disparo. Se for menor, os clientes cobertos sao os mais acionados.',
  'vt_res_03_cobertura'
FROM vt_res_03_cobertura WHERE grao = 'CPF'
UNION ALL
SELECT
  grupo, 'A. Oportunidade', 4,
  'Disparos em que o Golden Record indicaria outro numero',
  pct_envios, '%',
  'Espaco em que a adocao do Golden Record efetivamente muda o numero acionado.',
  concat('Em uma campanha de um milhao de disparos, ',
         format_number(pct_envios * 10000, 0), ' trocariam de numero.'),
  'Volume sujeito a intervencao. Fora dele, o Golden Record confirma o que ja e feito.',
  'vt_res_03_concordancia'
FROM vt_res_03_concordancia WHERE classe_concordancia = 'DIFERENTE'
UNION ALL
SELECT
  grupo, 'A. Oportunidade', 5,
  'Insucessos em que o Golden Record indicaria outro numero',
  pct_sobre_com_gr, '%',
  'Dos SMS nao entregues com cobertura do Golden Record, fracao que teria ido para outro numero.',
  concat('A cada mil SMS que falharam, cerca de ',
         format_number(pct_sobre_com_gr * 10, 0), ' teriam sido enviados para outro telefone.'),
  'Tamanho bruto da oportunidade de recuperacao, antes de qualquer ajuste.',
  'vt_res_08_anatomia'
FROM vt_res_08_anatomia WHERE grao = 'ENVIO'

/* Bloco B, qualidade do ranking */
UNION ALL
SELECT
  grupo, 'B. Qualidade do ranking', 10,
  'Entrega no telefone de ranking 1',
  taxa_entrega_pct, '%',
  'Taxa de entrega observada quando o numero acionado ocupa a primeira posicao do Golden Record.',
  concat('De cada cem disparos para o telefone de ranking 1, cerca de ',
         format_number(taxa_entrega_pct, 0), ' chegam ao destino.'),
  'Referencia de desempenho do melhor telefone disponivel por cliente.',
  'vt_res_04_entrega_por_ranking'
FROM vt_res_04_entrega_por_ranking WHERE posicao_no_gr = 'RANKING_1'
UNION ALL
SELECT
  grupo, 'B. Qualidade do ranking', 11,
  'Entrega em numero ausente do Golden Record',
  taxa_entrega_pct, '%',
  'Taxa de entrega quando o numero acionado nao consta em nenhuma posicao do ranking.',
  concat('De cada cem disparos para numero fora do Golden Record, cerca de ',
         format_number(taxa_entrega_pct, 0), ' chegam ao destino.'),
  'Contraste com a linha anterior. A distancia entre as duas mede o poder do cadastro.',
  'vt_res_04_entrega_por_ranking'
FROM vt_res_04_entrega_por_ranking WHERE posicao_no_gr = 'FORA_DO_GR'
UNION ALL
SELECT
  grupo, 'B. Qualidade do ranking', 12,
  'Vantagem do ranking 1 sobre o ranking 2',
  diferenca_pp, 'p.p.',
  'Diferenca de entrega entre a primeira e a segunda posicao do Golden Record.',
  concat('Em um milhao de disparos, priorizar a primeira posicao no lugar da segunda produz cerca de ',
         format_number(diferenca_pp * 10000, 0), ' entregas adicionais.'),
  'Valor positivo confirma que a ordenacao do cadastro carrega informacao real.',
  'vt_res_04_monotonicidade'
FROM vt_res_04_monotonicidade WHERE posicao_melhor = 'RANKING_1'

/* Bloco C, evidencia causal */
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 20,
  'Entrega com telefone igual ao Golden Record',
  taxa_concordante_pct, '%',
  'Taxa de entrega dos disparos que coincidiram com o telefone de ranking 1.',
  concat('Intervalo de confianca de 95 por cento entre ',
         format_number(ic95_inf_concordante, 2), ' e ', format_number(ic95_sup_concordante, 2), ' por cento.'),
  'Braco tratado do experimento natural.',
  'vt_res_05_bruto'
FROM vt_res_05_bruto
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 21,
  'Entrega com telefone diferente do Golden Record',
  taxa_discordante_pct, '%',
  'Taxa de entrega dos disparos que usaram outro numero.',
  concat('Intervalo de confianca de 95 por cento entre ',
         format_number(ic95_inf_discordante, 2), ' e ', format_number(ic95_sup_discordante, 2), ' por cento.'),
  'Braco de comparacao do experimento natural.',
  'vt_res_05_bruto'
FROM vt_res_05_bruto
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 22,
  'Diferenca bruta entre os dois bracos',
  diferenca_pp, 'p.p.',
  'Diferenca simples de entrega, sem nenhum controle estatistico.',
  concat('Em um milhao de disparos representa cerca de ',
         format_number(diferenca_pp * 10000, 0), ' entregas a mais. P-valor de ',
         format_number(p_valor, 6), '.'),
  'Ponto de partida. Ainda sujeito a diferencas de composicao entre os grupos.',
  'vt_res_05_bruto'
FROM vt_res_05_bruto
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 23,
  'Diferenca controlada por campanha',
  diferenca_pp_estratificada, 'p.p.',
  'Mesma comparacao feita dentro de cada campanha e depois combinada, ponderando pelo tamanho.',
  concat('Razao de chances de ', format_number(odds_ratio, 3),
         ', intervalo de 95 por cento entre ', format_number(odds_ratio_ic95_inf, 3),
         ' e ', format_number(odds_ratio_ic95_sup, 3),
         ', sobre ', format_number(campanhas_no_teste, 0), ' campanhas.'),
  'Estimativa principal do estudo. E o numero a levar para discussao executiva.',
  'vt_res_05_estratificado'
FROM vt_res_05_estratificado
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 24,
  'Diferenca no mesmo cliente',
  diferenca_pp, 'p.p.',
  'Comparacao do mesmo CPF consigo mesmo, com o telefone do Golden Record e com outro numero.',
  concat('Em ', format_number(n_pares, 0), ' clientes comparados, o telefone do Golden Record entregou sozinho em ',
         format_number(so_golden_record_entregou, 0), ' casos contra ',
         format_number(so_outro_telefone_entregou, 0), ' do outro numero.'),
  'Elimina qualquer caracteristica fixa do cliente como explicacao alternativa.',
  'vt_res_06_pareado'
FROM vt_res_06_pareado
UNION ALL
SELECT
  grupo, 'C. Evidencia causal', 25,
  'Diferenca no mesmo cliente e na mesma campanha',
  diferenca_pp, 'p.p.',
  'Versao mais restritiva, com pessoa e campanha fixas e apenas o telefone variando.',
  concat('Baseada em ', format_number(n_pares, 0), ' pares de disparo.'),
  'Desenho mais proximo de um teste controlado que a base observacional permite.',
  'vt_res_06_pareado_mesma_campanha'
FROM vt_res_06_pareado_mesma_campanha

/* Bloco D, reordenacao */
UNION ALL
SELECT
  grupo, 'D. Reordenacao', 30,
  'Disparos em que a ordem do Golden Record trocaria o numero',
  100.0 - pct_plano_confirma, '%',
  'Fracao dos primeiros acionamentos em que o plano do Golden Record usaria outro telefone.',
  concat('Em um milhao de primeiros disparos, cerca de ',
         format_number((100.0 - pct_plano_confirma) * 10000, 0), ' mudariam de numero.'),
  'Dimensiona o impacto operacional da mudanca de ordem no primeiro contato.',
  'vt_res_07_por_posicao'
FROM vt_res_07_por_posicao WHERE posicao_disparo = '1'
UNION ALL
SELECT
  grupo, 'D. Reordenacao', 31,
  'Vantagem do plano do Golden Record por posicao',
  diferenca_pp, 'p.p.',
  'Comparacao pareada entre o telefone que o plano usaria e o que foi de fato usado, restrita a casos com desfecho conhecido.',
  concat('Em ', format_number(n_comparacoes, 0), ' comparacoes com desfecho observado, o telefone do plano entregou sozinho em ',
         format_number(so_plano_entregou, 0), ' casos contra ',
         format_number(so_telefone_usado_entregou, 0), ' do telefone usado.'),
  'Evidencia sem premissa, porque os dois desfechos sao fatos registrados.',
  'vt_res_07_pareado_substituicao'
FROM vt_res_07_pareado_substituicao
UNION ALL
SELECT
  grupo, 'D. Reordenacao', 32,
  'Reducao de disparos ate a primeira entrega',
  pct_reducao_disparos, '%',
  'Economia de acionamentos obtida ao alcancar o telefone certo em posicao mais adiantada.',
  concat('No conjunto observado foram ', format_number(economia_disparos, 0),
         ' disparos poupados em ', format_number(pares_avaliados, 0),
         ' pares de cliente e campanha, ou seja ',
         format_number(economia_media_disparos, 3), ' disparo por par.'),
  'Base da economia de midia calculada na secao 09.',
  'vt_res_07_sequencia'
FROM vt_res_07_sequencia
UNION ALL
SELECT
  grupo, 'D. Reordenacao', 33,
  'Perda de cobertura por truncamento do plano',
  pct_perda_de_cobertura, '%',
  'Casos em que o numero que resolveu o contato no CRM fica fora da profundidade do plano do Golden Record.',
  concat('Ocorreu em ', format_number(pares_com_perda_de_cobertura, 0), ' de ',
         format_number(pares_avaliados, 0), ' pares avaliados. Em ',
         format_number(pares_com_ganho, 0), ' pares o plano acertou antes e em ',
         format_number(pares_com_atraso, 0), ' acertou depois.'),
  'Se a perda se concentrar nas posicoes profundas, ampliar a profundidade do plano na secao 00 resolve.',
  'vt_res_07_sequencia'
FROM vt_res_07_sequencia

/* Bloco E, robustez */
UNION ALL
SELECT
  grupo, 'E. Robustez', 40,
  'Campanhas em que o Golden Record venceu',
  pct_vitorias, '%',
  'Percentual das campanhas com volume suficiente em que o telefone do Golden Record entregou mais.',
  concat(format_number(vitorias, 0), ' vitorias contra ', format_number(derrotas, 0),
         ' derrotas em ', format_number(campanhas_avaliadas, 0), ' campanhas avaliadas.'),
  'Percentual alto indica efeito generalizado, e nao concentrado em poucas campanhas.',
  'vt_res_10_teste_sinal'
FROM vt_res_10_teste_sinal
UNION ALL
SELECT
  grupo, 'E. Robustez', 41,
  'Diferenca excluindo a maior campanha',
  diferenca_pp, 'p.p.',
  'Repeticao da comparacao bruta sem a campanha de maior volume.',
  concat('Campanha removida do calculo: ', campanha_excluida, '.'),
  'Valor proximo ao da comparacao bruta afasta a hipotese de dependencia de uma unica campanha.',
  'vt_res_10_sem_maior'
FROM vt_res_10_sem_maior
UNION ALL
SELECT
  grupo, 'E. Robustez', 42,
  'Diferenca com regra exata de comparacao',
  diferenca_pp, 'p.p.',
  'Repeticao da comparacao exigindo numero identico, sem tolerancia de formatacao.',
  'Compare com a diferenca bruta da linha 22. Valores proximos indicam que a regra de comparacao nao distorce a conclusao.',
  'Controle de qualidade da definicao de concordancia.',
  'vt_res_10_regra_exata'
FROM vt_res_10_regra_exata WHERE regra = 'EXATA'
UNION ALL
SELECT
  grupo, 'E. Robustez', 43,
  'Diferenca de entrega entre clientes com e sem Golden Record',
  diferenca_pp, 'p.p.',
  'Compara a entrega dos dois grupos sem olhar qual telefone foi usado.',
  leitura,
  'Nao invalida o efeito do telefone. Delimita ate onde a conclusao pode ser estendida.',
  'vt_res_03_selecao'
FROM vt_res_03_selecao

/* Bloco F, valuation */
UNION ALL
SELECT
  grupo, 'F. Valuation', 50,
  'Custo atual em disparos que nao chegam',
  custo_em_insucesso, 'R$',
  'Valor gasto hoje com SMS que nao sao entregues.',
  concat('Sao ', format_number(insucessos, 0), ' insucessos ao custo unitario de ',
         format_number(custo_sms_aplicado, 4), ' reais, dentro de um custo total de ',
         format_number(custo_total_disparos, 2), ' reais.'),
  'Denominador da discussao de eficiencia de midia.',
  'vt_res_09_base_atual'
FROM vt_res_09_base_atual
UNION ALL
SELECT
  grupo, 'F. Valuation', 51,
  'Economia de midia pela reordenacao',
  economia_observada_reais, 'R$',
  'Valor dos disparos que deixariam de existir ao acertar o telefone mais cedo, medido sem estimativa.',
  concat('Corresponde a ', format_number(economia_observada_disparos, 0),
         ' disparos poupados no conjunto observado, que representa ',
         format_number(pct_disparos_observados, 2), ' por cento do volume.'),
  'Ganho de caixa imediato, independente de qualquer premissa de conversao.',
  'vt_res_09_economia_midia'
FROM vt_res_09_economia_midia
UNION ALL
SELECT
  grupo, 'F. Valuation', 52 + ordem,
  concat('Valor total no cenario ', cenario),
  valor_total, 'R$',
  'Receita incremental das entregas recuperadas somada a economia de midia da reordenacao.',
  concat('Entregas liquidas de ', format_number(entregas_liquidas, 0), ', gerando ',
         format_number(conversoes_incrementais, 1), ' conversoes e ',
         format_number(receita_incremental, 2), ' reais de receita, mais ',
         format_number(economia_observada_reais, 2), ' reais de economia de disparo.'),
  'Use o cenario calibrado por campanha como numero central, o teto e o piso como limites da faixa.',
  'vt_res_09_valuation'
FROM vt_res_09_valuation
UNION ALL
SELECT
  grupo, 'F. Valuation', 60,
  'Clientes sem nenhuma entrega com telefone novo disponivel',
  CAST(com_telefone_gr_nao_testado AS DOUBLE), 'CPFs',
  'Clientes que nao recebem SMS em nenhum numero e para os quais o Golden Record aponta um telefone ainda nao acionado.',
  concat('De ', format_number(cpfs_sem_nenhuma_entrega, 0),
         ' clientes sem nenhuma entrega, outros ', format_number(com_telefone_gr_ja_falhou, 0),
         ' ja tiveram o telefone do Golden Record acionado sem sucesso.'),
  'Base para valorar recuperacao de contato, e nao apenas volume de disparo.',
  'vt_res_08_cpfs_recuperaveis'
FROM vt_res_08_cpfs_recuperaveis
;

SELECT
  grupo, bloco, ordem, indicador, valor, unidade,
  o_que_significa, exemplo, como_usar, origem
FROM vt_res_11_resumo
ORDER BY grupo, ordem
;
