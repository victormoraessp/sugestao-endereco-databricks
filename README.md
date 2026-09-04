# Sugestão de endereço canônico por CPF (Databricks / PySpark) com apoio da base dos Correios

Notebook para bases de cadastro com bilhões de linhas de endereço: para cada linha, sugere o endereço "correto"
(canônico) a partir de todas as variantes que o mesmo cliente tem na base e da base de referência dos Correios,
devolvendo a tabela original mais as colunas `_sugestao`, o cluster do endereço, o score de confiança e as flags.

- Notebook: `sugestao_endereco_cadastro_databricks.ipynb` (DBR 18 LTS, Spark 4.1, Python 3.12)
- Explicação técnica completa (para quem vai manter/revisar): `EXPLICACAO_TECNICA.md`
- Entradas: `tb_endereco` (idCPF, logradouro, numero, complemento, bairro, cidade, uf, cep_parte1, cep_parte2) e `tb_correios`
- Saídas: `<prefixo>_final` (linhas originais + `_sugestao` + `grau_certeza` / `requer_revisao_humana` / `motivos_revisao`), `<prefixo>_metricas` e tabelas intermediárias por etapa
- Endereços diferentes no mesmo prédio (dois apartamentos, blocos, salas...) nunca são fundidos: clusters distintos por unidade
- Tudo que é nome de tabela/coluna/API fica numa única célula (`AMBIENTES` com blocos `dev`/`prod`)

Importe o `.ipynb` no Databricks (Workspace > Import), preencha o bloco de ambiente, ajuste os widgets e execute.
Para um smoke test sem dados reais, use `MODO_TESTE_SINTETICO=true`.

URLs raw (para download direto ou `wget`/`curl` no cluster):

    https://raw.githubusercontent.com/victormoraessp/sugestao-endereco-databricks/main/sugestao_endereco_cadastro_databricks.ipynb
    https://raw.githubusercontent.com/victormoraessp/sugestao-endereco-databricks/main/EXPLICACAO_TECNICA.md
