# Metodologia estatística

Documento de referência para quem precisa defender (ou atacar) os números. O README conta a história; aqui estão as fórmulas, as hipóteses e as ameaças à validade.

---

## 1. O problema e por que não é uma simples correlação

Queremos o efeito causal de "usar o telefone do Golden Record (GR)" sobre "SMS entregue". O padrão-ouro seria um A/B: sortear clientes e enviar para o telefone do GR em um braço e para o telefone do CRM no outro. Não temos isso.

O que temos é uma alocação natural. O CRM escolheu telefones a partir de suas próprias origens. O GR foi construído a partir de outras origens, sem consultar nem os telefones nem os resultados do CRM. Quando os dois coincidem, é coincidência de fontes, não decisão de alguém que sabia o resultado. Isso satisfaz a condição central de um experimento natural: **o mecanismo de alocação é independente do desfecho, condicional às covariáveis que controlamos**.

O que NÃO é garantido: que as coincidências sejam independentes de características do cliente que também afetam a entrega. Um cliente cujo telefone aparece igual em duas fontes independentes pode ser um cliente com cadastro mais recente ou mais estável. Esse é o confundidor a atacar. Fazemos isso com três desenhos que controlam eixos diferentes:

| Desenho | Script | O que fixa | O que sobra como explicação |
|---|---|---|---|
| Estratificado por campanha (CMH) | 03 | período, mensagem, segmento, operadora do disparo | telefone + características do cliente |
| Pareado intra-CPF (McNemar) | 04 | tudo que é fixo na pessoa | telefone + campanha |
| Pareado intra-CPF e intra-campanha | 04.4 | pessoa e campanha | telefone |
| Recortes de sensibilidade | 06 | volume, regra de comparação, frequência de contato | verifica ausência de modificação de efeito |

A concordância entre os desenhos é o argumento. Nenhum deles sozinho é imune; juntos, exigem um confundidor que sobreviva a todos ao mesmo tempo.

---

## 2. Variáveis

- **Unidade:** envio = (cpf, campanha, telefone). Duplicidades consolidadas com `max(entregue)`.
- **Desfecho Y:** `entregue` = 1 se `bol_entregue` e não `bol_nao_entregue`; 0 no caso inverso; NULL (excluído) se ambos ou nenhum.
- **Tratamento T:** `concordante` = 1 se o telefone do envio é o do GR ranking 1 do CPF (regra tolerante: mesmo DDD e mesmos 8 últimos dígitos); 0 se diferente. Regra exata usada em sensibilidade.
- **Estrato:** `campanha`.
- **Universo:** envios cujo CPF existe no GR ranking 1 (`vt_experimento`).

---

## 3. Testes e estimadores

### 3.1 Duas proporções (scripts 02.5, 03.1, 06)

Com k1/n1 e k0/n0:

```
p_pool = (k1 + k0) / (n1 + n0)
z      = (p1 - p0) / sqrt( p_pool (1 - p_pool) (1/n1 + 1/n0) )
p-valor bilateral = 2 (1 - Φ(|z|))
IC95% da diferença = (p1 - p0) ± 1,96 sqrt( p1(1-p1)/n1 + p0(1-p0)/n0 )
```

IC de cada proporção pelo método de **Wilson** (não Wald), porque Wilson mantém cobertura nominal com n pequeno e p perto de 0 ou 1, situação comum em campanhas de 10 a 100 envios.

### 3.2 Cochran-Mantel-Haenszel por campanha (script 03.2)

Para o estrato k, tabela 2x2 com a (T=1,Y=1), b (T=1,Y=0), c (T=0,Y=1), d (T=0,Y=0), n = a+b+c+d:

```
E[a_k]   = (a+b)(a+c) / n
Var[a_k] = (a+b)(c+d)(a+c)(b+d) / ( n² (n-1) )
χ²_CMH   = ( Σ a_k - Σ E[a_k] )² / Σ Var[a_k]        ~ χ²(1)
OR_MH    = Σ (a d / n) / Σ (b c / n)
```

Variância de ln(OR_MH) por Robins, Breslow e Greenland (1986), válida tanto para poucos estratos grandes quanto para muitos estratos pequenos:

```
P = (a+d)/n   Q = (b+c)/n   R = ad/n   S = bc/n
Var = Σ PR / (2 (ΣR)²) + Σ (PS + QR) / (2 ΣR ΣS) + Σ QS / (2 (ΣS)²)
IC95%(OR) = exp( ln OR_MH ± 1,96 sqrt(Var) )
```

Diferença de risco ponderada de Mantel-Haenszel, para falar em pontos percentuais:

```
RD_MH = Σ w_k (p1k - p0k) / Σ w_k,   w_k = n1k n0k / nk
```

Estratos com um só braço não carregam informação sobre a diferença e são excluídos (sua contribuição a χ², R e S seria zero de qualquer forma). Sem correção de continuidade: com volumes na casa de milhões ela é irrelevante e só torna o teste conservador.

**Por que CMH e não regressão logística com efeito fixo de campanha:** o CMH é exatamente o teste escore da logística condicional para um único preditor binário, é calculável em SQL puro sem iteração, e não impõe suposição de forma funcional. Para mais covariáveis, a logística seria o passo seguinte (em PySpark).

### 3.3 McNemar pareado intra-CPF (script 04)

Para cada CPF com pelo menos um envio em cada braço, sorteia-se 1 envio por braço (ordenação por `xxhash64`, determinística) para equalizar exposição. Tabela pareada:

```
b = GR entregou e outro não     c = outro entregou e GR não
χ²_McNemar = (b - c)² / (b + c)   ~ χ²(1)
```

Complemento com todos os envios: d_i = taxa_conc_i − taxa_disc_i por CPF, z = média(d)/(dp(d)/√n). Com n na casa de milhares a aproximação Normal é adequada.

A versão 4.4 exige que os dois braços estejam na **mesma campanha** (o CRM disparou para dois telefones do mesmo cliente na mesma ação). Elimina o confundimento de campanha; só existe se essa prática ocorrer.

### 3.4 Teste do sinal entre campanhas (script 06.2)

Cada campanha com n ≥ mínimo em ambos os braços vota: GR venceu ou perdeu. Sob H0 (sem efeito) as vitórias seguem Binomial(n, 0,5):

```
z = (vitórias - n/2) / sqrt(n/4)
```

Não usa magnitude nem volume; é o teste mais livre de suposições do pacote e responde diretamente "o efeito é generalizado ou concentrado?".

### 3.5 Contrafactual do insucesso (script 05)

Para cada SMS não entregue cujo GR indicaria outro telefone (candidato), a entrega contrafactual é modelada assim:

| Cenário | Taxa aplicada | Justificativa |
|---|---|---|
| TETO | 1 | premissa pedida; limite superior lógico |
| CALIBRADO_GLOBAL | p1 = taxa de entrega do braço concordante, base toda | o telefone do GR entrega p1 quando é usado |
| CALIBRADO_CAMPANHA | p1_k da mesma campanha (fallback p1) | mesma janela, mensagem e público |
| EVIDÊNCIA_DIRETA_EXTRAPOLADA | taxa observada do telefone do GR nos CPFs em que ele já foi usado | controle por pessoa; extrapola para não testados |
| PISO_EVIDÊNCIA_DIRETA | só o que foi observado entregando | nada extrapolado |

As **perdas** usam a mesma lógica sobre os SMS entregues cujo GR indicaria outro telefone: ao trocar, a probabilidade de manter a entrega é a taxa do cenário. TETO assume perda zero por coerência com sua própria premissa.

Viés conhecido do CALIBRADO: p1 é medido em envios que "deram certo em coincidir", que podem ser clientes mais fáceis; a taxa contrafactual real nos insucessos tende a ser menor. Por isso o PISO existe e por isso o número central é declarado como estimativa, não como medição.

---

## 4. Ameaças à validade e resposta

**Validade interna (o efeito é do telefone?)**

1. *Confundimento por cliente.* Resposta: desenho pareado (04) e recorte por frequência (06.6).
2. *Confundimento por campanha.* Resposta: CMH (03.2), teste do sinal (06.2), pareado intra-campanha (04.4).
3. *Erro de medida do tratamento.* Concordância mal classificada por formatação. Resposta: regra tolerante como principal e regra exata como sensibilidade (06.5); anatomia dos formatos (02.6).
4. *Erro de medida do desfecho.* Status ambíguos. Resposta: exclusão e reporte (02.1).
5. *Temporalidade.* O GR usado é o atual; o envio pode ser anterior à ingestão. Sem data de envio no layout, não é controlável. Se existir, restringir a envios posteriores a `data_ingestao_gr` e comparar com o resultado sem restrição.

**Validade externa (para quem vale?)**

6. *Seleção do universo.* Só CPFs com GR. Resposta: `vt_res_02_selecao` compara a entrega dos dois grupos; se semelhante, a extrapolação é razoável; se não, o resultado vale para a população com GR.
7. *Generalização para o futuro.* O mix de campanhas muda. Resposta: reportar por faixa de volume (06.3) e por campanha (05.6) para reponderar.

**Validade de construto**

8. *"Entregue" não é "lido" nem "convertido".* O pacote mede entregabilidade. A conversão entra no valuation como multiplicador externo.

---

## 5. Regra de decisão sugerida

Declarar que "o GR é bom o suficiente para alimentar o CRM" se, simultaneamente:

1. `vt_res_03_cmh`: RD_MH > 0 e p < 0,05;
2. `vt_res_04_mcnemar`: b > c e p < 0,05;
3. `vt_res_06_teste_sinal`: GR venceu em mais de 50% das campanhas com p < 0,05;
4. `vt_res_06_regra_exata` e `vt_res_06_sem_maior_campanha` mantêm o sinal;
5. `vt_res_05_saldo_liquido`: PISO_EVIDÊNCIA_DIRETA > 0 (o pior caso defensável ainda é positivo).

Se 1 a 4 forem verdadeiras e 5 for falsa, o GR ajuda em média, mas a estratégia deve ser "usar o GR só onde o CRM falhou", não substituição total.

---

## 6. O que fortaleceria o resultado com pouco esforço

- **Data de envio** na base do CRM: resolve a ameaça 5 e permite estudar decaimento do telefone.
- **Piloto de 5%**: um A/B pequeno em uma campanha grande, com o GR em um braço, valida a calibração do cenário CALIBRADO com custo mínimo. O pacote diz onde apostar: campanhas com maior `saldo_calibrado` em `vt_res_05_valuation_por_campanha`.
- **Motivo do insucesso** (número inexistente, caixa cheia, bloqueio): separa "telefone errado" de "telefone certo, momento errado", e afina o contrafactual.

---

## 7. Referências

- Mantel, N.; Haenszel, W. (1959). Statistical aspects of the analysis of data from retrospective studies of disease. *JNCI* 22(4).
- Robins, J.; Breslow, N.; Greenland, S. (1986). Estimators of the Mantel-Haenszel variance consistent in both sparse data and large-strata limiting models. *Biometrics* 42(2).
- McNemar, Q. (1947). Note on the sampling error of the difference between correlated proportions or percentages. *Psychometrika* 12(2).
- Wilson, E. B. (1927). Probable inference, the law of succession, and statistical inference. *JASA* 22(158).
- Abramowitz, M.; Stegun, I. (1964). *Handbook of Mathematical Functions*, fórmula 26.2.17 (aproximação da CDF Normal).
- Dunning, T. (2012). *Natural Experiments in the Social Sciences*. Cambridge University Press.
