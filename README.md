# MAC5760 — Projeto 2: PostgreSQL versus MongoDB

Benchmark comparando **PostgreSQL (SQL)** e **MongoDB (NoSQL)** sobre o dataset
Stack Overflow 2010 (`Posts`, `Comments`, `Users`), avaliando o impacto da
**modelagem de dados** (normalizada vs. desnormalizada) e da **indexação**.

Felipe Pires Rocha · Victor Franco Martins — IME-USP, 2026.

## Conteúdo

| Arquivo | Descrição |
|---|---|
| `PostgreSQL versus MongoDB.md` | **Relatório completo** — metodologia, resultados e análise |
| `scripts/postgresql.sql` | Benchmark do lado PostgreSQL (tarefas T1–T12, com e sem índice) |
| `scripts/bench_mongo.js` | Benchmark do lado MongoDB, para `mongosh` (mesmas tarefas e protocolo) |

## O experimento em uma linha

As 12 tarefas (leituras pontuais, filtros, busca textual, agregações e
escritas) rodam em **três instâncias** — `pg` (relacional normalizado),
`mongo_ref` (MongoDB espelhando o relacional) e `mongo_emb` (MongoDB com
documentos aninhados) — cada uma **com e sem índices**, sob o mesmo protocolo:
5 execuções de warmup + 20 medidas por teste, planos de execução capturados e
resultados exportados em CSV.

## Requisitos

- PostgreSQL 18+ com o dataset Stack Overflow 2010 carregado no banco `StackOverflow`
- MongoDB 8+ (standalone) com as mesmas entidades portadas para os bancos
  `stackoverflow_ref` (coleções `users`, `posts`, `comments`) e
  `stackoverflow_emb` (coleção `questions`, com respostas e comentários embutidos)
- `mongosh` 2+

## Execução

```bash
# Lado PostgreSQL (cenários pg_sem_indice e pg_com_indice)
psql -d StackOverflow -v ON_ERROR_STOP=1 -f scripts/postgresql.sql

# Lado MongoDB (cenários mongo_ref e mongo_emb), a partir desta pasta
mongosh --quiet --file scripts/bench_mongo.js
```

O script do PostgreSQL grava os resultados nas tabelas `benchmark_*` do próprio
banco; o do MongoDB gera CSVs em `results/data/`. Variáveis úteis do
`bench_mongo.js`: `BENCH_SCENARIOS=mongo_ref,mongo_emb`, `BENCH_REPS`,
`BENCH_WARMUP`, `BENCH_APPEND=1` (retomar sem truncar CSVs).

## Resultado central

O desempenho não é propriedade do motor, e sim do **alinhamento entre modelagem
e padrão de acesso**: o modelo embutido reconstrói o agregado
"pergunta + respostas + comentários" ~24.000× mais rápido que os modelos
normalizados sem índice, mas é o pior em escrita massiva distribuída; o
PostgreSQL domina busca textual; o MongoDB referenciado vence em DML em lote.
Detalhes, tabelas e discussão no relatório.
