# Guia de leitura dos resultados

Este documento explica, bloco a bloco, o que cada teste do `vt_res_07_resumo_executivo` está tentando provar, qual premissa está por trás dele e como ler o número que ele produz. É a versão "explicando para um analista júnior" da metodologia completa, que está em [METODOLOGIA.md](METODOLOGIA.md).

Os números usados como exemplo aqui vêm de uma execução real do pacote, feita em 2026-09-09, sobre 308.321.817 envios de SMS analisados.

---

## Bloco A. O tamanho do campo de jogo

Antes de testar qualquer coisa, este bloco só mede o terreno: quanto do CRM o Golden Record consegue enxergar, e quanto espaço existe para ele fazer diferença. Nenhuma linha aqui testa uma hipótese, são só contagens e proporções que dão contexto para os blocos seguintes.

| Indicador | O que está sendo medido | Por que isso importa antes de qualquer teste | Resultado |
|---|---|---|---|
| Envios válidos analisados | Quantos disparos de SMS sobraram depois de limpar registros com status ambíguo ou telefone inválido | Define o tamanho real da base de trabalho | 308.321.817 envios |
| Cobertura do GR nos envios | De cada 100 disparos, quantos têm um CPF que existe no Golden Record | Se a cobertura fosse baixa, qualquer conclusão valeria para pouca gente | 77,10% |
| Cobertura do GR nos CPFs | De cada 100 clientes distintos, quantos têm telefone no Golden Record | Mesma pergunta, mas contando pessoas em vez de disparos | 63,86% |
| Envios em que o GR indicaria outro telefone | De cada 100 disparos com GR disponível, em quantos o número usado é diferente do recomendado | É o espaço em que o Golden Record pode, na prática, mudar algum resultado. Se fosse próximo de zero, não haveria nada para medir | 30,61% |
| Insucessos em que o GR indicaria outro telefone | De cada 100 SMS que falharam, em quantos o GR sugeriria um número diferente | Mostra o tamanho bruto da "oportunidade de recuperação" antes de qualquer ajuste estatístico | 66,89% |

**Leitura em uma frase:** o Golden Record enxerga a maior parte da base, e discorda do telefone usado hoje em quase um terço dos disparos, incluindo dois terços dos que falharam. Isso não prova que trocar o telefone ajudaria, só mostra que existe espaço relevante para investigar.

---

## Bloco B. A prova de que o telefone certo entrega mais

Esta é a parte central do pacote. A pergunta que este bloco responde é: **quando o SMS foi enviado exatamente para o telefone do Golden Record, ele chegou com mais frequência do que quando foi enviado para outro número?**

Como não foi possível fazer um teste A/B de verdade, esse bloco ataca a mesma pergunta de quatro jeitos diferentes, cada um fechando uma porta diferente para quem for questionar o resultado. A lógica por trás de cada teste é sempre a mesma: comparar um grupo "telefone igual ao GR" contra um grupo "telefone diferente do GR", e verificar se a diferença de entrega entre os dois é grande demais para ser coincidência.

| Teste | O que está sendo comparado | A dúvida cética que ele fecha | Resultado | Chance de ser coincidência |
|---|---|---|---|---|
| Comparação bruta | Todos os envios com telefone = GR contra todos com telefone ≠ GR, na base inteira | Ponto de partida. Ainda não descarta que os grupos sejam diferentes por outro motivo | 92,45% de entrega contra 65,43%, diferença de 27,02 p.p. | Menor que 1 em 10 mil |
| Controlada por campanha, CMH | A mesma comparação, mas feita separadamente dentro de cada uma das 5.504 campanhas, e depois somada | "Isso não é só uma campanha específica com público diferente puxando a média" | Diferença de 21,35 p.p., chance de entrega cerca de 5,16 vezes maior | Menor que 1 em 10 mil |
| Pareado por cliente, McNemar | O mesmo CPF, comparado com ele mesmo: uma vez recebeu SMS no telefone do GR, outra vez em outro número | "Isso não é porque o telefone do GR calha de estar associado a clientes mais fáceis de contatar" | Diferença de 23,04 p.p., com 4.084.000 clientes comparados consigo mesmos | Menor que 1 em 10 mil |
| Pareado por cliente e campanha | O mesmo CPF, na mesma campanha, recebendo SMS em dois números diferentes | Fecha as duas dúvidas ao mesmo tempo: mesma pessoa e mesma ação de disparo | Diferença de 12,72 p.p., com 1.521.230 pares avaliados | Menor que 1 em 10 mil |

### O que cada teste faz, em detalhe

**Comparação bruta.** A premissa aqui é simples: se o telefone do GR realmente ajuda a entrega, os SMS enviados para ele devem chegar mais que os enviados para outro número, olhando a base toda de uma vez. O método é o mais direto possível, uma divisão de sucesso por total em cada grupo, seguida de um teste estatístico que verifica se a diferença encontrada poderia ser só sorte de amostragem. A limitação deste teste é que ele não controla nada: se, por acaso, os clientes cujo telefone bate com o GR forem sistematicamente diferentes dos outros, por exemplo, cadastros mais recentes, essa diferença poderia estar contaminando o resultado.

**Controlada por campanha, CMH.** A premissa evolui: mesmo que campanhas diferentes tenham públicos e taxas de entrega de base diferentes, dentro de UMA MESMA campanha o público é parecido, porque é a mesma mensagem, o mesmo período, a mesma régua de disparo. O método, chamado Cochran-Mantel-Haenszel, refaz a comparação separadamente para cada uma das 5.504 campanhas, e só depois soma tudo, dando mais peso às campanhas maiores. Isso neutraliza qualquer diferença que exista entre campanhas, e o fato de o resultado continuar forte depois desse controle é uma evidência bem mais robusta que a comparação bruta.

**Pareado por cliente, McNemar.** A premissa muda de eixo: em vez de controlar por campanha, este teste controla pela PESSOA. Ele olha só para clientes que, em algum momento, receberam SMS no telefone do GR e, em outro momento, em um telefone diferente. Como é o mesmo CPF nos dois casos, qualquer característica fixa da pessoa, como região, idade de cadastro ou perfil de engajamento, é automaticamente igual nos dois lados da comparação. O que sobra para explicar a diferença é o telefone. O método conta quantas vezes só o telefone do GR entregou contra quantas vezes só o outro telefone entregou, e testa se esse placar é equilibrado demais para ser coincidência.

**Pareado por cliente e campanha.** Esta é a versão mais rigorosa do pacote inteiro. A premissa exige as duas coisas ao mesmo tempo: mesmo cliente E mesma campanha, com o único fator que muda sendo o telefone usado. É a comparação mais parecida com um experimento controlado que dá para montar sem fazer um A/B de verdade. O custo é que ela só existe quando o CRM realmente disparou para dois números do mesmo cliente dentro da mesma ação, então o volume de pares comparados é menor que nos outros testes, mas ainda assim é um teste válido, com 1,5 milhão de pares.

**Leitura em uma frase:** quatro métodos diferentes, controlando por coisas diferentes, chegaram a diferenças entre 12,72 e 27,02 pontos percentuais, todos apontando na mesma direção e todos com chance de ser coincidência menor que 1 em 10 mil. Quando testes que atacam ângulos diferentes concordam, a explicação alternativa fica muito mais difícil de sustentar.

---

## Bloco C. Isso se repete em todo lugar, ou é um resultado de sorte?

O Bloco B já provou que existe uma diferença real. O Bloco C existe para responder à pergunta seguinte, que qualquer pessoa cética vai fazer: **esse resultado é generalizado, ou é puxado por uma situação especial, como uma campanha gigante ou um jeito específico de comparar telefones?**

Cada linha deste bloco ataca uma dúvida específica, refazendo a análise principal de um jeito levemente diferente.

| Teste de robustez | A dúvida que ele ataca | Como ele ataca essa dúvida | Resultado | A dúvida se confirma? |
|---|---|---|---|---|
| Teste do sinal | "O resultado só existe por causa de uma ou duas campanhas enormes" | Ignora o tamanho de cada campanha e conta só: em quantas das 5.504 campanhas o telefone do GR entregou mais? | O GR venceu em 98,55% das campanhas, 5.421 vitórias contra 80 derrotas | Não. O efeito aparece em quase todas as campanhas, grandes e pequenas |
| Excluindo a maior campanha | "Tirando a campanha que mais pesa, o resultado desaparece" | Recalcula a diferença bruta removendo completamente a campanha de maior volume da base | Diferença de 27,55 p.p., praticamente igual ao resultado com todas as campanhas | Não. O resultado não depende dessa campanha específica |
| Regra exata de comparação | "A diferença é só um artefato de como os telefones foram comparados, tipo o nono dígito ou o código do país" | Refaz o teste exigindo que o número seja idêntico caractere por caractere, sem tolerar variação de formatação | Diferença de 26,21 p.p., muito próxima dos 27,02 p.p. da regra tolerante original | Não. A forma de comparar os números não está distorcendo a conclusão |
| Seleção, GR contra sem GR | "Os clientes que têm Golden Record já são diferentes dos que não têm, então o resultado pode não valer para todo mundo" | Compara a taxa de entrega geral de quem tem GR contra quem não tem, sem nem olhar qual telefone foi usado | Clientes com GR entregam 11,15 p.p. melhor, mesmo antes de considerar o telefone | Parcialmente. Não invalida o efeito do telefone, mas avisa que o resultado é mais forte para quem tem GR |

**Uma observação importante sobre a última linha:** ela não é um teste de robustez do mesmo tipo que as três primeiras. As três primeiras tentam derrubar a explicação "o telefone do GR entrega mais", e nenhuma conseguiu. A última linha não ataca essa explicação, ela avisa sobre até onde a conclusão pode ser esticada: o efeito foi medido só nos 63,86% de clientes que têm Golden Record, e esse grupo já é, de largada, um pouco mais fácil de alcançar do que o restante da base. Isso não invalida nada, só significa que estender a conclusão para os 36% de clientes sem GR é uma extrapolação, não uma medição direta.

**Leitura em uma frase:** o efeito resiste a três tentativas diferentes de derrubá-lo e vale com segurança para a maior parte da base, com uma ressalva honesta sobre os clientes que ainda não têm Golden Record.

---

## Bloco D. Quantos SMS a mais isso significa, na prática

Os blocos B e C provaram que existe um efeito real e generalizado. O Bloco D traduz esse efeito para a pergunta de negócio: **dos SMS que falharam, quantos teriam sido entregues se o telefone do Golden Record tivesse sido usado, e quanto disso sobra depois de descontar o risco de trocar números que já funcionam?**

Cada candidato a recuperação é um SMS que falhou e para o qual o GR indicaria outro número. Toda linha deste bloco calcula duas coisas: quantas recuperações esse cenário estima, e quantas perdas ele estima, porque trocar para o telefone do GR também significa abandonar alguns números que já funcionavam. O saldo líquido é a diferença entre as duas. O que muda de um cenário para o outro é só a fonte da taxa de sucesso usada na conta, cada uma com uma premissa diferente por trás.

| Cenário | A premissa por trás | De onde vem a taxa de sucesso usada | Recuperadas | Perdidas | Saldo líquido |
|---|---|---|---|---|---|
| Teto | Se o telefone do GR sempre funcionasse, sem exceção | Suposição de 100% de sucesso, a premissa que foi pedida explicitamente como limite superior | 25.154.677 | 0 | 25.154.677 |
| Calibrado, taxa geral | A taxa real observada no telefone do GR, medida em toda a base, prevê o comportamento futuro | Taxa de entrega média do braço concordante em toda a base, medida no Bloco B | 23.256.184 | 3.592.904 | 19.663.280 |
| Calibrado por campanha | A mesma ideia, mas respeitando que campanhas diferentes têm taxas diferentes | Taxa de entrega do braço concordante dentro da MESMA campanha do SMS específico | 23.241.345 | 3.413.514 | 19.827.830 |
| Evidência direta extrapolada | O histórico real de cada cliente específico com o telefone do GR é o melhor previsor | Taxa de sucesso medida só nos clientes cujo telefone do GR já foi de fato tentado em alguma campanha | 16.976.452 | 20.060.205 | -3.083.753 |
| Piso, evidência comprovada | Só contar o que já é fato, sem nenhuma extrapolação | Nenhuma. Conta só os casos em que o telefone do GR já foi testado para aquele cliente E comprovadamente entregou | 4.769.954 | 4.106.383 | 663.571 |

### O que cada cenário faz, em detalhe

**Teto.** Não é uma estimativa, é um limite matemático. Responde à pergunta "qual o ganho máximo imaginável, se a premissa mais otimista fosse verdadeira?" Não desconta perdas porque, dentro dessa mesma premissa, trocar de telefone nunca daria errado. Deve sempre aparecer ao lado dos outros cenários, nunca sozinho, porque a premissa por trás dele é sabidamente exagerada.

**Calibrado pela taxa geral.** Troca a suposição de 100% por um número medido de verdade: a taxa de entrega que o telefone do GR realmente teve, olhando todos os envios concordantes da base inteira. É mais honesto que o teto, mas ainda mistura campanhas com contextos muito diferentes numa média só.

**Calibrado por campanha.** Refina o anterior usando a taxa de sucesso medida especificamente dentro da campanha de cada SMS, e só recorre à média geral quando aquela campanha não tem nenhum envio concordante para medir. Como compara o candidato com o que aconteceu no mesmo contexto, é o número mais defensável para usar como estimativa central do valuation.

**Evidência direta extrapolada.** Em vez de uma taxa de campanha, usa o histórico real do próprio número do GR, cliente por cliente, olhando só quem já teve esse número testado pelo CRM alguma vez. É a forma mais rigorosa de calibrar a taxa, porque vem de fatos concretos, não de médias de grupo. O resultado negativo aqui é o achado mais importante do bloco inteiro: sugere que os clientes cujo telefone do GR já foi tentado antes podem ser um grupo sistematicamente mais difícil, talvez porque só se tenta um número alternativo quando o cliente já deu trabalho antes. Isso é um alerta para investigar, não um erro de conta.

**Piso.** Não estima nada, só soma o que já é fato registrado: candidatos cujo telefone do GR já foi usado noutra campanha e comprovadamente entregou, contra sucessos cujo telefone do GR já foi usado e comprovadamente falhou. É o número mais difícil de contestar, porque não depende de nenhuma suposição estatística, mas também é o mais incompleto, já que ignora todo cliente cujo telefone do GR nunca foi testado.

**Leitura em uma frase:** use o cenário calibrado por campanha como estimativa central para o valuation, o teto e o piso como os limites otimista e conservador da faixa, e trate o resultado negativo da evidência direta como um convite para investigar se existe um subgrupo de clientes mais difíceis antes de assumir o número calibrado como certo.

---

## Como as evidências se encaixam

| Bloco | Pergunta que responde | Tipo de raciocínio |
|---|---|---|
| A | Quanto do CRM o GR alcança, e quanto espaço existe para ele mudar algo? | Descritivo, sem teste de hipótese |
| B | O telefone do GR realmente entrega mais, e isso não é coincidência? | Causal, quatro testes independentes |
| C | Esse efeito é generalizado, ou concentrado em um caso especial? | Robustez do achado do Bloco B |
| D | Quantas entregas a mais isso significa, em número absoluto? | Estimativa de impacto, com faixa de cenários |

O fio condutor é: A mostra que existe espaço para o problema importar, B prova que o telefone certo faz diferença, C garante que essa prova não é um acidente estatístico, e D traduz tudo isso em um número que alimenta o valuation.
