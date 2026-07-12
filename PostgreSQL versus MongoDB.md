  
PostgreSQL versus MongoDB: Benchmark de Desempenho sob Diferentes Cenários de Indexação e Cargas de Trabalho

**¹Felipe Pires Rocha, ¹Victor Franco Martins.**  
¹Instituto de Matemática e Estatística, Universidade de São Paulo, São Paulo, 2026\.  
felipepiresrocha@ime.usp.br, victorf.martins@usp.br 

***Abstract**. This work compares the performance of PostgreSQL and MongoDB, evaluating the impact of data modeling (normalized vs. denormalized) and indexing. Using the Stack Overflow 2010 dataset (Posts, Comments, Users), three instances were created: PostgreSQL (PG), MongoDB mirroring the relational model (mongo\_ref), and MongoDB with denormalized data in nested documents (mongo\_emb). A benchmark of 12 tasks (point lookups, filters, text searches, aggregations, and write operations) was executed on each instance, with and without indexes. Without indexes, the MongoDB models outperform PostgreSQL on filtered reads, with the embedded model standing out for traversing fewer documents. With indexes, all three systems converge to sub-millisecond times. For infix text searches, PostgreSQL performs better because MongoDB's multikey index is less effective for nested documents. The most striking finding is the reconstruction of hierarchical structures: the embedded model is about 24,000 times faster than the normalized models. In distributed bulk writes, on the other hand, MongoDB's referenced model stands out, while the embedded model is penalized. We conclude that the application's predominant access pattern should guide the choice of data model.*

***Keywords**: PostgreSQL, MongoDB, performance benchmark, data modeling, indexing.*

***Resumo**. Este trabalho compara o desempenho de PostgreSQL e MongoDB, avaliando o impacto da modelagem de dados (normalizada vs. desnormalizada) e do uso de índices. A partir do dataset Stack Overflow 2010 (Posts, Comments, Users), foram criadas três instâncias: PostgreSQL (PG), MongoDB espelhando o modelo relacional (mongo\_ref) e MongoDB com dados desnormalizados em documentos aninhados (mongo\_emb). Um benchmark de 12 tarefas (buscas pontuais, filtros, buscas textuais, agregações e operações de escrita) foi executado em cada instância, com e sem índices. Sem índices, os modelos MongoDB superam o PostgreSQL em leituras filtradas, com o modelo embutido se destacando por percorrer menos documentos. Com índices, os três sistemas convergem para tempos em submilissegundos. Em buscas textuais infixas, o PostgreSQL é superior, pois o índice multikey do MongoDB perde eficácia com documentos aninhados. O achado mais expressivo é a reconstrução de estruturas hierárquicas: o modelo embutido é cerca de 24.000 vezes mais rápido do que os modelos normalizados. Já em escritas em massa distribuídas, o modelo referenciado do MongoDB se destaca, enquanto o embutido é penalizado. Conclui-se que a escolha do modelo deve considerar o padrão de acesso predominante da aplicação.*

***Palavras-chave:** PostgreSQL, MongoDB, benchmark de desempenho, modelagem de dados, indexação.*

1. # Introdução

Atualmente, a preservação e a recuperação eficientes de informações digitais tornaram-se essenciais para o funcionamento contínuo de sistemas corporativos, plataformas *web* e aplicações pessoais. Essa necessidade de organização estruturada fundamenta e motiva a existência dos bancos de dados. Segundo Elmasri e Navathe (2011, p.2-3), tais sistemas desempenham um papel central em praticamente todas as áreas de aplicação da computação, da medicina ao comércio eletrônico, o que evidencia sua relevância transversal para as infraestruturas de informação modernas.

Visto que um banco de dados funciona essencialmente como um repositório de informações, ele não possui capacidade de autogerenciamento. Torna-se, portanto, indispensável a presença de uma camada de *software* dedicada à sua manipulação. De acordo com a IBM (2010), um Sistema Gerenciador de Banco de Dados (SGBD) é uma solução computadorizada responsável por armazenar dados e oferecer mecanismos para sua manipulação, abrangendo tanto os registros informacionais quanto a própria estrutura lógica do banco de dados.

Conforme aponta o *ranking* do *DB-Engines* (2026), que mensura a popularidade de SGBDs com base em métricas como menções na *web*, frequência de buscas e discussões em redes profissionais, os sistemas mais utilizados no mercado incluem Oracle, MySQL, Microsoft SQL Server, PostgreSQL e MongoDB. Esse cenário evidencia a coexistência e a relevância de diferentes paradigmas arquiteturais na indústria tecnológica.

O modelo SQL (*Structured Query Language*), associado ao paradigma relacional, baseia-se em uma estrutura rígida composta por tabelas, esquemas fixos e aplicação de regras de normalização para garantir a integridade dos dados. Em contrapartida, o modelo NoSQL (*Not Only SQL*) caracteriza-se por uma abordagem em que os dados possuem uma estrutura flexível e dinâmica, dispensando esquemas rígidos globais para priorizar a escalabilidade e a adaptabilidade. 

O objetivo deste artigo é apresentar uma análise comparativa de desempenho entre bancos de dados SQL e NoSQL, avaliando o impacto de diferentes estratégias de modelagem de dados, normalizadas e desnormalizadas, bem como do uso de índices em operações típicas de leitura e escrita. Para representar o modelo SQL, selecionou-se o PostgreSQL, enquanto o MongoDB foi o sistema escolhido para representar o paradigma NoSQL. A comparação é motivada por um cenário comum em aplicações web que armazenam dados naturalmente hierárquicos, como fóruns de discussão, a exemplo do *Stack Overflow*, utilizado como base de dados deste estudo, nos quais a escolha entre normalização e desnormalização impacta diretamente o desempenho das operações de leitura e escrita.

O presente trabalho está estruturado em cinco seções, além desta introdução. A seção 2 apresenta as definições teóricas fundamentais das tecnologias estudadas. A seção 3 descreve o ambiente de testes, o dataset utilizado, a metodologia de coleta de dados e as tarefas que compõem o benchmark. A seção 4 apresenta a análise comparativa detalhada dos dados coletados, incluindo o desempenho de leitura e de escrita, o custo de armazenamento e o tempo de criação de índices. A seção 5 discute os resultados sob uma perspectiva conceitual, abordando flexibilidade de esquema, paradigmas de manipulação de dados e garantias transacionais. Por fim, a seção 6 apresenta as conclusões do estudo.

2. # Referencial Teórico

# Para promover a compreensão deste trabalho, esta seção apresenta o embasamento conceitual das tecnologias e dos paradigmas estudados.

1. ## **Sistemas de Gerenciamento de Banco de Dados (SGBDs)**

# Os Sistemas Gerenciadores de Banco de Dados surgiram na década de 1960 como resposta à crescente necessidade de organizar e manipular grandes volumes de dados de forma eficiente e confiável. Antes de sua consolidação, as aplicações armazenavam informações diretamente em arquivos de texto ou binários, o que frequentemente resultava em redundância, inconsistência e dificuldade de manutenção dos dados (ELMASRI; NAVATHE, 2011, p. 15). Como resposta a essas limitações, a IBM lançou, em 1966, o IMS (*Information Management System*), considerado um dos primeiros SGBDs comerciais, baseado no modelo hierárquico de organização de dados (IBM, 2026). Ao longo das décadas seguintes, os modelos evoluíram progressivamente, culminando nos paradigmas relacionais e não relacionais amplamente adotados atualmente.

2. ## **Bancos de Dados Relacionais (SQL)**

O modelo relacional de banco de dados organiza as informações em tabelas compostas por linhas e colunas, permitindo o estabelecimento de relacionamentos entre tabelas por meio de chaves primárias e estrangeiras (DATE, 2004, cap. 3.2). Esse modelo foi proposto por Edgar F. Codd em 1970, sob a premissa de que os usuários deveriam ser protegidos de ter que conhecer a organização física dos dados na máquina (CODD, 1970, p. 377). A partir disso, o modelo tornou-se o paradigma dominante para aplicações que exigem confiabilidade, integridade e consistência transacional. A comunicação com bancos de dados relacionais é realizada por meio da linguagem SQL (Structured Query Language), utilizada para definir estruturas, consultar, manipular e controlar os dados armazenados.

3. ##  **Bancos de Dados Não Relacionais (NoSQL)**

# Os bancos de dados não relacionais, conhecidos como NoSQL (Not Only SQL), surgiram como alternativa aos modelos relacionais tradicionais, especialmente diante das demandas por escalabilidade e flexibilidade impostas por aplicações modernas que lidam com grandes volumes de dados heterogêneos (PANIZ, 2016, cap. 1.2). Diferentemente do modelo relacional, os sistemas NoSQL não impõem um esquema rígido e predefinido, permitindo que os dados sejam armazenados em diferentes estruturas, como documentos, pares chave-valor, colunas amplas ou grafos, de acordo com as necessidades da aplicação.

4. **Normalização/Desnormalização**

A normalização é o processo de organizar os atributos e as tabelas de um banco de dados relacional segundo um conjunto de regras formais, as formas normais,  propostas originalmente também por Codd (1970) como parte do próprio modelo relacional. Seu objetivo é eliminar redundâncias e anomalias de inserção, atualização e exclusão, decompondo tabelas maiores em relações menores conectadas por chaves estrangeiras, de modo que cada fato seja armazenado apenas uma vez (DATE, 2004, cap. 12.1). O ganho em integridade, porém, tem um custo: consultas que precisam reunir informações espalhadas em várias tabelas normalizadas dependem de operações de junção (joins), que se tornam mais custosas à medida que o volume de dados cresce.

A desnormalização parte do caminho inverso. Trata-se de reintroduzir redundância deliberadamente no esquema físico, incorporando dados relacionados em uma mesma estrutura para evitar joins em tempo de consulta (DATE, 2004, cap. 13.5). Essa prática é particularmente comum em bancos orientados a documentos, como o MongoDB, nos quais entidades relacionadas podem ser embutidas diretamente como subdocumentos ou arrays em um único registro. O compromisso é claro: ganha-se desempenho de leitura às custas de maior espaço em disco e de um controle mais rígido sobre a consistência dos dados duplicados, que passam a exigir atualização em múltiplos pontos sempre que um valor redundante muda.

5. **Indexação em Bancos de Dados**

Um índice é uma estrutura de dados auxiliar que associa valores de um ou mais atributos aos endereços físicos dos registros correspondentes, permitindo que o SGBD localize informações sem precisar varrer a tabela ou a coleção inteira (ELMASRI; NAVATHE, 2011, p. 424-452). Na ausência de índices, qualquer consulta que filtre por um atributo não indexado obriga o motor a inspecionar cada registro individualmente, o chamado table scan (ou collection scan, no MongoDB), cujo custo cresce linearmente com o volume de dados armazenados.

O tipo de índice mais difundido em bancos relacionais é a árvore B (B-tree), eficiente tanto para buscas por igualdade quanto por intervalo, pois mantém as chaves ordenadas. O MongoDB reutiliza essa mesma estrutura internamente, mas oferece variações adaptadas ao modelo de documentos, como os índices multikey, capazes de indexar valores contidos em arrays, e os índices de texto, voltados à busca por palavras-chave em campos textuais.

Apesar de acelerar as leituras, um índice não é gratuito: toda vez que um registro é inserido, removido ou tem um campo indexado alterado, o SGBD também precisa atualizar as estruturas de índice correspondentes, o que adiciona overhead às operações de escrita. Por isso, a decisão de indexar um atributo é sempre um equilíbrio entre o ganho esperado nas consultas de leitura e o custo adicional imposto às operações de escrita, equilíbrio que este trabalho explora diretamente ao comparar cenários com e sem índices.

6. ## **PostgreSQL**

# O PostgreSQL é um SGBD relacional de código aberto, lançado em 1996 como evolução do projeto POSTGRES, desenvolvido na década de 1980 por Michael Stonebraker na Universidade da Califórnia em Berkeley (THE POSTGRESQL GLOBAL DEVELOPMENT GROUP, 2026). O sistema organiza os dados em tabelas relacionadas e utiliza SQL como linguagem principal para manipulação de dados. Entre seus principais recursos, destacam-se o suporte a transações ACID, o controle de concorrência por multiversão (MVCC), a extensibilidade por meio de tipos e funções personalizadas e o suporte nativo a dados semiestruturados no formato JSON.

7. ## **MongoDB**

# O MongoDB é um SGBD NoSQL orientado a documentos, projetado para armazenar grandes volumes de dados de forma flexível e escalável (MONGODB, 2026). Em vez de tabelas e linhas, o sistema organiza os dados em coleções compostas por documentos no formato BSON (Binary JSON), uma representação binária do JSON que suporta tipos de dados adicionais. Sua principal característica é a ausência de um esquema fixo, o que permite que documentos de uma mesma coleção possuam estruturas distintas, conferindo agilidade ao desenvolvimento e facilidade de adaptação a mudanças nos requisitos da aplicação  (BRADSHAW; BRAZIL; CHODOROW, 2019).

8. ACID

# O acrônimo ACID resume as quatro propriedades que uma transação deve satisfazer para ser considerada confiável em um sistema de banco de dados: atomicidade, consistência, isolamento e durabilidade (DATE, 2004, cap. 16.10). A atomicidade garante que uma transação seja executada por completo ou não seja executada de forma alguma, de modo que falhas no meio da operação não deixem o banco de dados em um estado parcialmente modificado. A consistência assegura que a transação leve o banco de um estado válido a outro, respeitando todas as restrições de integridade definidas no esquema. O isolamento garante que transações concorrentes não interfiram entre si, como se cada uma fosse executada isoladamente, ainda que, na prática, sejam intercaladas pelo escalonador do SGBD. Por fim, a durabilidade garante que, uma vez confirmada (commit), uma transação sobreviva a falhas subsequentes do sistema, permanecendo registrada de forma persistente.

# O PostgreSQL implementa as quatro propriedades de forma nativa e abrangente, permitindo que uma transação delimitada por um bloco BEGIN...COMMIT envolva múltiplas tabelas e comandos, sem que o escopo de atomicidade fique restrito a um único registro. O MongoDB, por sua vez, garante atomicidade de forma nativa apenas no nível de um único documento: qualquer operação que modifique campos e subdocumentos dentro de um mesmo documento é atômica por padrão, mas transações que abrangem múltiplos documentos ou coleções exigem o uso explícito de sessões transacionais, recurso introduzido apenas nas versões mais recentes do sistema e cujo funcionamento pressupõe uma topologia de replica set. Essa diferença estrutural entre os dois sistemas é retomada na discussão dos resultados deste trabalho, na qual se avalia como a modelagem de dados adotada em cada instância do MongoDB interage com os limites de atomicidade impostos pelo motor.

3. # Metodologia

Esta seção descreve os procedimentos metodológicos adotados para avaliar e comparar o desempenho do PostgreSQL e do MongoDB.

1. ## **Ambiente de Testes (hardware, software, versões)**

Para garantir a consistência das coletas, todos os experimentos foram executados de forma centralizada em uma única máquina de trabalho. As especificações de *hardware* e *software* utilizadas são detalhadas a seguir:

* **CPU:** Apple M4 (10 núcleos);  
* **Memória RAM:** 16 GB;  
* **Sistema Operacional**: macOS 26.5.1 (Darwin 25.5);  
* **Disco**: SSD (APFS);  
* **PostgreSQL**: 18.3,  configurado com *shared\_buffers* \= 128MB e *track\_io\_timing*\=on;  
* **MongoDB**: 8.3.4 (Community Edition), utilizando o motor de armazenamento *WiredTiger*, alocação de *cache* de aproximadamente 3,5 GB, operando em modo *standalone;*  
* **Cliente Mongo**: *mongosh*  versão 2.8.3.

Por se tratar de uma única máquina compartilhada entre os dois SGBDs, algumas precauções foram adotadas para reduzir a interferência entre os testes: ambos os serviços permaneciam ativos simultaneamente, mas apenas um deles recebia carga de cada vez. Processos de segundo plano não essenciais foram minimizados durante a execução dos testes. 

2. ## **Dataset Utilizado**

O *dataset* base deste trabalho foi o *Stack Overflow* 2010, mais especificamente as tabelas Posts, Comments e Users, nas quais os dados estão normalizados em uma estrutura típica de bancos de dados relacionais. A tabela 1 resume a escala do dataset original:

Tabela 1: Escala e volumetria do dataset do *Stack Overflow* (2010).

| Entidade | PostgreSQL | MongoDB ref. | MongoDB emb. |
| :---- | ----- | :---- | :---- |
| Users | 299.398 | 299.398 (users) | desnormalizado em owner/user |
| Posts | 3.245.976 | 3.245.976 (posts) | 965.354 perguntas \+ 2.280.103 respostas embutidas |
| Comments | 3.399.536 | 3.399.536 (comments) | 3.399.536 (908.288 em perguntas \+ 2.491.248 em respostas) |

Fonte: elaborada pelos autores.

A escolha desta base justifica-se  por apresentar uma volumetria e complexidade representativas de aplicações do mundo real, mantendo-se, ao mesmo tempo, tratável para execuções e coletas controladas em ambiente local.   
Para viabilizar a análise comparativa entre as arquiteturas, foram derivadas três instâncias do *dataset*:

1. PostgreSQL (PG): Modelo relacional original, mantendo a estrutura normalizada em três tabelas.  
2. MongoDB Referência (*mongo\_ref* ou modelo R): Cópia direta das três tabelas originais para coleções equivalentes no MongoDB, desconsiderando as restrições de integridade referencial (chaves estrangeiras). Esta instância funciona como um espelho do modelo relacional, isolando a avaliação estritamente do comportamento dos motores de execução.  
3. MongoDB Embutido (*mongo\_emb* ou Modelo E): Instância desnormalizada que aproveita a flexibilidade do modelo de documentos. Cada registro da tabela *Posts,arrays,* categorizado como pergunta, deu origem a um documento raiz no qual foram incorporados, via subdocumentos e *arrays*) Os seus respectivos comentários, as suas respostas e, hierarquicamente, os comentários associados a cada resposta.

Os testes de *benchmarking* foram aplicados a cada uma dessas três instâncias em dois cenários distintos: sem índices e com índices. Dessa forma, os resultados apresentados comparam o desempenho de cada uma das seis configurações. Cada teste do benchmark, de codinome T1 a T12, foi executado para cada configuração do *dataset*.

3. ## **Métricas de Avaliação**

O desempenho e a eficiência estrutural foram quantificados por meio de três métricas principais:

* O tamanho de cada instância do *dataset* nas configurações com e sem índice.  
* O tempo de criação dos índices.  
* O tempo de execução dos testes (consultas).

  4. ## **Procedimentos de Coleta de Dados**

A coleta de dados foi padronizada e automatizada por meio de código. Cada teste do *benchmark* foi gerenciado por uma função controladora denominada *run\_benchmark()*, a qual executou o seguinte ciclo:

1. Criação de dependências necessárias para o teste;  
2. Realização  do *warmup* do cache executando o teste 5 vezes;  
3. Execução de 20 repetições adicionais medindo o tempo de cada uma;  
4. Remoção das dependências e dos produtos gerados pelo teste, devolvendo o fluxo ao programa principal. 

O número de repetições de aquecimento (N \= 5\) e de medição (N \= 20\) foi definido de forma empírica, após a observação prévia de que a variância dos tempos de resposta decrescia e atingia estabilização a partir da N-ésima execução. Para mitigar o viés do "vazamento de *cache*" (*cache bleeding*) entre arquiteturas diferentes, os *caches* internos dos SGBDs eram explicitamente limpos a cada alternância entre os sistemas testados. O isolamento foi mantido ao garantir a ausência de cargas de trabalho concorrentes ou paralelas durante os experimentos.

Adicionalmente, os tempos de criação de índices foram coletados isoladamente por meio da função *create\_index\_timed().* Para fins de análise qualitativa, os planos de execução de cada consulta foram extraídos e persistidos pela função *save\_explain()*, utilizando as diretivas EXPLAIN ANALYZE no PostgreSQL e *.explain("executionStats")* no MongoDB.

5. ## **Carga de Trabalho e Justiça**

A carga de trabalho foi projetada para cobrir os principais padrões de acesso e de manipulação de dados observados em aplicações produtivas cotidianas. O benchmark é composto por 12 tarefas centrais (codificadas de T1 a T12, divididas em subconsultas quando necessário), que avaliam o comportamento do sistema sob perfis de leitura seletiva, leitura analítica e escrita em diferentes escalas.

A caracterização das tarefas compreende um espectro diversificado de operações, estruturadas de modo a refletir diferentes demandas de carga de trabalho. No escopo da leitura seletiva e da busca, foram avaliadas a busca pontual por chave primária ou identificador único (T1), a busca por igualdade de atributos (T2) e a busca por intervalo de valores (T3). Adicionalmente, os aspectos de ordenação e processamento de texto foram contemplados por meio de ordenação combinada com limite de paginação (*top-N*) (T4), além de consultas textuais por correspondência de prefixo (T5a) e de infixo ou subcadeia (T5b).

Para a avaliação de operações analíticas e de maior complexidade relacional, o *benchmark* inclui rotinas de agregação multi-tabela ou multi-coleção (T6a), junções complexas associadas a cortes *top-N* (T6b) e o agrupamento de dados com a aplicação de funções agregadas (T7).

Por fim, as operações de modificação do estado da base de dados foram divididas em manipulações localizadas e volumosas. O primeiro grupo engloba a inserção unitária de registros (T8) e a atualização de dados, tanto em campos indexados (T10b) quanto em não indexados (T10a). O segundo grupo valida o comportamento dos motores em cenários de escrita em lote (*bulk insert*) (T9), remoção por chave primária (T11a) ou por critérios de coluna (T11b) e, de forma mais rigorosa, operações massivas que executam a inserção, atualização e deleção simultâneas sobre um bloco de 100 mil registros (T12a, T12b e T12c).

A fim de garantir a isonomia (justiça) na comparação, todas as tarefas foram codificadas de forma idiomática, respeitando as melhores práticas e os paradigmas nativos de cada tecnologia. Utilizou-se a linguagem SQL no PostgreSQL e instruções JavaScript estruturadas no MongoDB, preterindo traduções literais de sintaxe que pudessem penalizar artificialmente o desempenho de um dos motores. Por fim, o resultado de todas as consultas foi encapsulado em uma função de contagem (*counter*), minimizando o impacto do tempo de transporte e de serialização na rede sobre a métrica de tempo de execução de fim a fim do SGBD.

## **3.6. Disponibilidade de Dados e Código**

O código-fonte utilizado para a criação das instâncias do *dataset*, a execução dos benchmarks e a coleta das métricas apresentadas neste trabalho está disponível publicamente em LINK AQUI. O repositório inclui os scripts de carga de dados, as implementações de cada uma das 12 tarefas (T1–T12) em SQL e JavaScript, bem como as funções de instrumentação (*run\_benchmark(), create\_index\_timed(), save\_explain()*) descritas na Seção 3.4.

4. # Análise Comparativa dos Resultados

Esta seção apresenta e discute os resultados obtidos a partir dos experimentos práticos realizados nas seis configurações dos bancos de dados, avaliando métricas de tempo de execução, custo de armazenamento e tempo de criação de índices.

## **4.1. Análise de Desempenho da Carga de Trabalho (Benchmark)**

A Tabela 2 apresenta os tempos médios de execução de cada tarefa, medidos em milissegundos após 20 repetições em regime de cache aquecido (*warm cache*), organizados segundo os cenários sem índice (*s)* e com índice (*c*) para as três instâncias avaliadas (*pg, ref e emb*).

Tabela 2: Tempo médio de execução por tarefa e por cenário.

| Tarefa | pg\_s | ref\_s | emb\_s | pg\_c | ref\_c | emb\_c |
| :---- | ----- | ----- | ----- | ----- | ----- | ----- |
| T1 busca por PK/\_id | 0,02 | 0,40 | 0,75 | 0,02 | 0,53 | 0,40 |
| T2 igualdade (autor) | 1.397,82 | 605,45 | 387,49 | 0,07 | 1,74 | 0,32 |
| T3 intervalo de data | 1.566,78 | 663,57 | 297,07 | 32,93 | 60,91 | 12,02 |
| T4 top-N por score | 1.796,41 | 669,16 | 316,94 | 0,02 | 0,69 | 0,68 |
| T5a texto prefixo (LIKE 'I %') | 679,83 | 743,77 | 2.666,08 | 64,37 | 287,00 | 1.963,78 |
| T5b texto infixo (%error%) | 501,27 | 1.860,52 | 3.010,22 | 352,65 | 2.528,09 | 5.147,40 |
| T6a agregado (perg.+resp.+com.) | 9.605,22 | 10.821,31 | 0,40 | 0,12 | 1,54 | 0,45 |
| T6b junção top-N \+ autor | 1.739,06 | 739,81 | 331,47 | 0,07 | 0,98 | 0,30 |
| T7 agregação por grupo | 1.160,69 | 1.025,93 | 2.362,24 | 1.470,05 | 2.618,05 | 2.066,38 |
| T8 insert unitário | 0,15 | 0,25 | 0,48 | 0,16 | 0,35 | 0,55 |
| T9 insert em lote (1.000) | 42,64 | 5,09 | 37,44 | 64,45 | 5,46 | 75,47 |
| T10a update col. não indexada | 1.183,83 | 596,32 | 476,36 | 0,02 | 0,23 | 0,43 |
| T10b update col. indexada | 1.086,77 | 619,77 | 448,13 | 0,02 | 0,19 | 0,27 |
| T11a delete por PK | 0,02 | 0,19 | 0,23 | 0,01 | 0,13 | 0,24 |
| T11b delete por coluna | 1.309,00 | 624,03 | 421,79 | 0,01 | 0,15 | 0,26 |
| T12a massa insert 100k | 1.296,05 | 196,53 | 5.894,72 | 1.446,84 | 327,49 | 6.782,73 |
| T12b massa update 100k | 2.755,85 | 841,23 | 1.150,77 | 1.865,94 | 364,39 | 781,74 |
| T12c massa delete 100k | 301,88 | 739,10 | 2.414,11 | 94,07 | 352,98 | 3.923,16 |

Fonte: elaborada pelos autores.

No cenário sem índice, observa-se uma vantagem nas duas instâncias do MongoDB em relação ao PostgreSQL ao executar varreduras filtradas. Esse comportamento decorre da eficiência do motor de armazenamento *WiredTiger,* que realiza a varredura diretamente nos blocos comprimidos no disco, reduzindo a necessidade de operações de entrada e saída lógicas. Além disso, o modelo embutido percorre muito menos documentos, cerca de 3,4 vezes menos, o que representa um grande ganho. Por exemplo, ele precisa percorrer apenas 965 mil perguntas, em vez de 3,2 milhões de posts. Por outro lado, quando os índices secundários são introduzidos (cenário c), os três bancos de dados se aproximam em termos de desempenho, com tempos de resposta inferiores a 1 milissegundo. Nesse contexto,  o PostgreSQL tem uma vantagem muito pequena, especialmente no acesso a pontos específicos de dados, devido ao uso de índices B-tree e ao armazenamento em *cache*.

Ao contrário do cenário anterior, as buscas textuais revelaram predominância do PostgreSQL em ambas as configurações. Na busca por correspondência de prefixo (T5a), o uso do índice acelerou a execução no PostgreSQL de 679,83 ms para 64,37 ms. No MongoDB, a mesma busca via expressões regulares exigiu 287,00 ms na instância de referência e estendeu-se para 1.963,78 ms no modelo embutido. Essa penalidade no modelo embutido acentua-se na busca por infixo (T5b) e é explicada pela dispersão do texto em múltiplos níveis hierárquicos aninhados (estruturados em propriedades como *comentarios.text* e *respostas.comentarios.text*). Embora o índice do tipo *multikey* do MongoDB acelere a localização do documento raiz, o motor do SGBD ainda é obrigado a computar e projetar individualmente cada subdocumento correspondente, o que resulta em sobrecarga de processamento.

O modelo embutido (*emb\_s*) solucionou a reconstrução do bloco completo ("pergunta \+ respostas \+ comentários") em apenas 0,40 ms, uma marca cerca de 24.000 vezes mais rápida do que o PostgreSQL e o MongoDB de referência em seus estados sem índice. Essa disparidade ocorre porque o modelo embutido consolida os dados correlacionados em uma única região física do disco. Para transações pontuais e isoladas, todas as tecnologias apresentaram desempenho semelhante. As inserções unitárias (T8) mantiveram-se na escala de frações de milissegundo. Nas modificações localizadas e nas deleções (T10 e T11), o tempo total da operação mostrou-se estritamente indexado ao tempo de localização do registro-alvo. Consequentemente, operações baseadas em chaves primárias (T11a) foram processadas de imediato, enquanto remoções por colunas de texto não indexadas (T11b) demandaram uma varredura completa da tabela, o que foi mitigado com a ativação dos índices secundários.

Nas operações em lote (T12), o modelo *mongo\_ref* apresentou os menores tempos tanto para inserções (327,49 ms) quanto para atualizações (364,39 ms). Esse comportamento ocorre porque a estrutura de documentos planos permite o uso direto de chamadas nativas, como *insertMany* e *updateMany,* sem dependências estruturais. Em contrapartida, o modelo embutido apresentou o maior tempo de execução na escrita massiva, com 6.782,73 ms no teste T12a. Esse aumento no tempo deve-se à sobrecarga dos operadores *$push* e *$set* que, ao modificarem subdocumentos, forçam o motor *WiredTiger* a reescrever o documento-pai completo em disco múltiplas vezes. O modelo embutido oferece vantagens quando as alterações se concentram na mesma entidade raiz. Contudo, como o teste distribuiu as operações entre perguntas distintas, a localidade de dados gerou um custo adicional (*overhead*) devido à reescrita repetida de grandes blocos de dados.

## **4.2. Análise de Custo de Armazenamento**

A avaliação física e lógica do espaço ocupado pelas diferentes abordagens de modelagem revela o impacto direto dos mecanismos de armazenamento de cada SGBD. Os dados consolidados de volumetria são apresentados na Tabela 3\.

Tabela 3: Custo de armazenamento.

| Cenário | Dados em disco | Índices | Total | Dados lógicos (descompr.) | Compressão |
| :---- | :---- | :---- | :---- | :---- | :---- |
| PostgreSQL | 3,10 GiB | 1,11 GiB | 4,21 GiB | 3,10 GiB | 1,0× (TOAST parcial) |
| MongoDB ref. | 2,15 GiB | 0,73 GiB | 2,88 GiB | 3,77 GiB | 1,75× (snappy) |
| MongoDB emb. | 2,78 GiB | 0,58 GiB | 3,36 GiB | 4,05 GiB | 1,46× (snappy) |

Fonte: elaborada pelos autores.

Em termos lógicos e descomprimidos, os modelos normalizados superam o volume do modelo embutido devido à replicação estrutural de chaves para estabelecer vínculos, como se espera em estruturas normalizadas. Contudo, a aplicação do algoritmo de compressão *Snappy* pelo motor *WiredTiger* altera essa relação no armazenamento físico. As duas instâncias do MongoDB registram menor ocupação de disco do que o PostgreSQL, mesmo operando com bases de dados de tamanho lógico maior. Essa diferença é ampliada pela volumetria das estruturas de indexação no PostgreSQL, que demandam maior alocação de espaço em disco do que as do MongoDB.

Para complementar a análise do impacto dessas estruturas secundárias, a Tabela 4 detalha o custo temporal associado à construção de cada índice planejado.

Tabela 4: Tempo de criação dos índices.

| Índice lógico | pg | mongo\_ref | mongo\_emb |
| :---- | ----- | ----- | ----- |
| autor (OwnerUserId/owner.userId) | 7,19 | 3,01 | 0,9 |
| data (CreationDate) | 3,66 | 2,76 | 0,82 |
| ParentId / aninhamento | 3,04 | 2,25 | — (implícito) |
| PostType+Score / score | 2,57 | 2,9 | 0,78 |
| Comments.PostId | 1,19 | 2,39 | — (implícito) |
| texto (Text/comments.text) | 15,04 | 6,93 | 1,82 (+5,54 no 2º nível) |

Fonte: elaborada pelos autores.

Os dados demonstram que o modelo embutido requer um número menor de índices secundários e apresenta redução no tempo de construção. Esse comportamento decorre da redução do espaço amostral de busca, com uma coleção 3,4 vezes menor em volume de documentos, e da conversão de relacionamentos explícitos em hierarquias implícitas por aninhamento.

Em contrapartida, a arquitetura embutida exige a criação de dois índices de texto distintos para cobrir os diferentes níveis de aninhamento do documento. Por fim, a classe de índice *text\_pattern\_ops* do PostgreSQL concentrou o maior custo computacional do experimento, demandando 15 segundos para sua compilação completa, o que confirma o elevado ônus de manutenção de índices textuais especializados no modelo relacional.

5. Discussão

A ausência de um esquema rígido (*schema-less*) no MongoDB permite que campos ausentes ou nulos não ocupem espaço físico, sem que sejam incluídos nos documentos. Por outro lado, o PostgreSQL exige uma definição prévia e estrita da estrutura de dados, o que demanda a flexibilidade das restrições NOT NULL desde as etapas iniciais de modelagem. Essa característica evidencia a facilidade de evolução de esquemas em bancos de dados não relacionais, em comparação com a rigidez estrutural do modelo relacional.

No que tange à manipulação de dados, o framework de agregação (*aggregation pipeline*) do MongoDB opera de forma procedural e composicional, processando os dados por meio de estágios sequenciais (como $match, $group e $sort). Essa abordagem contrapõe-se à natureza declarativa da linguagem SQL do PostgreSQL. Embora o pipeline do MongoDB ofereça alta flexibilidade para a transformação de documentos e matrizes (*arrays*), ele apresenta maior verbosidade e restrições em cenários específicos, como nos recursos avançados de busca textual (*full-text search*) nativos do PostgreSQL. Essa capacidade de síntese e de abrangência conceitual caracteriza a linguagem SQL como mais expressiva para consultas complexas.

No aspecto transacional, o PostgreSQL implementa o padrão ACID de forma nativa e global, permitindo delimitar o escopo da atomicidade em múltiplas tabelas por meio de blocos de transação explícitos (BEGIN...COMMIT). Em contrapartida, o MongoDB garante a atomicidade estritamente ao nível de um único documento. O modelo embutido aproveita essa característica ao consolidar a entidade completa ("pergunta, respostas e comentários") em uma única estrutura física, assegurando consistência e atomicidade imediatas, sem a sobrecarga operacional de transações multidocumento. Contudo, essa garantia limita-se aos limites do próprio documento raiz. Operações que demandem consistência entre diferentes documentos exigem mecanismos transacionais adicionais, cenário em que o modelo relacional apresenta maior robustez nativa. Embora o MongoDB permita estender essas garantias por meio de sessões transacionais em ambientes replicados (*replica sets*), essa abordagem introduziria custos adicionais de infraestrutura, optando-se, portanto, pela manutenção do modelo *standalone* neste experimento.

6. Conclusão

Os dados experimentais confirmam que a eficiência de um SGBD não é uma propriedade absoluta, mas sim uma variável estritamente dependente do padrão de acesso e da estratégia de modelagem física adotada. O PostgreSQL sobressaiu-se em operações atreladas a índices B-Tree consolidados, como acessos pontuais e buscas textuais (prefixo e infixo), o que reflete a maturidade do seu otimizador de consultas declarativo. Em contrapartida, o MongoDB demonstrou competitividade em varreduras lineares não indexadas devido à compressão do motor *WiredTiger* e obteve um ganho de 24.000 vezes na reconstrução de estruturas hierárquicas ao utilizar o modelo embutido.

Esse comportamento sintetiza o núcleo desta pesquisa: o desempenho do SGBD está subordinado ao alinhamento entre o esquema de dados e a dinâmica de leitura e escrita da aplicação. O modelo embutido, embora ideal para leituras hierárquicas rápidas, mostrou-se inviável para escritas massivas distribuídas (T12a) devido ao custo de reescrita repetida de documentos-pai completos no disco. Inversamente, o modelo plano de referência do MongoDB sacrificou a velocidade de leitura para entregar os menores tempos de inserção e de atualização em lote. Esse contraste reitera que a escolha entre normalização e desnormalização é uma decisão de projeto baseada na proporção esperada de operações concorrentes.

Como limitações metodológicas, os experimentos limitaram-se a um ambiente local isolado e em modo *standalone* para o MongoDB, omitindo o impacto da concorrência massiva decorrente de múltiplas conexões e os custos de consistência e de rede inerentes a topologias distribuídas (como *sharding* e *replica sets*). Além disso, a volumetria fixada no *dataset* do *Stack Overflow*, embora relevante para testes locais, não mapeia o comportamento dos índices sob estresse limitante de memória RAM.

Trabalhos futuros devem estender este *benchmark* para cenários de concorrência real de usuários, avaliar o impacto da replicação lógica e da fragmentação em ambos os sistemas, e investigar a viabilidade de modelos híbridos de embutimento seletivo como alternativa intermediária aos extremos avaliados.

7. Referências bibliográficas

BRADSHAW, Shannon; BRAZIL, Eoin; CHODOROW, Kristina. **MongoDB: The Definitive Guide**: Powerful and Scalable Data Storage. 3\. ed. Sebastopol: O'Reilly Media, 2019\.

CODD, Edgar F. A Relational Model of Data for Large Shared Data Banks. **Communications of the ACM**, v. 13, n. 6, p. 377-387, June 1970\.

DATE, C. J. **Introdução a Sistemas de Bancos de Dados**. Tradução de Daniel Vieira. Rio de Janeiro: Elsevier, 2004\. E-book.

DB-ENGINES. **DB-Engines Ranking**. 2026\. Disponível em: [https://db-engines.com/en/ranking](https://db-engines.com/en/ranking). Acesso em: 26 jun. 2026\.

ELMASRI, Ramez; NAVATHE, Shamkant B. **Sistemas de banco de dados**. 6\. ed. São Paulo: Pearson, 2011\.

IBM. What is a database management system? **IBM Documentation**, 2010\. Disponível em: [https://www.ibm.com/docs/en/zos-basic-skills?topic=zos-what-is-database-management-system](https://www.ibm.com/docs/en/zos-basic-skills?topic=zos-what-is-database-management-system). Acesso em: 26 jun. 2026\.

IBM. **Information Management System.** 2026\. Disponível em: [https://www.ibm.com/history/information-management-system](https://www.ibm.com/history/information-management-system). Acesso em: 11 jul. 2026\.

MONGODB, Inc. **Documentação do MongoDB**. 2026\. Disponível em: [https://www.mongodb.com/pt-br/docs/](https://www.mongodb.com/pt-br/docs/). Acesso em: 11 jul. 2026\.

PANIZ, David. **NoSQL: Como armazenar os dados de uma aplicação moderna.** São Paulo: Casa do Código, 2016\. E-book.

THE POSTGRESQL GLOBAL DEVELOPMENT GROUP. **A Brief History of PostgreSQL**. 2026\. Disponível em: [https://www.postgresql.org/docs/current/history.html](https://www.postgresql.org/docs/current/history.html). Acesso em: 11 jul. 2026\.

