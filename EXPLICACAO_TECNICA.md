# Explicação técnica — Sugestão de endereço canônico por CPF em Databricks

> Este documento explica, do zero, o notebook `sugestao_endereco_cadastro_databricks.ipynb`: o problema, cada
> decisão de projeto, os termos técnicos usados e por que cada coisa foi feita de um jeito e não de outro.
> Foi escrito para um analista de TI júnior que precise **entender, operar, revisar ou estender** o processo.
> Sempre que um termo aparecer em **negrito com definição**, ele está no glossário da seção 2.

---

## 1. O problema em uma página

A empresa tem uma tabela `tb_endereco` com cerca de **10 bilhões de linhas**. Cada linha é "um endereço que um
cliente (`idCPF`) informou em algum momento". O mesmo cliente aparece dezenas de vezes e, na grande maioria, é o
**mesmo endereço escrito de formas diferentes**:

| Linha | logradouro | numero | complemento | cep_parte1 | cep_parte2 |
|---|---|---|---|---|---|
| 1 | `RUA ADINEI EMIDIO DE ALMEIDA, 123 APTO 45 BL B` | *(nulo)* | *(nulo)* | `01310` | `100` |
| 2 | `R ADINEI E DE ALMEIDA` | `123` | `AP 45 BLOCO B` | `1310` | `100` |
| 3 | `Adinei Emídio de Almeida` | `123` | *(nulo)* | `01310100` | *(nulo)* |
| 4 | `ADINEI EMIDIO DE ALMEIDA N 123` | `S/N` | `APTO 45` | `71697` | `976` |

As quatro linhas são o mesmo lugar. O que queremos entregar é a mesma tabela com colunas adicionais
`logradouro_sugestao`, `numero_sugestao`, `complemento_sugestao`, `bairro_sugestao`, `cidade_sugestao`,
`uf_sugestao`, `cep_parte1_sugestao`, `cep_parte2_sugestao`, **idênticas nas quatro linhas**, contendo o endereço
"correto": `AVENIDA ADINEI EMIDIO DE ALMEIDA`, `123`, `BLOCO B APTO 45`, CEP `01310-100`.

Existe uma base de apoio, `tb_correios` (uma extração do **DNE**, o cadastro oficial de CEPs dos Correios), com
CEP, tipo e nome do logradouro, bairro, município, UF e o "lado" da rua (par/ímpar). Ela é a única fonte externa de
verdade que temos — mas só sabe de logradouro, bairro, município e CEP. Número e complemento só o cliente sabe.

### O que torna o problema difícil

1. **Escala.** 10 bilhões de linhas não cabem em memória de máquina alguma. Qualquer coisa que rode "linha a
   linha em Python" leva dias. É preciso trabalhar em **Spark** (processamento distribuído) e evitar qualquer
   operação que traga dados para o Python.
2. **Variação quase infinita.** Não dá para prever todas as formas de escrever um endereço. Precisamos de várias
   técnicas em camadas: quando uma falha, a próxima cobre.
3. **Consistência.** Não adianta produzir uma sugestão boa em uma linha e outra diferente na linha ao lado do
   mesmo endereço. A sugestão tem de ser **uma por endereço**, replicada em todas as suas linhas.
4. **Auditabilidade.** Quem for revisar precisa conseguir ver *por que* o processo decidiu cada coisa.

---

## 2. Glossário (leia antes de continuar)

**Databricks** — plataforma em nuvem que roda Spark. Você escreve notebooks (células de código) e ela distribui
o processamento por um **cluster** (conjunto de máquinas). Um cluster tem um **driver** (a máquina que coordena e
roda o seu código Python) e vários **workers** (as máquinas que fazem o trabalho pesado, aqui com 32 GB e 8 cores
cada). Regra de ouro: o driver é pequeno; nunca traga dados grandes para ele.

**Spark / PySpark** — motor de processamento distribuído. PySpark é a interface em Python. Você descreve
transformações sobre um **DataFrame** (tabela distribuída); o Spark monta um plano e executa nos workers.

**Transformação lazy** — no Spark, `df.filter(...)`, `df.withColumn(...)` etc. **não executam nada**; só
descrevem. A execução acontece quando você pede um resultado (`count`, `write`, `show`). Isso permite ao Spark
otimizar o plano inteiro de uma vez.

**Partição** — pedaço de um DataFrame que fica numa máquina. Um DataFrame de 10 bi de linhas é dividido em
milhares de partições, processadas em paralelo.

**Shuffle** — quando uma operação precisa juntar linhas que estão em máquinas diferentes (por exemplo, "agrupe
por idCPF"), o Spark redistribui os dados pela rede. É a operação mais cara que existe. Bom projeto = poucos
shuffles, e sobre o mínimo de dados.

**Window (função de janela)** — cálculo feito "dentro de um grupo sem colapsar o grupo": por exemplo, "para cada
linha, o menor rótulo entre as linhas do mesmo idCPF". Internamente exige agrupar (shuffle) e ordenar.

**UDF (User Defined Function)** — função Python que você aplica a cada linha. Problema: o Spark precisa serializar
cada linha, mandar para um processo Python, esperar e trazer de volta. É de 10 a 100 vezes mais lento do que usar
as funções nativas do Spark (que rodam em Scala/Java dentro do worker). **Pandas UDF** é a versão em lote
(vetorizada) da UDF: bem mais rápida que a UDF comum, mas ainda mais lenta que o nativo. Neste projeto: **zero UDF
sobre a base completa**; pandas UDF só numa tabela pequena de pares candidatos.

**Expressão nativa** — funções que o Spark executa sem Python: `regexp_replace`, `split`, `translate`,
`array_sort`, `xxhash64`, `levenshtein`, `transform` etc. Todo o parsing deste notebook é feito com elas.

**Regex (expressão regular)** — linguagem de padrões de texto. Ex.: `\d{5}` = cinco dígitos. O Spark usa a
sintaxe do Java. Neste notebook as regex estão em *raw strings* do Python (`r"..."`) para não precisar duplicar
barras.

**Delta Lake / tabela Delta** — formato de tabela do Databricks (arquivos Parquet + um log de transações). Permite
sobrescrever, versionar (`VERSION AS OF`) e ler de volta com desempenho. Todas as tabelas gravadas aqui são Delta.

**Liquid Clustering (`CLUSTER BY`)** — forma de organizar fisicamente uma tabela Delta por uma coluna (aqui
`idCPF`) para que leituras e joins por essa coluna sejam mais rápidos. É o sucessor do particionamento por pasta.

**Catálogo / schema / tabela** — hierarquia de nomes no Unity Catalog do Databricks: `catalogo.schema.tabela`.

**Widget** — campo de parâmetro no topo do notebook Databricks (`dbutils.widgets`). Permite mudar comportamento
sem editar código. **dbutils.secrets** — cofre de segredos (chaves de API) do Databricks.

**Hash** — função que transforma qualquer valor num número de tamanho fixo, de forma determinística (o mesmo
valor sempre dá o mesmo número; valores diferentes quase nunca colidem). Usamos `xxhash64` para (a) sortear CPFs
de forma estável e (b) criar `hash_linha`, a identidade de uma linha pelo seu conteúdo.

**Normalização** — transformar texto em uma forma canônica para comparação: maiúsculas, sem acento, sem
pontuação, espaços únicos. `São João` e `SAO JOAO` viram a mesma coisa.

**Token** — cada palavra de um texto depois de separar por espaço. **Stopword** — palavra sem valor de
identificação (`DE`, `DA`, `DO`, `E`). **Chave de tokens** — tokens sem stopwords, sem repetição, em ordem
alfabética, unidos: `QUINZE DE NOVEMBRO` → `NOVEMBRO QUINZE`. Serve para comparar ignorando ordem e preposições.

**Chave fonética** — versão de uma palavra que representa "como ela soa", para que grafias diferentes com o
mesmo som coincidam (`XAVIER`/`CHAVIER`). O Spark tem `soundex`, mas é para inglês; escrevemos uma para pt-BR.

**Forma reduzida (regra do DNE)** — os Correios abreviam nomes longos mantendo o primeiro e o último nome e
reduzindo os do meio à inicial: `ADINEI EMIDIO DE ALMEIDA` → `ADINEI E DE ALMEIDA`. Reproduzimos a regra para
comparar as duas formas.

**Distância de Levenshtein** — número mínimo de edições (inserir, remover, trocar um caractere) para transformar
um texto em outro. `CASA`→`CAZA` = 1. Convertida em similaridade 0–1 dividindo pelo tamanho.

**Jaccard (de tokens)** — tamanho da interseção dividido pelo da união de dois conjuntos de tokens.
`{ADINEI, ALMEIDA}` × `{ADINEI, EMIDIO, ALMEIDA}` = 2/3.

**Fuzzy matching** — casar textos "aproximadamente iguais" usando essas medidas. **rapidfuzz** — biblioteca
Python muito rápida (C++) com medidas prontas (`token_set_ratio`, `WRatio`).

**Blocking** — técnica para não comparar tudo contra tudo. Antes de medir similaridade, restringe-se os
candidatos a quem compartilha uma chave barata (mesmo município e mesma inicial, por exemplo). Sem blocking, 1
milhão de consultas × 1 milhão de logradouros = 10¹² comparações; com blocking, milhões.

**Componentes conexas / propagação de rótulo** — pense num grafo em que cada variante é um ponto e há uma linha
entre duas variantes se elas compartilham alguma chave. Um "cluster" é um conjunto de pontos conectados direta ou
indiretamente. O algoritmo de propagação de rótulo descobre esses conjuntos sem construir o grafo: cada ponto
começa com um rótulo próprio e, repetidamente, adota o menor rótulo dos vizinhos até nada mudar.

**Voto ponderado** — cada variante "vota" no valor que ela tem para um campo, com um peso (quantas vezes
apareceu, qualidade, recência). Vence o valor com mais peso acumulado.

**Pivot** — transformar linhas em colunas. Aqui, a tabela longa `(cluster, campo, valor)` vira uma linha por
cluster com uma coluna por campo.

**LLM (Large Language Model)** — modelos como Claude ou GPT, acessados por API. **Prompt** — o texto enviado ao
modelo. **Saída estruturada / JSON Schema** — pedir ao modelo que responda exatamente num formato JSON definido,
para que a resposta possa ser lida por programa sem surpresas.

**ANSI mode** — no Spark 4 é o padrão: conversões inválidas (`"abc"` para inteiro) e índices fora do array
**lançam erro** em vez de devolver nulo. Por isso o código usa `try_cast`, `try_element_at`, `try_divide` e
`get()`, que devolvem nulo em vez de quebrar o job.

**Linhagem (lineage)** — o histórico de transformações que gera um DataFrame. Se você encadeia centenas de
`withColumn`, o plano fica gigantesco e o driver pode estourar memória só para analisá-lo. Gravar em Delta (ou
`localCheckpoint`) "corta" a linhagem: a próxima etapa começa de uma tabela lida do disco.

---

## 3. A arquitetura, de cima

```
tb_endereco (10 bi)                                      tb_correios (DNE)
     |                                                          |
 E1  amostra / lote  -> dedup em VARIANTES (idCPF + campos)     |
 E2  parsing + normalização (Spark nativo)                  E3  normalização + dims por CEP e por logradouro
 E4  validação de cada variante contra o CEP  <---------------------------+
 E5  fuzzy: acha o logradouro nos Correios para quem tem CEP errado/ausente
 E6  clustering dentro do CPF, nível 1: "quais variantes são o mesmo local (rua + número)?"  -> grupo_local
 E6b clustering nível 2: "dentro do local, quais são a mesma unidade (apartamento, bloco, sala...)?" -> cluster
 E7  eleição por campo dentro de cada cluster  +  E7b consolidação de grupos locais com a mesma sugestão
 E8  LLM só para clusters de baixa confiança (amostra, cache)
 E9  devolve a sugestão para cada linha original + métricas + checks de uniformidade
```

**Ideia central:** reduzir o problema em cada etapa. 10 bi de linhas viram alguns bilhões de *variantes* (E1);
variantes viram alguns milhões de *consultas* distintas para o fuzzy (E5); as consultas viram um número limitado
de *pares candidatos* (blocking); e só uma *amostra* de clusters difíceis vai ao LLM. Cada camada só faz o trabalho
caro sobre o que a camada anterior não resolveu.

### Por que "camadas com fallback" e não um único método?

Porque nenhum método sozinho cobre tudo:
- Só CEP: falha quando o CEP está errado (muito comum, como você viu na base).
- Só comparação de texto: falha em abreviações, erros de digitação e quando a rua nova não está nos Correios.
- Só LLM: caro demais para bilhões de linhas e não determinístico.

Combinando na ordem certa (barato e confiável primeiro, caro e incerto por último), cada linha recebe o melhor
tratamento que seu nível de sujeira exige.

---

## 4. Célula por célula

### 4.1 Documentação (célula 1)

A primeira célula é a documentação completa para outra pessoa/IA. Foi pedida assim de propósito: em um processo
com nove etapas e dezenas de decisões, quem for corrigir algo daqui a seis meses precisa do contexto no próprio
notebook, não num documento perdido.

### 4.2 `%pip install` e reinício do Python (células 2 e 3)

`%pip install rapidfuzz unidecode anthropic openai` instala bibliotecas no escopo do notebook.
`dbutils.library.restartPython()` reinicia o interpretador para que as bibliotecas sejam enxergadas. Está dentro de
`try/except` porque fora do Databricks `dbutils` não existe.

> **Dica:** por que não instalar no cluster inteiro? Instalar no notebook garante que quem importar o `.ipynb`
> tenha o que precisa sem depender de configuração de cluster. Em produção, vale migrar para uma lib de cluster ou
> um ambiente do bundle.

### 4.3 ⚙️ Configuração de ambiente (célula 4)

Um dicionário `AMBIENTES` com blocos `dev` e `prod`. Cada bloco tem catálogo, schemas, nomes das tabelas, prefixo
das saídas, o mapeamento de colunas e a configuração do LLM. `AMBIENTE_ATIVO` escolhe o bloco.

**Mapeamento de colunas** (`COLS_ENDERECO`, `COLS_CORREIOS`): a chave é o nome **interno** que o código usa
(`cep_parte1`), o valor é o nome **real** na sua tabela (`cep_parte 1`, com espaço, por exemplo). O código nunca
usa nomes reais diretamente: na leitura ele renomeia real → interno; na escrita, interno → real.

> **Por que assim e não editar os nomes espalhados pelo código?** Porque troca de tabela é a mudança mais comum
> em processos de dados (dev → homologação → produção) e é onde mais se erra. Concentrar em um lugar e validar
> (`verificar_ambiente()` confere se as tabelas e todas as colunas mapeadas existem) evita descobrir um nome errado
> depois de três horas de processamento.

### 4.4 Parâmetros (célula 6)

Lê os parâmetros com uma precedência fixa: JSON no widget `PARAMETROS_JSON` → widget individual → variável de
ambiente `END_<NOME>` → default do código. Assim o mesmo notebook roda no Databricks (widgets), num job (JSON),
num bundle do VS Code (variáveis de ambiente) e localmente (defaults).

Parâmetros que você mais vai mexer:

| Parâmetro | O que controla |
|---|---|
| `MODO_AMOSTRA`, `FRACAO_AMOSTRA` | rodar só uma fração dos CPFs (sorteio por hash, estável entre execuções) |
| `N_LOTES`, `LOTE_ATUAL` | dividir a base completa em lotes por hash do CPF (append na saída) |
| `PERSISTIR_INTERMEDIARIOS` | gravar cada etapa em Delta (recomendado na base real) |
| `ETAPAS_A_EXECUTAR` | reexecutar só algumas etapas, lendo as anteriores das tabelas |
| `LIMIAR_SIM_LOGRADOURO` | a partir de que similaridade "o logradouro bate com o do CEP" (0.80) |
| `LIMIAR_FUZZY_CORREIOS`, `MARGEM_FUZZY` | aceitação do fuzzy (88 de 100) e margem sobre o 2º candidato |
| `USAR_LLM`, `LIMITE_LLM`, `LIMIAR_CONFIANCA_PARA_LLM` | fallback LLM: liga, quantos clusters, abaixo de que score |
| `N_PARTICOES_SHUFFLE` | número de partições nos shuffles (2–3× o total de cores do cluster) |

Também define os helpers de I/O:
- `persistir(df, sufixo)` grava a etapa em Delta com `CLUSTER BY idCPF` e **lê de volta** (corta linhagem). Sem
  persistência, usa `localCheckpoint` pelo mesmo motivo.
- `obter(sufixo)` devolve a etapa da memória ou da tabela — é o que permite reiniciar do meio.
- `nome_intermediario(sufixo)` monta o nome completo com prefixo e, se houver lotes, o sufixo `_loteNN`.

> **Por que persistir cada etapa?** Três razões: (1) reinício — se E6 quebra, você não refaz E1–E5;
> (2) auditoria — dá para abrir `_03_validado` e ver por que uma variante ganhou score 20;
> (3) plano de execução — sem cortar a linhagem, o Spark tenta otimizar um plano com centenas de projeções e regex
> e o driver estoura memória (aconteceu no teste local antes da correção).

### 4.5 Referências (células 7–8)

Dicionários de conhecimento de domínio, em Python puro, para serem fáceis de estender:
- `MAPA_TIPOS_CLIENTE`: como clientes escrevem o tipo de logradouro (`R`, `R.`, `RUA`, `AV`, `AVN`...) → forma
  canônica (`RUA`, `AVENIDA`). Aplicado só ao **primeiro token** do logradouro.
- `MAPA_TIPOS_CORREIOS`: abreviações oficiais do DNE (`TV`, `AL`, `PC`...). Os ~360 tipos não estão todos; os que
  faltarem são impressos em E3 para você acrescentar.
- `MAPA_TITULOS`: `DR`→`DOUTOR`, `PROF`→`PROFESSOR`, `MAL`→`MARECHAL`... Letras únicas (`D`, `S`) **não** são
  expandidas, porque colidem com iniciais da forma reduzida; casos especiais (`S JOAO`→`SAO JOAO`, `N S`→`NOSSA
  SENHORA`) são tratados por regex com lista de nomes de santos.
- `MAPA_COMPL` e `ORDEM_COMPL`: palavras-chave de complemento (`AP`, `APT`, `APTO` → `APTO`) e a ordem em que a
  sugestão é montada (`BLOCO B APTO 45`, não `APTO 45 BLOCO B`).
- `MESES`, `STOPWORDS`, `UFS`/`MAPA_UF`, `FAIXAS_CEP_UF` (faixas oficiais de CEP por estado — validação barata que
  não depende dos Correios), `ALIASES_CIDADE` (`SP`, `BH`, `POA`, `S PAULO`...).

Os dicionários viram colunas Spark do tipo `map` (`F.create_map`) para serem consultados com `try_element_at`
nativamente — sem UDF.

> **Dica:** `GAL` significa "Galeria" no DNE mas "General" em 99 % dos endereços de clientes. Por isso está em
> `MAPA_TIPOS_CORREIOS` como GALERIA (só se aplica ao campo `tipo` dos Correios) e em `MAPA_TITULOS` como GENERAL
> (aplicado dentro do nome). Ambiguidades assim são resolvidas pelo **contexto em que o token aparece**, não por
> uma regra global.

### 4.6 Helpers (células 9–10)

Funções que recebem e devolvem `Column` do Spark — ou seja, **compõem expressões** que rodam nos workers.

- `norm_basica` / `norm_chave` / `norm_local`: normalização. Acentos são removidos com `translate` (tabela de
  correspondência caractere a caractere), porque o Spark não tem "remover acento" nativo e uma UDF com
  `unidecode` custaria caro em bilhões de linhas.
- `fonetica_br`: cadeia de ~20 `regexp_replace` que implementa um Metaphone simplificado para português
  (`PH→F`, `CH/SH→X`, `SS/Z→S`, `LH→L`, `NH→N`, `QU→K`, `C(E,I)→S`, `C→K`, `G(E,I)→J`, `W→V`, `Y→I`, `H` mudo,
  vogais internas removidas, letras duplas colapsadas). `FONSECA` e `FONCECA` viram `FNSK`.
- `forma_reduzida`: usa `transform` com índice (função de ordem superior do Spark) para abreviar os tokens do
  meio: `transform(tokens, (t, i) -> se 0 < i < último e não stopword então inicial senão t)`.
- `sim_jaccard`, `sim_contencao`, `sim_lev`, `sim_logradouro`: similaridades 0–1. `sim_logradouro` devolve o
  **máximo** entre várias medidas (tokens, Levenshtein, fonética igual, forma reduzida igual, reduzido do cliente
  = reduzido dos Correios). Máximo, e não média, porque cada medida cobre um tipo de variação: se qualquer uma
  reconhece a igualdade, é igual.
- `faixa_uf_expr`: `CASE WHEN` gerado a partir de `FAIXAS_CEP_UF`.
- `flags_array`: monta um array com os nomes das condições verdadeiras (é o que alimenta `flags_sugestao`).

> **Por que não `soundex`?** É um algoritmo para inglês: trata `CH`, `LH`, `NH`, `Ç` de forma errada para
> português e comprime demais (4 caracteres). A versão própria mantém mais informação e conhece os dígrafos do
> português.

### 4.7 Dados sintéticos (células 11–12)

Com `MODO_TESTE_SINTETICO=True`, gera no driver uma mini `tb_correios` (60 logradouros em 5 municípios, com CEP por
lado par/ímpar e um município com CEP único) e uma `tb_endereco` com N CPFs, 1–2 endereços verdadeiros cada e
3–14 variantes sujas por endereço, reproduzindo todas as patologias listadas. Guarda um **gabarito** (o endereço
verdadeiro de cada linha) para E9 medir acerto.

> **Por que dados sintéticos?** Porque permitem testar o notebook inteiro em minutos, sem acesso à base real, e
> medir precisão de forma objetiva. Não substituem a validação na base real — as patologias reais são mais
> variadas — mas provam que o encanamento funciona e servem de regressão quando você mexer em regras.

### 4.8 E1 — Leitura, escopo e dedup em variantes

1. Lê `tb_endereco` renomeando colunas reais → internas, tudo como string.
2. Escopo: lista de CPFs, **ou** fração por `pmod(xxhash64(idCPF), 1e6) < fração × 1e6`, **e** lote por
   `pmod(xxhash64(idCPF), N_LOTES) == LOTE_ATUAL`.
3. `hash_linha = xxhash64(idCPF, campos brutos)`.
4. `groupBy(idCPF, hash_linha, campos).agg(count)` → **variantes** com `qtd_ocorrencias`.

> **Por que sortear por hash do CPF e não por `sample()`?** O `sample()` pega linhas aleatórias; você ficaria
> com 3 das 40 linhas de um cliente e o clustering perderia sentido. Hash do CPF traz **todas** as linhas dos
> clientes sorteados e o sorteio é o mesmo em toda execução (reprodutível).

> **Por que dedup primeiro?** Linhas idênticas são muito comuns (o mesmo cadastro reimportado). Se 10 bi de linhas
> viram 2 bi de variantes, todo o resto do processo custa 5× menos. A contagem vira o peso do voto em E7, então
> nenhuma informação se perde. E `hash_linha` é o que permite devolver a sugestão a cada linha original no fim
> (E9) com um join simples.

### 4.9 E2 — Normalização e parsing

A etapa mais longa. Transforma cada variante em campos estruturados. Passos:

**A. Normalização básica** de cada campo. UF via `MAPA_UF` (aceita `SAO PAULO`, `sp`, `S P`). Cidade via
`ALIASES_CIDADE` e remoção de `- SP` no fim. Se a UF vier vazia, é **inferida**: pelo campo cidade quando ele
contém uma UF (`cidade="SP"`), ou por município de UF única (lista tirada da própria `tb_correios`). Flag
`UF_INFERIDA_PELA_CIDADE`.

**B. CEP.** As duas partes são reduzidas a dígitos e classificadas (`CASE WHEN` em ordem de confiança):

| Caso | Exemplo (`p1`, `p2`) | Resultado | `cep_origem` |
|---|---|---|---|
| 5 + 3 dígitos | `01310`, `100` | `01310100` | `CAMPOS` |
| 8 na parte 1 | `01310100`, nulo | `01310100` | `P1_COMPLETO` |
| 8 na parte 2 | nulo, `01310100` | `01310100` | `P2_COMPLETO` |
| partes curtas | `1310`, `100` | `lpad` → `01310100` | `ZEROS_CORRIGIDOS` |
| 7 dígitos ao todo | `1310100`, nulo | `01310100` | `ZEROS_CORRIGIDOS` |
| só a parte 1 | `01310`, nulo | `01310000` | `SUFIXO_000_INCERTO` |

Padrões impossíveis (`00000000`, `11111111`, `12345678`) viram nulo. Um CEP escrito **dentro do logradouro**
(`... CEP 01310-100`) é extraído separadamente (`cep_embutido`) e usado em E4 se o CEP dos campos não existir.
`cep_faixa_uf_ok` compara o CEP com a faixa oficial da UF informada.

> **Por que `lpad` de zeros?** Porque a causa mais comum de CEP "quebrado" é alguém ter guardado o CEP como
> número inteiro: `01310` vira `1310`. Repor zeros à esquerda recupera o valor; a flag `ZEROS_CORRIGIDOS` mantém
> registrado que houve reconstrução (e o score de qualidade desconta um pouco).

**C. Logradouro.** É onde o cliente mistura tudo. A sequência:
1. Remove `CEP xxxxx-xxx` e o rótulo `CEP`; converte `S/N` em `SN`.
2. **Segmenta** por vírgula e por ` - ` (hífen com espaços). O 1º segmento é o nome da rua; os demais são número,
   complemento, bairro, cidade ou referência. Segmentos que são iguais ao bairro/cidade/UF da própria linha, que são
   um município conhecido dos Correios (`SAO PAULO SP`), ou que são só letras sem palavra-chave de complemento, são
   **descartados** (flag `BAIRRO_CIDADE_NO_LOGRADOURO`). Os demais são reunidos de volta.
3. **Protege datas**: `15 DE NOVEMBRO` vira `15_DE_NOVEMBRO` para o "15" não ser lido como número da casa.
4. **Corta o complemento** na primeira palavra-chave com valor (`APTO 45`, `BL B`, `KM 12`) ou solitária
   (`FUNDOS`). Se, sem isso, não sobrar nome de rua (`QD 12 LT 5`, endereço de Goiânia), a extração é revertida.
5. **Extrai o número**: primeiro com marcador (`N 123`, `Nº 123`, `NUM 123`), senão o número no fim do texto.
   Se, sem o número, não sobrar nome (`RUA 7`), reverte — é uma rua numerada.
6. Desfaz a proteção de datas, limpa, e remove `BAIRRO`/`CIDADE UF` colados no fim sem separador.
7. **Tipo** = 1º token se estiver em `MAPA_TIPOS_CLIENTE`; **nome** = o resto, com títulos expandidos.
8. Gera as chaves: `nome_chave` (tokens ordenados), `nome_fon` (fonética), `nome_red` e `nome_red_chave`
   (forma reduzida), `logradouro_limpo` (tipo + nome, para exibição).

> **Por que regex em vez de um modelo de "parsing de endereço" (como deepparse/libpostal)?** Dois motivos: você
> não pode baixar modelos no cluster, e um modelo teria de rodar como UDF em bilhões de linhas. Regex nativa roda
> nos workers, é auditável (dá para ver exatamente qual regra pegou) e cobre os padrões brasileiros que importam.
> O custo é manutenção: casos novos entram como regras novas. As listas de "não mapeados" impressas em E2/E3 são o
> mecanismo para descobrir esses casos.

**D. Número (campo).** Dígitos sem zeros à esquerda; `S/N`, `SN`, `SEM NUMERO`, `0` viram `SN`; `123A` vira número
`123` + sufixo `A`; `KM 12` vira complemento. Prioridade: campo numérico > número extraído do logradouro > número
achado dentro do complemento (`APTO 4 N 123`) > `SN`. Conflito entre campo e extraído gera `NUMERO_CONFLITO` e
desconta no score.

**E. Complemento.** Junta o campo + o que foi extraído do logradouro; canoniza palavras-chave (`AP`→`APTO`);
descola `APTO45`; `3 ANDAR`→`ANDAR 3`; extrai **pares** `TIPO VALOR` (`APTO 45`, `BLOCO B`, `FUNDOS`) em
`compl_pares` e deixa a sobra em `compl_livre`.

> **Por que pares em vez de texto?** Porque em E7 cada tipo de par é votado separadamente. Assim `APTO 45` numa
> linha e `BLOCO B` em outra se **complementam** (`BLOCO B APTO 45`), e `APTO 45` × `APTO 54` é decidido pela
> maioria. Com texto puro, "APTO 45 BLOCO B" e "BLOCO B APTO 45" seriam valores diferentes disputando entre si.

**F. Flags.** Tudo que foi corrigido/detectado vira uma string num array (`CEP_ZEROS_CORRIGIDOS`,
`NUMERO_EXTRAIDO_DO_LOGRADOURO`...). É o rastro de auditoria que chega até a saída.

### 4.10 E3 — Base dos Correios

Aplica **as mesmas funções** de normalização à `tb_correios`. Isso é essencial: se o cliente é normalizado de um
jeito e os Correios de outro, as chaves não coincidem. Produz:

- `_dim_correios_cep`: uma linha por CEP com UF, município, bairro, tipo, nome e chaves do logradouro, os lados
  existentes (`P`, `I`, `A`), e `c_cep_tipo` = `LOGRADOURO` ou `LOCALIDADE` (municípios pequenos têm um CEP só,
  sem rua).
- `_dim_correios_logradouro`: uma linha por (UF, município, tipo, chave do nome) com a lista de CEPs (cada um com
  lado e bairro) e chaves de blocking (1º token, último token, fonética, forma reduzida).

Se `logradouro_correios` vier com o tipo na frente (`R ADINEI...`), o 1º token é removido quando coincide com o
campo `tipo`. Se existir a coluna de logradouro reduzido oficial, ela vira uma chave adicional.

> **Por que duas dims?** A dim por CEP responde "dado um CEP, que endereço é?" (E4). A dim por logradouro
> responde "dado um nome de rua numa cidade, que CEPs existem?" (E5). São perguntas inversas e cada uma precisa de
> uma tabela organizada de um jeito.

### 4.11 E4 — Validação via CEP e score de qualidade

Join (com **broadcast** — a dim é pequena e é copiada para todos os workers, evitando shuffle da base grande)
das variantes com a dim por CEP. Segundo join pelo `cep_embutido` para quem não achou o primeiro.

Calcula, por variante: `sim_log_cep` (similaridade entre o nome da rua do cliente e o do CEP),
`logradouro_bate` (≥ `LIMIAR_SIM_LOGRADOURO`), `uf_ok`, `municipio_ok`, `bairro_ok`, `lado_ok` (paridade do
número × lado do CEP), `faixa_ok` (faixa numérica, se sua base tiver), `cep_confiavel` e `cep_contradiz`
(CEP existe, mas a rua não bate **e** a UF é outra → CEP quase certamente errado).

`score_qualidade` (0–100) soma pontos por cada indicador positivo e desconta por conflitos. Ele **não** decide
nada sozinho: vira o multiplicador do peso do voto em E7. Uma variante com CEP validado e rua batendo pesa mais
que uma com CEP aleatório.

> **Por que broadcast?** Um join normal entre 2 bi de variantes e 1 mi de CEPs faria shuffle dos 2 bi. Com
> broadcast, o Spark manda a tabela pequena (dezenas de MB) para cada worker e o join acontece localmente. Se sua
> `tb_correios` for muito maior que o normal (> ~500 MB), desligue `BROADCAST_CORREIOS`.

### 4.12 E5 — Fuzzy contra os Correios

Para variantes cujo CEP não existe, contradiz o endereço ou cuja rua não bate:

1. Reduz a **consultas distintas** (UF, cidade, tipo, chave do nome). Bilhões de variantes viram alguns milhões
   de consultas — porque a mesma rua escrita do mesmo jeito aparece em muitos CPFs.
2. **Blocking** por município (UF, quando informada): candidatos que compartilham 1º token, ou fonética, ou
   último token, ou forma reduzida. Consultas sem candidato no município ganham uma 2ª passada só por UF
   (para cidade escrita diferente, distrito etc.), com penalidade.
3. Similaridade nativa para podar (≥ 0.35, no máximo `MAX_CANDIDATOS_FUZZY` por consulta).
4. `rapidfuzz` numa pandas UDF **só sobre os pares que sobraram**: `token_set_ratio` (bom para tokens em ordem
   diferente e subconjuntos), `WRatio` e `partial_token_sort_ratio`.
5. Score final 0–100 com bônus/penalidade pelo tipo (`RUA` × `AVENIDA`). Aceita o melhor candidato se
   `score ≥ LIMIAR_FUZZY_CORREIOS` **e** a diferença para o 2º colocado é ≥ `MARGEM_FUZZY`; senão marca
   `FUZZY_AMBIGUO` (dois candidatos parecidos demais — melhor não chutar).
6. De volta à variante, escolhe o CEP entre os CEPs da rua casada usando a **paridade do número** (lado par/ímpar)
   e a faixa numérica. Se sobrar mais de um, mantém o CEP da própria variante se estiver entre eles; senão fica sem
   CEP (mas com rua, bairro e município sugeridos) — flag `FUZZY_CEP_AMBIGUO`.

> **Por que a margem sobre o 2º candidato?** Um score alto sozinho engana: `RUA SAO JOAO` tem score 95 contra
> `RUA SAO JOAO BATISTA` e 93 contra `RUA SAO JOAO EVANGELISTA`. Se os dois melhores estão muito próximos, o
> processo não tem base para escolher, e um erro aqui trocaria o CEP do cliente por um de outra rua.

### 4.13 E6 — Clustering dentro do CPF

A pergunta: "entre as variantes deste CPF, quais são o mesmo endereço?"

Solução ingênua: comparar cada variante com cada outra (30 variantes → 435 comparações por CPF; multiplicado por
centenas de milhões de CPFs, inviável, e ainda teria de calibrar um limiar de similaridade para tudo).

Solução adotada: **união por chaves**. Cada variante recebe até 7 chaves, e duas variantes que compartilham
**qualquer** chave estão no mesmo cluster:

| Chave | Composição | Pega o caso |
|---|---|---|
| `k_cep` | CEP + número | CEP certo, rua escrita de qualquer jeito |
| `k_log` | chave do nome + número | mesma rua, CEP errado |
| `k_fon` | fonética + número | grafia diferente com o mesmo som |
| `k_red` | forma reduzida + número | `ADINEI EMIDIO` × `ADINEI E` |
| `k_cor` | id do logradouro nos Correios (via CEP ou fuzzy) + número | qualquer variante que os Correios reconheceram |
| `k_p5` | 5 primeiros dígitos do CEP + número + 1º token | CEP com sufixo errado |
| `k_ana` | anagrama do nome (letras ordenadas) + UF + número | erro de digitação por troca de letras (`FOSNECA`) |

**Todas** as chaves contêm o número. É o que impede juntar `RUA X, 100` com `RUA X, 200` — dois endereços reais
na mesma rua (o cliente mudou de casa). O preço é que um erro de digitação no número separa clusters; E7 ainda
elege o número majoritário dentro de cada cluster, e E7b junta clusters cuja sugestão coincide.

**Propagação de rótulo.** Cada variante começa com um rótulo (sua posição no CPF). A cada iteração, para cada
chave, calcula-se `min(rotulo) over (idCPF, chave)` com função de janela, e a variante adota o menor entre todos.
Repete até nada mudar (3–4 iterações na prática). É matematicamente o mesmo que calcular componentes conexas do
grafo "compartilha chave", mas sem construir grafo e usando só operações do Spark.

Detalhes de performance: o loop roda sobre uma tabela **estreita** (idCPF, hash_linha, 7 chaves, rótulo) e não
sobre as 80 colunas da variante; os dados são reparticionados por `idCPF` uma vez por iteração, e as sete janelas
por `(idCPF, chave)` reaproveitam essa partição (o Spark reconhece que particionar por `idCPF` já satisfaz um
agrupamento por `(idCPF, chave)`), evitando sete shuffles. Cada iteração é persistida para cortar a linhagem.

**Variantes sem número** (`nulo`, `S/N`, `0`) não geram chaves. Depois do loop, cada uma é **anexada** a um cluster
numerado do mesmo CPF se existir **exatamente um** com a mesma rua (chave, fonética, id Correios ou CEP). Se houver
dois, fica sozinha — não dá para saber a qual pertence. As que não se anexaram são agrupadas entre si.

> **Por que não usar uma biblioteca de grafos (GraphFrames, NetworkX)?** GraphFrames não vem no runtime e
> exigiria construir uma tabela de arestas (pares) — que é justamente o que evitamos. NetworkX rodaria no driver,
> em Python, e não escala. A propagação por janelas usa só o Spark e explora o fato de que os grupos (um CPF) são
> pequenos.

O resultado de E6 é o **`grupo_local`**: "mesma rua + mesmo número", ou seja, o prédio ou o lote. Ele ainda **não**
é o endereço — é o assunto da próxima etapa.

### 4.13b E6b — Unidades dentro do mesmo local (apartamentos, blocos, salas, lotes, frente/fundos)

Um cliente pode ter dois ou mais endereços **no mesmo prédio**: `APTO 45` e `APTO 46`, `BLOCO A` e `BLOCO B`,
`SALA 101` e `SALA 205`, `KM 12` e `KM 15` numa rodovia, a casa da `FRENTE` e a dos `FUNDOS`. Rua, número e CEP
são iguais; só o complemento distingue. Fundir isso numa sugestão única seria um erro grave: metade das linhas
receberia o apartamento errado. Por outro lado, o caso mais comum é o oposto — um único apartamento, com o
complemento faltando em algumas linhas — e aí as linhas sem complemento **devem** receber o complemento.

E6b resolve os dois casos com a noção de **compatibilidade**:

1. Cada variante recebe uma **assinatura**: os pares distintivos de `compl_pares` (`APTO 45`, `BLOCO B`, `KM 12`;
   palavras de posição viram `POSICAO FUNDOS`/`POSICAO FRENTE`). Zeros à esquerda são removidos (`APTO 045` =
   `APTO 45`). Texto livre (`PROXIMO AO MERCADO`) não entra: não dá para comparar com segurança.
2. Duas assinaturas são **compatíveis** quando, para todo tipo de par presente nas duas, o valor é o mesmo.
   `{APTO 45}` e `{BLOCO B}` são compatíveis (nada em comum contradiz); `{APTO 45}` e `{APTO 46}` **conflitam**.
3. Dentro de cada `grupo_local`, as assinaturas **maximais** (que não estão contidas em outra) definem as unidades:
   - se nenhuma maximal conflita com outra, o grupo é **uma** unidade e a assinatura da unidade é a união dos pares
     (`APTO 45 | BLOCO B`) — cobre "APTO 45 BL B" numa linha, "AP 45" em outra e "BLOCO B" em outra;
   - se há conflito, as maximais em conflito são **âncoras** (unidades distintas por evidência). Uma assinatura
     parcial (`{BLOCO B}` quando existem `{APTO 45}` e `{APTO 46}`) só entra numa unidade se for compatível com
     **exatamente uma**; compatível com duas ⇒ **ambígua**, cluster próprio.
4. Linhas **sem complemento**: se o grupo tem uma unidade só, entram nela. Se tem duas ou mais, formam um cluster
   próprio, **sem complemento sugerido**, com a flag `COMPLEMENTO_AMBIGUO`. O processo não chuta em qual
   apartamento a linha estava — sugere rua, número, CEP, bairro, cidade e UF (que são iguais) e deixa o complemento
   vazio para revisão (ou para o LLM de E8, se você quiser tentar).
5. `cluster_id = grupo_local # hash(unidade)`, e a coluna `unidade` mostra os pares que definem o cluster.

Implementação: a assinatura é calculada nativamente; grupos com 0 ou 1 assinatura não vazia (a enorme maioria)
são resolvidos nativamente; só os grupos com 2+ assinaturas distintas passam por uma pandas UDF que aplica as
regras acima a uma lista de poucas strings. A célula traz **auto-testes** dessa função (os cenários acima); se um
falhar, a célula para antes de processar dados.

> **Por que "conflito separa, ausência não separa"?** Porque são evidências diferentes. Duas linhas com `APTO 45`
> e `APTO 46` são prova de duas unidades. Uma linha sem complemento não é prova de nada: pode ser qualquer uma. A
> regra copia o raciocínio de um analista: só junta o que não se contradiz, e só preenche o que falta quando há uma
> única resposta possível.

> **Limite honesto:** `APTO 45` e `APTO 45 BLOCO A` são tratados como a mesma unidade (o segundo só completa o
> primeiro). Se o cliente tem de fato o apto 45 do bloco A **e** o apto 45 do bloco B, só linhas que citem os dois
> blocos separam as unidades. É um caso raro e, sem a informação, indecidível.

Teste sintético do cenário: parte dos CPFs sintéticos recebe **duas unidades no mesmo prédio** (mesma rua, número
e CEP; `APTO n` e `APTO n+1`, às vezes com bloco). A métrica `fusoes_indevidas` (clusters não ambíguos que
misturam dois endereços verdadeiros) tem de ser **0**, e `pct_linhas_complemento_ambiguo` mostra quantas linhas
ficaram sem complemento por serem indecidíveis.

### 4.14 E7 — Eleição por campo

Para cada cluster, elege **campo a campo** (não "a melhor linha inteira"):

1. **Valores efetivos** por variante: CEP confiável (Correios via CEP ou via fuzzy) > CEP que existe e não
   contradiz > bruto (só se estiver na faixa da UF). Logradouro dos Correios quando bate (mantendo o nome completo
   do cliente se ele for a versão expandida do reduzido oficial) > logradouro limpo do cliente. Bairro, município
   e UF dos Correios quando o CEP é confiável > os do cliente.
2. **Peso do voto** = `qtd_ocorrencias × (1 + score_qualidade/100) × recência`, vezes um fator por campo (CEP dos
   Correios pesa 2×, fuzzy 1.6×, bruto 0.5×; campos de localização respaldados pelos Correios 1.8×).
3. **Urna em formato longo**: uma tabela `(cluster_id, campo, valor, peso, bônus)` com uma linha por variante e
   campo (feita com `explode` de um array de structs) → soma de peso por valor → vencedor por `peso/total + bônus` →
   `pivot` para uma linha por cluster. É **um** shuffle para todos os campos, em vez de um por campo.
4. **Complemento**: pares votados por tipo e remontados na ordem de `ORDEM_COMPL`.
5. **Número**: vota primeiro só entre valores numéricos; `SN` só vence se ninguém tiver número. O sufixo de letra
   (`123A`) é votado à parte e **a ausência conta como voto** — senão uma única linha `795A` venceria dez linhas
   `795`.
6. `metodo_sugestao` (`CORREIOS_CEP`, `CORREIOS_FUZZY`, `CONSENSO_INTERNO`, `VARIANTE_UNICA`, `SEM_SUGESTAO`),
   `score_confianca_sugestao` (0–100: respaldo dos Correios + concordância dos votos + completude),
   `concordancias` (JSON com a fração de peso que concordou com o vencedor em cada campo), `flags_sugestao`.

Todos os desempates são determinísticos (rank → peso → ordem alfabética) e os arrays são ordenados: duas
execuções dão a mesma sugestão.

> **Por que por campo e não "a linha mais completa"?** Porque a informação está espalhada: a linha com o CEP
> certo tem o complemento vazio; a linha com o complemento tem CEP aleatório. Votar por campo junta o melhor de
> cada uma.

> **Por que bônus de completude no logradouro?** Só frequência elegeria `R ADINEI E DE ALMEIDA` (escrito 8 vezes)
> sobre `AVENIDA ADINEI EMIDIO DE ALMEIDA` (escrito 2 vezes). Os dois são o mesmo endereço; o segundo é a versão
> mais informativa. O bônus (respaldo dos Correios, tipo presente, nome mais longo) inclina a eleição para a forma
> completa sem ignorar a frequência.

### 4.15 E7b — Consolidação (a garantia de uniformidade)

Depois da primeira eleição, pode existir o mesmo endereço em dois clusters do mesmo CPF (E6 não achou chave em
comum: erro de digitação + CEP aleatório, por exemplo). Se ficasse assim, as linhas de um cluster teriam uma
sugestão e as do outro, outra — exatamente o que não pode acontecer.

E7b resolve: aplica a **mesma propagação de rótulo** agora sobre os grupos locais, usando a **sugestão eleita**
como chave (`CEP+número` para CEPs de logradouro, `rua+número+cidade`, `fonética+número+cidade`, e as versões sem
número; a chave `GL` amarra todas as unidades de um grupo para se moverem juntas). Grupos que caem no mesmo rótulo
são fundidos, a divisão por unidade (E6b) é **refeita** no grupo fundido — apartamentos distintos continuam
separados — e os clusters resultantes são **reeleitos** (flag `CLUSTER_CONSOLIDADO`). Só os grupos afetados são
reprocessados; os demais mantêm a 1ª eleição. O mapa linha → cluster consolidado vai para
`_05b_clusters_consolidados`, que é o que E9 usa.

Resultado: **um endereço sugerido (local + unidade) ⇒ um `cluster_id` ⇒ uma única sugestão em todas as suas
linhas.**

No teste com todas as chaves ligadas, E7b não precisou fundir nada. Desligando cinco das sete chaves de E6 de
propósito (`CHAVES_CLUSTER_DESATIVADAS`), E6 fragmentou em 424 clusters, E7b fundiu 45 e os checks de E9 ficaram em
zero.

### 4.15b Grau de certeza — o que aplicar sozinho e o que mandar para gente

O `score_confianca_sugestao` (0–100) é contínuo e serve para ordenar. Para **decidir** (aplicar automaticamente,
conferir por amostragem, ou mandar para um time humano) é melhor uma escala pequena e explicável. Cada linha da
saída recebe `grau_certeza`, `requer_revisao_humana` (booleano) e `motivos_revisao` (lista de razões):

| Grau | Quando | Uso sugerido |
|---|---|---|
| `A_ALTA` | score ≥ 85, CEP respaldado pelos Correios e **nenhuma** restrição abaixo | aplicar automaticamente |
| `B_MEDIA` | score ≥ 65, ou rebaixado por: o cliente tem 2+ unidades no mesmo prédio (`MULTIPLAS_UNIDADES_NO_LOCAL`), endereço sem número (`SEM_NUMERO`), número desta linha preenchido a partir do cluster porque a linha era S/N (`NUMERO_PREENCHIDO_PELO_CLUSTER`), consenso interno forte sem Correios, LLM aplicado | aplicar com amostragem de conferência |
| `C_BAIXA` | score < 65, ou rebaixado por: CEP sem validação nos Correios, CEP ausente, conflito de número entre as variantes, variante única sem Correios, consenso interno fraco, LLM consultado com baixa confiança | não usar em processos críticos; fila de baixa prioridade |
| `D_REVISAO_HUMANA` | condição crítica no cluster: complemento ambíguo, fuzzy ambíguo sem CEP validado, CEP que contradiz o endereço, concordância muito baixa de logradouro/número, sem sugestão — **ou** na linha: a sugestão troca o **número** desta linha, troca o **logradouro** sem respaldo (Correios/LLM), troca o **CEP** por outro não validado | revisão humana obrigatória |

Como funciona: o cluster começa no grau dado pelo score; cada regra de restrição impõe um **nível mínimo** (no
máximo B, no máximo C, ou D) e grava o motivo; o pior nível vence. Isso é feito em E7 (e refeito em E8 se o LLM
sobrescreveu). Em E9, três regras **por linha** podem rebaixar mais: elas comparam o que *aquela* linha dizia com a
sugestão — uma linha que tinha o número 123 e recebe 132 é um caso para gente olhar, mesmo que o cluster seja
confiável. Os limiares ficam em `LIMIAR_GRAU_ALTA` / `LIMIAR_GRAU_MEDIA`; as regras estão numa lista simples
dentro de `grau_certeza_cluster` e `regras_linha`, fáceis de estender.

> **Por que uma escala por regras e não só o score?** Porque um número esconde o *motivo*. "Score 72" não diz se o
> problema é um CEP não validado (tolerável) ou um número trocado (crítico). Regras nomeadas produzem uma fila de
> revisão que o time consegue priorizar por motivo, e permitem ajustar a política sem retreinar nada.

> **Por que "o pior vence"?** Porque, para revisão humana, o custo de um falso positivo (mandar para revisão algo
> que estava certo) é pequeno, e o custo de um falso negativo (aplicar automaticamente um endereço errado) é alto.

### 4.16 E8 — Fallback com LLM

Só com `USAR_LLM=True`. Seleciona até `LIMITE_LLM` clusters com score abaixo de `LIMIAR_CONFIANCA_PARA_LLM`
(os mais frequentes primeiro) e envia ao modelo: as variantes brutas (com a frequência de cada), os candidatos dos
Correios e a sugestão atual. Pede a resposta em **JSON com schema fixo** (logradouro, número, complemento, bairro,
cidade, UF, CEP, confiança 0–1, justificativa).

- Provedores: `anthropic` (SDK `anthropic`, `output_config.format` com o JSON Schema), `openai`/`azure_openai`/
  `databricks` (SDK `openai`, `response_format` json_schema com fallback para `json_object`) e `mock` (não chama
  API; ecoa a sugestão do pipeline — serve para testar o encanamento sem custo).
- Credencial: `dbutils.secrets` → variável de ambiente. Nunca no código.
- **Cache** em Delta por hash do prompt + modelo: reexecutar não paga de novo.
- Chamadas em paralelo (`ThreadPoolExecutor`) com retentativas e recuo exponencial.
- A resposta só sobrescreve a sugestão se `confianca ≥ LIMIAR_CONFIANCA_LLM`; então `metodo_sugestao = LLM`.
- **O prompt nunca contém o CPF** — só strings de endereço.

> **Por que o LLM é a última camada e em amostra?** Custo (cada chamada custa centavos; bilhões de linhas
> custariam milhões), latência (segundos por chamada) e não determinismo (a mesma pergunta pode ter respostas
> diferentes). Ele é excelente exatamente onde as regras falham: casos raros e bagunçados. Usá-lo só ali, com
> cache e com limiar de confiança, dá o melhor dos dois mundos. Para escalar, a célula tem o pseudocódigo com
> `ai_query()` do Databricks SQL, que chama o modelo de dentro do Spark sem loop no driver.

### 4.17 E9 — Saída final, métricas e checks

1. Relê a origem com **o mesmo escopo** de E1 e recalcula `hash_linha`.
2. Join com `_05b_clusters_consolidados` (linha → cluster) e com a sugestão por cluster.
3. Devolve as colunas originais **com os nomes originais**, as `<coluna>_sugestao` (também com os nomes
   originais + sufixo), `endereco_sugestao_completo`, `cluster_id`, `unidade`, `n_unidades_local`, contagens,
   `metodo_sugestao`, `score_confianca_sugestao`, `grau_certeza`, `requer_revisao_humana`, `motivos_revisao`,
   `concordancias`, `flags_sugestao` e `flag_alterou_<campo>` (compara cada original normalizado com a sugestão).
4. Grava `<prefixo>_final` (overwrite no lote 0, append nos demais, `CLUSTER BY idCPF`) e uma linha em
   `<prefixo>_metricas` com contagens, distribuição por método, % de linhas alteradas por campo e os
   **checks de uniformidade**:
   - `check_clusters_nao_uniformes`: clusters com mais de uma sugestão (tem de ser 0 por construção);
   - `check_sugestoes_iguais_em_clusters_distintos`: CPFs com dois clusters de sugestão idêntica (tem de ser 0
     depois de E7b).
5. Em modo sintético, compara com o gabarito: pureza dos clusters (nenhum cluster mistura dois endereços
   verdadeiros), completude (cada endereço verdadeiro em um só cluster) e acerto por campo.

> **Dica operacional:** rode E1 e E9 sobre a **mesma versão** da tabela de origem (ou fixe `VERSION AS OF` no
> Delta). E9 relê a origem; linhas novas que não passaram por E1 saem como `SEM_SUGESTAO`.

---

## 5. Por que a sugestão é uniforme entre as linhas do mesmo endereço

Vale repetir, porque é o requisito mais importante:

1. A sugestão **nunca** é calculada linha a linha. O caminho é linha → `hash_linha` → variante → `cluster_id` →
   **uma** sugestão por cluster → devolvida a cada linha pelo `cluster_id`.
2. Logo, dentro de um cluster, as colunas `_sugestao` são idênticas por construção. Só as `flag_alterou_*` mudam
   por linha (comparam cada original com a sugestão).
3. A única brecha seria o mesmo endereço em dois clusters. Contra isso: as 7 chaves de E6, a anexação das
   variantes sem número, a consolidação E7b (mesmo local sugerido ⇒ mesmo grupo, com as unidades refeitas) e os
   dois checks medidos em E9 e gravados em `_metricas`.
3b. O erro inverso — **fundir dois endereços diferentes** (dois apartamentos no mesmo prédio) — é evitado por E6b:
   complementos conflitantes nunca ficam no mesmo cluster, e linhas indecidíveis ficam marcadas em vez de
   receberem um complemento chutado.
4. Limite honesto: uma variante tão distorcida que nenhuma chave nem o fuzzy alcançam fica num cluster próprio,
   com score baixo — é o caso que o LLM de E8 foi desenhado para resolver, e que aparece na auditoria como
   `VARIANTE_UNICA` com score < 60.

---

## 6. Como o notebook foi testado

Não havia acesso à base real nem a um cluster Databricks durante o desenvolvimento. O teste foi feito assim:

1. Ambiente local com PySpark 4.1.3 (mesma linha do DBR 18) e Java 17.
2. As células foram executadas em sequência por um script, exatamente como no notebook, com
   `MODO_TESTE_SINTETICO=True` (300 CPFs, ~5.400 linhas, ~360 endereços verdadeiros, todas as patologias).
3. Resultados (versão final, com 66 CPFs tendo dois apartamentos no mesmo prédio): fusões indevidas entre linhas
   numeradas 0; pureza dos clusters 99,8 %; completude excluindo linhas ambíguas 99,3 %; acerto de CEP, logradouro,
   bairro, cidade e UF 100 %, número 99,7 %, complemento nas linhas não ambíguas 100 %; 8,5 % das linhas ficaram
   `COMPLEMENTO_AMBIGUO`. Distribuição do grau de certeza: cerca de 62 % `A_ALTA`, 29 % `B_MEDIA` (quase tudo por
   "prédio com 2+ unidades" e "número preenchido a partir do cluster", proporções exageradas no sintético), 8,5 %
   `D_REVISAO_HUMANA` (as linhas ambíguas). Com
   recência (`COL_DATA`) e com o provedor `mock` do LLM: mesmo comportamento, clusters sobrescritos pelo "LLM" com a
   flag `LLM_APLICADO`.
4. Teste de robustez de E7b: com 5 das 7 chaves de E6 desligadas, 63 grupos fragmentados foram fundidos, as
   unidades refeitas e os checks de uniformidade ficaram em 0.
5. O único "erro" residual encontrado é uma linha `S/N` de um endereço anexada ao cluster numerado de **outro**
   endereço do mesmo cliente na mesma rua (o gerador sorteou a mesma rua duas vezes). É a inferência documentada
   da anexação de S/N; por isso a linha recebe `NUMERO_PREENCHIDO_PELO_CLUSTER` e no máximo `B_MEDIA`.

O que **não** foi testado e merece atenção na primeira execução real: escrita Delta com `CLUSTER BY` (o ambiente
local não tem Delta), widgets do Databricks, `dbutils.secrets`, chamadas reais de LLM (só o `mock`), e a
distribuição real das patologias — as regras foram calibradas em dados sintéticos e nos exemplos que você deu.

---

## 7. Como operar

**Primeira execução (amostra):** `MODO_AMOSTRA=true`, `FRACAO_AMOSTRA=0.001`, `USAR_LLM=false`. Olhe:
- as listas de "não mapeados" (E2: tokens de complemento; E3: tipos dos Correios) → estenda os dicionários;
- a distribuição de `cep_origem` (E2) e o resumo da validação (E4: % CEP existe, % rua bate);
- a distribuição por método e score (E7);
- a amostra de auditoria (E9): 30 linhas de clusters com mais de uma variante, original × sugestão.

**Calibração:** `LIMIAR_SIM_LOGRADOURO` (0.80) e `LIMIAR_FUZZY_CORREIOS` (88). Subir = mais conservador (menos
correções, menos erros); descer = mais agressivo. Decida olhando 50–100 casos auditados.

**LLM:** ative com `LIMITE_LLM=500` e compare custo × quantos clusters realmente mudaram (`LLM_APLICADO`).

**Base completa:** `MODO_AMOSTRA=false`, `N_LOTES=10`, `LOTE_ATUAL=0` com todas as etapas (gera as dims dos
Correios), depois lotes 1–9 com `ETAPAS_A_EXECUTAR="E1,E2,E4,E5,E6,E7,E8,E9"`. Dimensionamento de referência:
20–40 workers de 8 cores por lote de ~1 bi de variantes; `N_PARTICOES_SHUFFLE` ≈ 2–3× o total de cores.

**Reexecução parcial:** quebrou em E6 → `ETAPAS_A_EXECUTAR="E6,E7,E8,E9"`. Mudou dicionário → a partir de E2 (ou
E3 se foi `MAPA_TIPOS_CORREIOS`).

**Trocar de tabelas (dev → prod):** preencha `AMBIENTES["prod"]` e mude `AMBIENTE_ATIVO`. `verificar_ambiente()`
avisa se algo não existir.

---

## 8. Erros comuns e como diagnosticar

| Sintoma | Causa provável | Onde olhar / o que fazer |
|---|---|---|
| `verificar_ambiente` lista coluna inexistente | nome real errado no bloco de ambiente | corrija o valor em `COLS_*` |
| `% CEP existe` muito baixo em E4 | `tb_correios` com CEP em formato diferente (ex.: com hífen numa coluna só) | veja `_dim_correios_cep`; ajuste a montagem de `cep8` em E3 |
| `LOGRADOURO_NAO_BATE_CEP` em massa numa cidade | `logradouro_correios` vem com tipo na frente ou só reduzido | confira `nome_log` × `nome_red_chave` em `_dim_correios_logradouro` |
| muitos `FUZZY_AMBIGUO` | ruas homônimas na cidade; limiar de margem alto | reduza `MARGEM_FUZZY` com cuidado, ou deixe para o LLM |
| muitos `CONSENSO_INTERNO` com score < 60 | ruas que não existem nos Correios (loteamentos novos) ou cidade escrita diferente | amplie `ALIASES_CIDADE`; verifique a versão do DNE |
| `numero` disputado (`concordancias.numero` < 0.6) | número embutido lido errado | veja as variantes do cluster; ajuste `RE_NUM_FIM`/`MARCADORES_NUMERO` |
| driver com `OutOfMemory` | `PERSISTIR_INTERMEDIARIOS=false` numa base grande (linhagem gigante) | ligue a persistência em Delta |
| job lento em E6 | shuffle com poucas partições | aumente `N_PARTICOES_SHUFFLE`; mais workers |
| `check_sugestoes_iguais_em_clusters_distintos` > 0 | E7b não rodou (etapa pulada) ou tabela `_05b` antiga | rode E7 de novo |
| uma célula "trava" por minutos sem stage progredindo | expressão Spark com crescimento exponencial (regra encadeada reutilizando a própria expressão duas vezes) | escreva regras como `greatest(base, regra1, regra2...)` ou materialize com `withColumn` a cada passo — ver comentários em `grau_certeza_cluster` e em E2 |
| muitas linhas `D_REVISAO_HUMANA` por `COMPLEMENTO_AMBIGUO` | clientes com 2+ unidades no mesmo prédio e linhas sem complemento | esperado; priorize pela frequência (`qtd_ocorrencias_cluster`) ou use o LLM nesses clusters |

---

## 9. Perguntas frequentes ("por que não…?")

**…usar pandas?** Pandas roda numa máquina só, em memória. 10 bi de linhas são terabytes.

**…fazer um join direto de tudo com os Correios por nome de rua?** Sem blocking, é produto cartesiano.
Com blocking e sobre consultas distintas (E5), o mesmo resultado custa uma fração.

**…comparar todas as variantes de um CPF entre si com rapidfuzz?** Dezenas de variantes ao quadrado, vezes
centenas de milhões de CPFs, em Python. As chaves de E6 dão o mesmo agrupamento em Spark nativo.

**…escolher a linha mais recente como "a certa"?** A mais recente também pode estar errada, e ela raramente tem
todos os campos. A recência entra como **peso** (`COL_DATA`), não como decisão.

**…confiar no CEP do cliente?** Você mesmo observou CEPs aleatórios. O CEP só é aceito quando a rua bate (ou é
CEP de localidade com município coerente); senão o fuzzy tenta recuperar e o bruto só entra como último recurso,
com a flag `CEP_SUGERIDO_NAO_VALIDADO`.

**…usar o LLM em tudo?** Custo, latência e não determinismo (seção 4.16).

**…uma sugestão por CPF em vez de por cluster?** Um CPF pode ter dois endereços legítimos (mudou de casa, ou tem
dois apartamentos no mesmo prédio). A saída é por endereço (cluster). A última célula do notebook tem o
pseudocódigo para escolher um por CPF, se você precisar.

**…e se o cliente tem dois apartamentos no mesmo prédio?** É exatamente o caso de E6b (seção 4.13b): rua, número
e CEP iguais viram o mesmo `grupo_local`, mas `APTO 45` e `APTO 46` conflitam e formam clusters distintos, cada um
com a sua sugestão. Linhas desse prédio sem complemento ficam num terceiro cluster, sem complemento sugerido e
com a flag `COMPLEMENTO_AMBIGUO`. O mesmo vale para bloco, torre, casa, sala, lote/quadra, km e frente/fundos.

**…por que as linhas sem complemento não vão para o apartamento mais frequente?** Porque seria um chute com
consequência real (correspondência entregue no apartamento errado). O processo prefere entregar "sei a rua, o
número e o CEP; não sei a unidade" a inventar. Se para o seu uso o chute for aceitável, é uma mudança pequena em
`resolver_unidades` (atribuir ao anchor de maior peso) — mas faça isso conscientemente.

**…por que Spark nativo mesmo quando o código fica mais longo?** Porque 10 bi de linhas transformam qualquer
ineficiência em dias de cluster. Cada regra escrita como expressão nativa roda em Scala nos workers; a mesma regra
em Python (UDF) custaria de 10 a 100× mais.

---

## 10. Mapa das tabelas geradas

| Sufixo | Conteúdo | Uso |
|---|---|---|
| `_01_variantes` | variantes distintas com contagem | reinício de E2 |
| `_02_normalizado` | variantes parseadas + chaves + flags | auditoria do parsing |
| `_dim_correios_cep`, `_dim_correios_logradouro` | Correios normalizados | compartilhadas entre lotes |
| `_03_validado` | variantes × CEP + score de qualidade | auditoria da validação |
| `_04_fuzzy_correios`, `_04b_variantes_enriquecidas` | resultado do fuzzy por consulta e por variante | auditoria do fuzzy |
| `_05_grupos_locais` | linha → grupo_local (E6, rua+número) | auditoria do nível 1 |
| `_05_clusters`, `_05b_clusters_consolidados` | linha → cluster (E6b, grupo_local#unidade) e após E7b | E9 usa a `_05b` |
| `_06a_sugestao_pass1`, `_06a_consolidacao` | 1ª eleição e mapa de fusões | auditoria de E7b |
| `_06_sugestao_cluster`, `_06b_sugestao_cluster_llm` | sugestão por cluster, antes/depois do LLM | E9 |
| `_07_llm_cache` | respostas do LLM por hash do prompt | economia em reexecuções |
| `_final` | saída: linhas originais + `_sugestao` + diagnóstico | consumo |
| `_metricas` | uma linha por execução | monitoramento |
