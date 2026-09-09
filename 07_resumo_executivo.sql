/* =============================================================================
   VALUATION TELEFONE  |  07_resumo_executivo.sql
   =============================================================================
   O QUE ESTE SCRIPT FAZ
   ---------------------
   Junta em UMA tabela os números que contam a história inteira, na ordem em
   que devem ser apresentados. Cada linha tem: bloco, indicador, valor,
   unidade e uma leitura em uma frase. É a tabela para colar no slide.

   Pré-requisito: scripts 00 a 06 já executados na mesma sessão.

   -----------------------------------------------------------------------------
   LEITURA POR NÍVEL
   -----------------------------------------------------------------------------
   [JÚNIOR]   Cada linha aponta a view de origem (coluna origem) para você
              rastrear o número até a query que o gerou.
   [SÊNIOR]   Bloco A = tamanho da oportunidade; B = evidência causal (3
              lentes); C = robustez; D = tradução para entregas recuperadas
              (o insumo do valuation). Se B e C concordarem em sinal e
              significância, D pode ser usado com o cenário CALIBRADO como
              central e TETO/PISO como faixa.
   [EXECUTIVO] Quatro perguntas, quatro blocos:
              A. Quanto do CRM o GR alcança e em quantos disparos o GR
                 discorda do telefone usado hoje?
              B. Quando o CRM usou o telefone do GR, entregou mais? (sim/não,
                 com p-valor)
              C. Isso se repete em todas as campanhas?
              D. Quantas entregas a mais teríamos usado o GR? (faixa
                 piso..teto e número central)
   ============================================================================= */

CREATE OR REPLACE TEMP VIEW vt_res_07_resumo_executivo AS

/* ---------- BLOCO A: TAMANHO DA OPORTUNIDADE ---------- */
SELECT 'A. Oportunidade' AS bloco, 1 AS ordem,
       'Envios de SMS válidos analisados' AS indicador,
       CAST(count(*) AS DOUBLE) AS valor, 'envios' AS unidade,
       'Base do CRM após limpeza de status e chaves.' AS leitura,
       'vt_base_analitica' AS origem
FROM vt_base_analitica
UNION ALL
SELECT 'A. Oportunidade', 2, 'Cobertura do GR sobre os envios',
       pct_com_gr, '%',
       'Percentual dos disparos cujo CPF tem telefone ranking 1 no GR.',
       'vt_res_02_cobertura'
FROM vt_res_02_cobertura WHERE grao = 'ENVIO'
UNION ALL
SELECT 'A. Oportunidade', 3, 'Cobertura do GR sobre os CPFs',
       pct_com_gr, '%',
       'Percentual dos clientes contatados que têm telefone ranking 1 no GR.',
       'vt_res_02_cobertura'
FROM vt_res_02_cobertura WHERE grao = 'CPF'
UNION ALL
SELECT 'A. Oportunidade', 4, 'Envios em que o GR indicaria OUTRO telefone',
       pct_envios, '%',
       'Espaço em que o GR pode mudar o resultado (universo com GR).',
       'vt_res_02_concordancia'
FROM vt_res_02_concordancia WHERE classe_concordancia = 'DIFERENTE'
UNION ALL
SELECT 'A. Oportunidade', 5, 'Insucessos em que o GR indicaria OUTRO telefone',
       pct_gr_diferente_sobre_com_gr, '%',
       'Dos SMS não entregues (com GR), quantos teriam ido para outro número.',
       'vt_res_05_anatomia_insucesso'
FROM vt_res_05_anatomia_insucesso WHERE grao = 'ENVIO'

/* ---------- BLOCO B: EVIDÊNCIA CAUSAL (3 LENTES) ---------- */
UNION ALL
SELECT 'B. Evidência', 10, 'Taxa de entrega: telefone = GR (bruta)',
       taxa_concordante_pct, '%',
       concat('IC95% [', ic95_inf_concordante_pct, ' ; ', ic95_sup_concordante_pct, ']'),
       'vt_res_03_bruto'
FROM vt_res_03_bruto
UNION ALL
SELECT 'B. Evidência', 11, 'Taxa de entrega: telefone ≠ GR (bruta)',
       taxa_discordante_pct, '%',
       concat('IC95% [', ic95_inf_discordante_pct, ' ; ', ic95_sup_discordante_pct, ']'),
       'vt_res_03_bruto'
FROM vt_res_03_bruto
UNION ALL
SELECT 'B. Evidência', 12, 'Lente 1 - Diferença bruta',
       diferenca_pp, 'p.p.',
       concat('p-valor = ', p_valor, '. ', leitura),
       'vt_res_03_bruto'
FROM vt_res_03_bruto
UNION ALL
SELECT 'B. Evidência', 13, 'Lente 1 - Diferença controlada por campanha (CMH)',
       diferenca_pp_mh, 'p.p.',
       concat('OR_MH = ', odds_ratio_mh, ' IC95% [', odds_ratio_ic95_inf, ' ; ', odds_ratio_ic95_sup,
              '], p-valor = ', p_valor, '. ', leitura),
       'vt_res_03_cmh'
FROM vt_res_03_cmh
UNION ALL
SELECT 'B. Evidência', 14, 'Lente 2 - Mesmo cliente, telefones diferentes (McNemar)',
       diferenca_pp, 'p.p.',
       concat('Pares = ', n_pares, ', só GR entregou = ', b_so_gr_entregou,
              ', só outro entregou = ', c_so_outro_entregou, ', p-valor = ', p_valor, '. ', leitura),
       'vt_res_04_mcnemar'
FROM vt_res_04_mcnemar
UNION ALL
SELECT 'B. Evidência', 15, 'Lente 2 - Mesmo cliente, mesma campanha (McNemar estrito)',
       diferenca_pp, 'p.p.',
       concat('Pares = ', n_pares, ', p-valor = ', p_valor, '. ', leitura),
       'vt_res_04_mcnemar_mesma_campanha'
FROM vt_res_04_mcnemar_mesma_campanha

/* ---------- BLOCO C: ROBUSTEZ ---------- */
UNION ALL
SELECT 'C. Robustez', 20, 'Campanhas em que o telefone do GR venceu',
       pct_campanhas_gr_venceu, '%',
       concat(gr_venceu, ' vitórias x ', gr_perdeu, ' derrotas em ', campanhas_avaliadas,
              ' campanhas avaliadas; p-valor do sinal = ', p_valor, '. ', leitura),
       'vt_res_06_teste_sinal'
FROM vt_res_06_teste_sinal
UNION ALL
SELECT 'C. Robustez', 21, 'Diferença excluindo a maior campanha',
       diferenca_pp, 'p.p.',
       concat('Campanha excluída: ', campanha_excluida, '; p-valor = ', p_valor),
       'vt_res_06_sem_maior_campanha'
FROM vt_res_06_sem_maior_campanha
UNION ALL
SELECT 'C. Robustez', 22, 'Diferença com regra EXATA de concordância',
       diferenca_pp, 'p.p.',
       concat('p-valor = ', p_valor, '. Compare com a regra tolerante (linha 12).'),
       'vt_res_06_regra_exata'
FROM vt_res_06_regra_exata WHERE regra = 'EXATA'
UNION ALL
SELECT 'C. Robustez', 23, 'Seleção: entrega de quem tem GR x quem não tem',
       diferenca_pp, 'p.p.',
       leitura,
       'vt_res_02_selecao'
FROM vt_res_02_selecao

/* ---------- BLOCO D: TRADUÇÃO PARA O VALUATION ---------- */
UNION ALL
SELECT 'D. Valuation', 30 + ordem,
       concat('Entregas líquidas - cenário ', cenario),
       entregas_liquidas, 'entregas',
       concat('Recuperadas ', entregas_recuperadas, ' - perdidas ', entregas_perdidas,
              ' = ', entregas_liquidas, ' (', pp_incremental_taxa_entrega, ' p.p. de entrega). ', premissa),
       'vt_res_05_saldo_liquido'
FROM vt_res_05_saldo_liquido
UNION ALL
SELECT 'D. Valuation', 40, 'CPFs hoje inalcançáveis para os quais o GR tem telefone novo',
       CAST(inalcancaveis_com_gr_novo_nao_testado AS DOUBLE), 'CPFs',
       concat('De ', cpfs_inalcancaveis_hoje, ' CPFs sem nenhuma entrega em nenhum telefone. ',
              'Outros ', inalcancaveis_com_gr_testado_e_falhou, ' já tiveram o telefone do GR testado sem sucesso.'),
       'vt_res_05_cpfs_recuperaveis'
FROM vt_res_05_cpfs_recuperaveis
UNION ALL
SELECT 'D. Valuation', 41, 'CPFs alcançáveis cujo telefone do GR já provou entregar',
       CAST(alcancaveis_gr_provado_entrega AS DOUBLE), 'CPFs',
       'Clientes com insucesso em outro número e entrega comprovada no número do GR.',
       'vt_res_05_cpfs_recuperaveis'
FROM vt_res_05_cpfs_recuperaveis
;

SELECT bloco, ordem, indicador, valor, unidade, leitura, origem
FROM vt_res_07_resumo_executivo
ORDER BY ordem
;
