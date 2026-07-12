-- ============================================================================
-- Projeto 2 — Benchmark PostgreSQL (cenário `pg`) — carga de trabalho T1–T12
-- ============================================================================
-- Reaproveita INTEGRALMENTE a infraestrutura do Projeto 1
-- (../projeto1/scripts/postgresql.sql): tabelas benchmark_*, run_benchmark(),
-- save_explain(), create_index_timed(), protocolo de 20 repetições + 5 warmup,
-- pg_prewarm antes de cada cenário.
--
-- Cenários internos deste arquivo (fator índice):
--   'pg_sem_indice'  — apenas PKs (estado natural das tabelas)
--   'pg_com_indice'  — índices B-tree equivalentes aos criados no MongoDB
--
-- Execução: seção por seção (psql -f também funciona de ponta a ponta, pois as
-- extensões/configurações de servidor já foram aplicadas no Projeto 1):
--   psql -d StackOverflow -v ON_ERROR_STOP=1 -f scripts/postgresql.sql
-- ============================================================================


-- ============================================================================
-- SEÇÃO 0 — Pré-requisitos
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
-- track_io_timing='on' e pg_stat_statements já ativos desde o Projeto 1.


-- ============================================================================
-- SEÇÃO 1 — Infraestrutura de medição (idêntica ao Projeto 1)
-- ============================================================================

-- 1.1 Tabelas de resultados
CREATE TABLE IF NOT EXISTS benchmark_runs (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT clock_timestamp(),
    scenario TEXT,
    operation TEXT,
    test_name TEXT,
    run_number INT,
    time_ms NUMERIC,
    rows_affected INT,
    is_warmup BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS benchmark_results (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT clock_timestamp(),
    scenario TEXT,
    operation TEXT,
    test_name TEXT,
    repetitions INT,
    mean_ms NUMERIC,
    stddev_ms NUMERIC,
    min_ms NUMERIC,
    max_ms NUMERIC
);

CREATE TABLE IF NOT EXISTS benchmark_explain (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT clock_timestamp(),
    scenario TEXT,
    operation TEXT,
    test_name TEXT,
    plan_line TEXT
);

CREATE TABLE IF NOT EXISTS benchmark_warmup_results (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT clock_timestamp(),
    scenario TEXT,
    operation TEXT,
    test_name TEXT,
    repetitions INT,
    mean_ms NUMERIC,
    stddev_ms NUMERIC,
    min_ms NUMERIC,
    max_ms NUMERIC
);

CREATE TABLE IF NOT EXISTS benchmark_index_creation (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT clock_timestamp(),
    index_name TEXT,
    create_sql TEXT,
    time_ms NUMERIC
);

-- 1.2 run_benchmark() — mesma função do Projeto 1
CREATE OR REPLACE FUNCTION run_benchmark(
    p_scenario TEXT,
    p_operation TEXT,
    p_test_name TEXT,
    p_sql TEXT,
    p_repetitions INT,
    p_setup_sql TEXT DEFAULT NULL,
    p_cleanup_sql TEXT DEFAULT NULL,
    p_warmup_runs INT DEFAULT 5
)
RETURNS VOID AS $$
DECLARE
    i INT;
    t1 TIMESTAMP;
    t2 TIMESTAMP;
    elapsed_ms NUMERIC;
    affected_rows INT;
BEGIN
    DELETE FROM benchmark_runs
    WHERE scenario = p_scenario
      AND operation = p_operation
      AND test_name = p_test_name;

    DELETE FROM benchmark_results
    WHERE scenario = p_scenario
      AND operation = p_operation
      AND test_name = p_test_name;

    DELETE FROM benchmark_warmup_results
    WHERE scenario = p_scenario
      AND operation = p_operation
      AND test_name = p_test_name;

    -- Warmup (medido, mas gravado à parte com is_warmup = TRUE)
    i := 1;
    WHILE i <= p_warmup_runs LOOP
        IF p_setup_sql IS NOT NULL THEN
            EXECUTE p_setup_sql;
        END IF;

        t1 := clock_timestamp();

        IF upper(p_operation) = 'SELECT' THEN
            EXECUTE 'SELECT count(resultado) FROM (' || p_sql || ') AS resultado'
            INTO affected_rows;
        ELSE
            EXECUTE p_sql;
            GET DIAGNOSTICS affected_rows = ROW_COUNT;
        END IF;

        t2 := clock_timestamp();

        elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;

        INSERT INTO benchmark_runs (
            scenario, operation, test_name, run_number, time_ms, rows_affected, is_warmup
        )
        VALUES (
            p_scenario, p_operation, p_test_name, i, elapsed_ms, affected_rows, TRUE
        );

        IF p_cleanup_sql IS NOT NULL THEN
            EXECUTE p_cleanup_sql;
        END IF;

        i := i + 1;
    END LOOP;

    -- Repetições medidas
    i := 1;
    WHILE i <= p_repetitions LOOP
        IF p_setup_sql IS NOT NULL THEN
            EXECUTE p_setup_sql;
        END IF;

        t1 := clock_timestamp();

        IF upper(p_operation) = 'SELECT' THEN
            EXECUTE 'SELECT count(resultado) FROM (' || p_sql || ') AS resultado'
            INTO affected_rows;
        ELSE
            EXECUTE p_sql;
            GET DIAGNOSTICS affected_rows = ROW_COUNT;
        END IF;

        t2 := clock_timestamp();

        elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;

        INSERT INTO benchmark_runs (
            scenario, operation, test_name, run_number, time_ms, rows_affected, is_warmup
        )
        VALUES (
            p_scenario, p_operation, p_test_name, i, elapsed_ms, affected_rows, FALSE
        );

        IF p_cleanup_sql IS NOT NULL THEN
            EXECUTE p_cleanup_sql;
        END IF;

        i := i + 1;
    END LOOP;

    IF p_warmup_runs > 0 THEN
        INSERT INTO benchmark_warmup_results (
            scenario, operation, test_name, repetitions,
            mean_ms, stddev_ms, min_ms, max_ms
        )
        SELECT
            p_scenario, p_operation, p_test_name, p_warmup_runs,
            avg(time_ms), stddev(time_ms), min(time_ms), max(time_ms)
        FROM benchmark_runs
        WHERE scenario = p_scenario
          AND operation = p_operation
          AND test_name = p_test_name
          AND is_warmup = TRUE;
    END IF;

    INSERT INTO benchmark_results (
        scenario, operation, test_name, repetitions,
        mean_ms, stddev_ms, min_ms, max_ms
    )
    SELECT
        p_scenario, p_operation, p_test_name, p_repetitions,
        avg(time_ms), stddev(time_ms), min(time_ms), max(time_ms)
    FROM benchmark_runs
    WHERE scenario = p_scenario
      AND operation = p_operation
      AND test_name = p_test_name
      AND is_warmup = FALSE;
END;
$$ LANGUAGE plpgsql;

-- 1.3 save_explain() — idem Projeto 1
CREATE OR REPLACE FUNCTION save_explain(
    p_scenario TEXT,
    p_operation TEXT,
    p_test_name TEXT,
    p_sql TEXT
)
RETURNS VOID AS $$
DECLARE
    line TEXT;
BEGIN
    DELETE FROM benchmark_explain
    WHERE scenario = p_scenario
      AND operation = p_operation
      AND test_name = p_test_name;

    FOR line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || p_sql LOOP
        INSERT INTO benchmark_explain (
            scenario, operation, test_name, plan_line
        )
        VALUES (
            p_scenario, p_operation, p_test_name, line
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 1.4 create_index_timed() — idem Projeto 1
CREATE OR REPLACE FUNCTION create_index_timed(
    p_index_name TEXT,
    p_sql TEXT
)
RETURNS VOID AS $$
DECLARE
    t1 TIMESTAMP;
    t2 TIMESTAMP;
    elapsed_ms NUMERIC;
BEGIN
    t1 := clock_timestamp();
    EXECUTE p_sql;
    t2 := clock_timestamp();

    elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;

    INSERT INTO benchmark_index_creation (index_name, create_sql, time_ms)
    VALUES (p_index_name, p_sql, elapsed_ms);
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- SEÇÃO 1.5 — Valores de teste (determinísticos) e limpeza defensiva
-- ============================================================================
-- Os MESMOS alvos lógicos são usados no lado MongoDB (bench_mongo.js deriva-os
-- com os mesmos critérios determinísticos), garantindo carga idêntica.

DROP TABLE IF EXISTS benchmark_values_p2;
CREATE TABLE benchmark_values_p2 AS
WITH answer_counts AS (
    SELECT "ParentId" AS qid, count(*) AS n
    FROM "Posts" WHERE "PostTypeId" = 2
    GROUP BY "ParentId"
), comment_counts AS (
    SELECT "PostId" AS qid, count(*) AS n
    FROM "Comments"
    GROUP BY "PostId"
)
SELECT
    -- pergunta "rica": 20–40 respostas e >= 10 comentários — alvo de T1 e T6
    (SELECT min(q."Id")
       FROM "Posts" q
       JOIN answer_counts  ac ON ac.qid = q."Id"
       JOIN comment_counts cc ON cc.qid = q."Id"
      WHERE q."PostTypeId" = 1
        AND ac.n BETWEEN 20 AND 40
        AND cc.n >= 10)                                   AS question_id,
    -- usuário prolífico (~40–60 PERGUNTAS) — alvo de T2 (T2–T4 são definidos
    -- sobre perguntas, para equivalência lógica com o modelo embutido)
    (SELECT min("OwnerUserId")
       FROM (SELECT "OwnerUserId"
               FROM "Posts"
              WHERE "OwnerUserId" IS NOT NULL
                AND "PostTypeId" = 1
              GROUP BY "OwnerUserId"
             HAVING count(*) BETWEEN 40 AND 60) t)        AS owner_user_id,
    -- usuário existente para comentários inseridos (T8/T9/T12)
    (SELECT min("Id") FROM "Users" WHERE "Reputation" > 1000) AS user_id;

SELECT * FROM benchmark_values_p2;

-- Garantia: os três alvos existem (aborta cedo em vez de medir consultas vazias)
DO $$
DECLARE v benchmark_values_p2%ROWTYPE;
BEGIN
    SELECT * INTO v FROM benchmark_values_p2;
    IF v.question_id IS NULL OR v.owner_user_id IS NULL OR v.user_id IS NULL THEN
        RAISE EXCEPTION 'benchmark_values_p2 contém NULL: %', v;
    END IF;
END $$;

-- Alvos dos lotes: primeiras N perguntas em ordem de Id (determinístico e
-- reproduzível no MongoDB com o mesmo critério)
DROP TABLE IF EXISTS bench_qids_1000;
CREATE TABLE bench_qids_1000 AS
SELECT row_number() OVER (ORDER BY "Id") AS gid, "Id" AS question_id
FROM (SELECT "Id" FROM "Posts" WHERE "PostTypeId" = 1 ORDER BY "Id" LIMIT 1000) t;

DROP TABLE IF EXISTS bench_qids_100k;
CREATE TABLE bench_qids_100k AS
SELECT row_number() OVER (ORDER BY "Id") AS gid, "Id" AS question_id
FROM (SELECT "Id" FROM "Posts" WHERE "PostTypeId" = 1 ORDER BY "Id" LIMIT 100000) t;

-- Limpeza defensiva de execuções anteriores (marcadores e ids sentinela)
DELETE FROM "Comments" WHERE "Id" IN (-910001, -920001, -920002, -930001, -930002);
DELETE FROM "Comments" WHERE "Id" BETWEEN 210000001 AND 210001000;   -- lote 1000
DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000;   -- massa 100k
DELETE FROM "Comments" WHERE "Text" IN (
    'benchmark_insert_comment', 'benchmark_insert_lote',
    'benchmark_update_score', 'benchmark_update_text_old', 'benchmark_update_text_new',
    'benchmark_delete_comment',
    'benchmark_mass_insert', 'benchmark_mass_update', 'benchmark_mass_delete');


-- ============================================================================
-- SEÇÃO 2 — Cenário `pg_sem_indice`  (T1–T12, apenas PKs)
-- ============================================================================

-- 2.0 Preparação: derruba índices extras; estado de cache simétrico ao Mongo
--     (CHECKPOINT + VACUUM + ANALYZE + pg_prewarm — warm cache, como no P1)
DROP INDEX IF EXISTS idx_posts_owneruserid_btree;
DROP INDEX IF EXISTS idx_posts_creationdate_btree;
DROP INDEX IF EXISTS idx_posts_score_btree;
DROP INDEX IF EXISTS idx_posts_parentid_btree;
DROP INDEX IF EXISTS idx_posts_posttype_score_btree;
DROP INDEX IF EXISTS idx_comments_postid_btree;
DROP INDEX IF EXISTS idx_comments_text_btree;
DROP INDEX IF EXISTS idx_comments_text_pattern_btree;
CHECKPOINT;
VACUUM "Comments";
ANALYZE "Posts";
ANALYZE "Comments";
ANALYZE "Users";
SELECT pg_prewarm('"Posts"');
SELECT pg_prewarm('"Comments"');
SELECT pg_prewarm('"Users"');

-- ─── T1 — Busca por chave primária ──────────────────────────────────────────
-- MongoDB equivalente: db.posts.findOne({_id}) / db.questions.findOne({_id})
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_post_by_pk',
    $SQL$
    SELECT * FROM "Posts" WHERE "Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T2 — Busca por campo secundário (igualdade) ────────────────────────────
-- Mesmo teste do Projeto 1 (select_posts_by_owner_user_id)
-- MongoDB: db.posts.find({ownerUserId}) / db.questions.find({'owner.userId'})
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_posts_by_owner_user_id',
    $SQL$
    SELECT "Id", "OwnerUserId", "Title", "Score", "ViewCount"
    FROM "Posts"
    WHERE "PostTypeId" = 1
      AND "OwnerUserId" = (SELECT owner_user_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T3 — Consulta por intervalo de data ────────────────────────────────────
-- MongoDB: find({creationDate: {$gte, $lt}})
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_posts_date_between',
    $SQL$
    SELECT "Id", "Title", "CreationDate"
    FROM "Posts"
    WHERE "PostTypeId" = 1
      AND "CreationDate" >= '2010-01-01 00:00:00+00'
      AND "CreationDate" <  '2010-02-01 00:00:00+00'
    $SQL$,
    20);

-- ─── T4 — Top-N ordenado por score ──────────────────────────────────────────
-- Mesmo teste do Projeto 1. MongoDB: find().sort({score:-1}).limit(20)
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_posts_order_by_score',
    $SQL$
    SELECT "Id", "Title", "Score"
    FROM "Posts"
    WHERE "PostTypeId" = 1
    ORDER BY "Score" DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T5 — Busca textual: prefixo e infixo ───────────────────────────────────
-- Mesmos testes do Projeto 1. MongoDB: regex ancorado /^I / e regex /error/
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_comments_like_prefix',
    $SQL$
    SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE 'I %'
    $SQL$,
    20);

SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'select_comments_like_infix',
    $SQL$
    SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE '%error%'
    $SQL$,
    20);

-- ─── T6 — Agregado: pergunta + respostas + comentários (tarefa-chave) ───────
-- PG reconstrói o agregado com subconsultas correlacionadas + json_agg
-- (forma idiomática de montar o documento no relacional).
-- MongoDB ref: $lookup aninhado | MongoDB emb: findOne({_id}) — leitura direta
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'join_pergunta_respostas',
    $SQL$
    SELECT q."Id", q."Title", q."Body", q."Score",
           (SELECT json_agg(json_build_object(
                      'id', c."Id", 'text', c."Text", 'score', c."Score"))
              FROM "Comments" c WHERE c."PostId" = q."Id")     AS comments,
           (SELECT json_agg(json_build_object(
                      'id', a."Id", 'body', a."Body", 'score', a."Score",
                      'comments',
                      (SELECT json_agg(json_build_object(
                                  'id', c2."Id", 'text', c2."Text", 'score', c2."Score"))
                         FROM "Comments" c2 WHERE c2."PostId" = a."Id")))
              FROM "Posts" a WHERE a."ParentId" = q."Id")      AS answers
    FROM "Posts" q
    WHERE q."Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T6b — Junção N:1 com Users (top-20 perguntas + nome do autor) ──────────
-- Mesmo teste do Projeto 1 (join_top_posts_users).
-- MongoDB ref: $lookup users | MongoDB emb: owner denormalizado (leitura local)
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'join_top_posts_users',
    $SQL$
    SELECT p."Id", p."Title", p."Score", u."DisplayName"
    FROM "Posts" p
    LEFT JOIN "Users" u ON u."Id" = p."OwnerUserId"
    WHERE p."PostTypeId" = 1
    ORDER BY p."Score" DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T7 — Agregação: contagem por grupo (alta cardinalidade) ────────────────
-- Mesmo teste do Projeto 1 (agg_group_by_owner). MongoDB: $group + $sort + $limit
SELECT run_benchmark(
    'pg_sem_indice', 'SELECT', 'agg_group_by_owner',
    $SQL$
    SELECT "OwnerUserId", COUNT(*) AS post_count
    FROM "Posts"
    WHERE "PostTypeId" IN (1, 2)
    GROUP BY "OwnerUserId"
    ORDER BY post_count DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T8 — Inserção unitária ─────────────────────────────────────────────────
-- Mesmo teste do Projeto 1 (insert_comment). MongoDB ref: insertOne
-- MongoDB emb: $push no documento da pergunta (inserir = atualizar o pai)
SELECT run_benchmark(
    'pg_sem_indice', 'INSERT', 'insert_comment',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-910001,
            (SELECT question_id FROM benchmark_values_p2),
            0, 'benchmark_insert_comment', NOW(),
            (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -910001 $SQL$);

-- ─── T9 — Inserção em lote (1.000 comentários em 1.000 perguntas) ───────────
-- MongoDB ref: insertMany(1000) | MongoDB emb: bulkWrite de 1000 $push
SELECT run_benchmark(
    'pg_sem_indice', 'INSERT', 'insert_lote_1000',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 210000000 + b.gid, b.question_id, 0, 'benchmark_insert_lote', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_1000 b
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 210000001 AND 210001000 $SQL$);

-- ─── T10 — Update em campo não indexado e em campo indexado ─────────────────
-- Mesmos testes do Projeto 1. MongoDB: updateOne por texto; no emb o update é
-- em subdocumento embutido (arrayFilters) — a variação idiomática do modelo E.
SELECT run_benchmark(
    'pg_sem_indice', 'UPDATE', 'update_comment_score_non_indexed',
    $SQL$
    UPDATE "Comments" SET "Score" = "Score" + 1
    WHERE "Text" = 'benchmark_update_score'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-920002, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_update_score', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -920002 $SQL$);

SELECT run_benchmark(
    'pg_sem_indice', 'UPDATE', 'update_comment_text_indexed_column',
    $SQL$
    UPDATE "Comments" SET "Text" = 'benchmark_update_text_new'
    WHERE "Text" = 'benchmark_update_text_old'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-920001, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_update_text_old', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -920001 $SQL$);

-- ─── T11 — Delete por PK e por coluna comum ─────────────────────────────────
-- Mesmos testes do Projeto 1. MongoDB ref: deleteOne | emb: $pull do documento
SELECT run_benchmark(
    'pg_sem_indice', 'DELETE', 'delete_comment_by_pk',
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -930001 $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-930001, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_delete_by_pk', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    NULL);

SELECT run_benchmark(
    'pg_sem_indice', 'DELETE', 'delete_comment_by_text',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_delete_comment' $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-930002, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_delete_comment', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    NULL);

-- ─── T12 — DML em massa (100 mil comentários em 100 mil perguntas) ──────────
-- MongoDB ref: insertMany/updateMany/deleteMany | emb: bulkWrite de $push /
-- updateMany+arrayFilters / updateMany+$pull
SELECT run_benchmark(
    'pg_sem_indice', 'INSERT', 'mass_insert_100k',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_insert', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000 $SQL$);

SELECT run_benchmark(
    'pg_sem_indice', 'UPDATE', 'mass_update_100k',
    $SQL$
    UPDATE "Comments" SET "Score" = "Score" + 1
    WHERE "Text" = 'benchmark_mass_update'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_update', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000 $SQL$);

SELECT run_benchmark(
    'pg_sem_indice', 'DELETE', 'mass_delete_100k',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_mass_delete' $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_delete', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    NULL);

-- 2.17 Planos de execução do cenário sem índice (SELECTs; UPDATE/DELETE por
--      marcador com setup/limpeza manual em volta — EXPLAIN ANALYZE executa)
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_post_by_pk',
    $SQL$ SELECT * FROM "Posts" WHERE "Id" = (SELECT question_id FROM benchmark_values_p2) $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_posts_by_owner_user_id',
    $SQL$ SELECT "Id", "OwnerUserId", "Title", "Score", "ViewCount" FROM "Posts"
          WHERE "PostTypeId" = 1
            AND "OwnerUserId" = (SELECT owner_user_id FROM benchmark_values_p2) $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_posts_date_between',
    $SQL$ SELECT "Id", "Title", "CreationDate" FROM "Posts"
          WHERE "PostTypeId" = 1
            AND "CreationDate" >= '2010-01-01 00:00:00+00'
            AND "CreationDate" <  '2010-02-01 00:00:00+00' $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_posts_order_by_score',
    $SQL$ SELECT "Id", "Title", "Score" FROM "Posts"
          WHERE "PostTypeId" = 1 ORDER BY "Score" DESC LIMIT 20 $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_comments_like_prefix',
    $SQL$ SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE 'I %' $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'select_comments_like_infix',
    $SQL$ SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE '%error%' $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'join_pergunta_respostas',
    $SQL$
    SELECT q."Id", q."Title", q."Body", q."Score",
           (SELECT json_agg(json_build_object('id', c."Id", 'text', c."Text", 'score', c."Score"))
              FROM "Comments" c WHERE c."PostId" = q."Id")     AS comments,
           (SELECT json_agg(json_build_object('id', a."Id", 'body', a."Body", 'score', a."Score",
                      'comments', (SELECT json_agg(json_build_object('id', c2."Id", 'text', c2."Text", 'score', c2."Score"))
                                     FROM "Comments" c2 WHERE c2."PostId" = a."Id")))
              FROM "Posts" a WHERE a."ParentId" = q."Id")      AS answers
    FROM "Posts" q WHERE q."Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'join_top_posts_users',
    $SQL$ SELECT p."Id", p."Title", p."Score", u."DisplayName" FROM "Posts" p
          LEFT JOIN "Users" u ON u."Id" = p."OwnerUserId"
          WHERE p."PostTypeId" = 1 ORDER BY p."Score" DESC LIMIT 20 $SQL$);
SELECT save_explain('pg_sem_indice', 'SELECT', 'agg_group_by_owner',
    $SQL$ SELECT "OwnerUserId", COUNT(*) AS post_count FROM "Posts"
          WHERE "PostTypeId" IN (1, 2)
          GROUP BY "OwnerUserId" ORDER BY post_count DESC LIMIT 20 $SQL$);

INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
VALUES (-920002, (SELECT question_id FROM benchmark_values_p2), 0,
        'benchmark_update_score', NOW(), (SELECT user_id FROM benchmark_values_p2));
SELECT save_explain('pg_sem_indice', 'UPDATE', 'update_comment_score_non_indexed',
    $SQL$ UPDATE "Comments" SET "Score" = "Score" + 1 WHERE "Text" = 'benchmark_update_score' $SQL$);
DELETE FROM "Comments" WHERE "Id" = -920002;

INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
VALUES (-930002, (SELECT question_id FROM benchmark_values_p2), 0,
        'benchmark_delete_comment', NOW(), (SELECT user_id FROM benchmark_values_p2));
SELECT save_explain('pg_sem_indice', 'DELETE', 'delete_comment_by_text',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_delete_comment' $SQL$);
DELETE FROM "Comments" WHERE "Id" = -930002;


-- ============================================================================
-- SEÇÃO 3 — Cenário `pg_com_indice`  (T1–T12, índices B-tree equivalentes)
-- ============================================================================

-- 3.0 Preparação: cria índices EQUIVALENTES aos do MongoDB ,
--     com tempo de criação medido; ANALYZE + prewarm de tabelas e índices
CHECKPOINT;
VACUUM "Comments";

SELECT create_index_timed('idx_posts_owneruserid_btree',
    $$ CREATE INDEX idx_posts_owneruserid_btree ON "Posts" ("OwnerUserId") $$);
SELECT create_index_timed('idx_posts_creationdate_btree',
    $$ CREATE INDEX idx_posts_creationdate_btree ON "Posts" ("CreationDate") $$);
SELECT create_index_timed('idx_posts_parentid_btree',
    $$ CREATE INDEX idx_posts_parentid_btree ON "Posts" ("ParentId") $$);
SELECT create_index_timed('idx_posts_posttype_score_btree',
    $$ CREATE INDEX idx_posts_posttype_score_btree ON "Posts" ("PostTypeId", "Score" DESC) $$);
SELECT create_index_timed('idx_comments_postid_btree',
    $$ CREATE INDEX idx_comments_postid_btree ON "Comments" ("PostId") $$);
-- text_pattern_ops: cobre LIKE de prefixo em locale != C E TAMBÉM igualdade
-- (=), servindo T5 e os filtros por marcador de T10–T12 — UM índice em Text,
-- equivalente ao único índice {text:1} do MongoDB (paridade de custo de escrita)
SELECT create_index_timed('idx_comments_text_pattern_btree',
    $$ CREATE INDEX idx_comments_text_pattern_btree ON "Comments" ("Text" text_pattern_ops) $$);

ANALYZE "Posts";
ANALYZE "Comments";
ANALYZE "Users";

-- ── Medição de armazenamento — capturada AQUI, com a tabela
--    recém-VACUUMizada e os índices recém-criados, espelhando o snapshot
--    'apos_criacao_indices' do lado MongoDB (antes do churn dos testes DML)
DROP TABLE IF EXISTS benchmark_storage_p2;
CREATE TABLE benchmark_storage_p2 AS
SELECT 'pg'::text                                   AS scenario,
       c.relname                                    AS object,
       pg_table_size(c.oid)                         AS size_bytes,
       pg_indexes_size(c.oid)                       AS index_size_bytes
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relname IN ('Posts', 'Comments', 'Users');

SELECT * FROM benchmark_storage_p2;

DROP TABLE IF EXISTS benchmark_storage_idx_p2;
CREATE TABLE benchmark_storage_idx_p2 AS
SELECT 'pg'::text                                    AS scenario,
       i.indexrelid::regclass::text                  AS object,
       pg_relation_size(i.indexrelid)                AS size_bytes
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname LIKE 'idx_%_btree';

SELECT * FROM benchmark_storage_idx_p2;

SELECT pg_prewarm('"Posts"');
SELECT pg_prewarm('"Comments"');
SELECT pg_prewarm('"Users"');
SELECT pg_prewarm('idx_posts_owneruserid_btree');
SELECT pg_prewarm('idx_posts_creationdate_btree');
SELECT pg_prewarm('idx_posts_parentid_btree');
SELECT pg_prewarm('idx_posts_posttype_score_btree');
SELECT pg_prewarm('idx_comments_postid_btree');
SELECT pg_prewarm('idx_comments_text_pattern_btree');

-- ─── T1 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_post_by_pk',
    $SQL$
    SELECT * FROM "Posts" WHERE "Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T2 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_posts_by_owner_user_id',
    $SQL$
    SELECT "Id", "OwnerUserId", "Title", "Score", "ViewCount"
    FROM "Posts"
    WHERE "PostTypeId" = 1
      AND "OwnerUserId" = (SELECT owner_user_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T3 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_posts_date_between',
    $SQL$
    SELECT "Id", "Title", "CreationDate"
    FROM "Posts"
    WHERE "PostTypeId" = 1
      AND "CreationDate" >= '2010-01-01 00:00:00+00'
      AND "CreationDate" <  '2010-02-01 00:00:00+00'
    $SQL$,
    20);

-- ─── T4 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_posts_order_by_score',
    $SQL$
    SELECT "Id", "Title", "Score"
    FROM "Posts"
    WHERE "PostTypeId" = 1
    ORDER BY "Score" DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T5 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_comments_like_prefix',
    $SQL$
    SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE 'I %'
    $SQL$,
    20);

SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'select_comments_like_infix',
    $SQL$
    SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE '%error%'
    $SQL$,
    20);

-- ─── T6 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'join_pergunta_respostas',
    $SQL$
    SELECT q."Id", q."Title", q."Body", q."Score",
           (SELECT json_agg(json_build_object(
                      'id', c."Id", 'text', c."Text", 'score', c."Score"))
              FROM "Comments" c WHERE c."PostId" = q."Id")     AS comments,
           (SELECT json_agg(json_build_object(
                      'id', a."Id", 'body', a."Body", 'score', a."Score",
                      'comments',
                      (SELECT json_agg(json_build_object(
                                  'id', c2."Id", 'text', c2."Text", 'score', c2."Score"))
                         FROM "Comments" c2 WHERE c2."PostId" = a."Id")))
              FROM "Posts" a WHERE a."ParentId" = q."Id")      AS answers
    FROM "Posts" q
    WHERE q."Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$,
    20);

-- ─── T6b ────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'join_top_posts_users',
    $SQL$
    SELECT p."Id", p."Title", p."Score", u."DisplayName"
    FROM "Posts" p
    LEFT JOIN "Users" u ON u."Id" = p."OwnerUserId"
    WHERE p."PostTypeId" = 1
    ORDER BY p."Score" DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T7 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'SELECT', 'agg_group_by_owner',
    $SQL$
    SELECT "OwnerUserId", COUNT(*) AS post_count
    FROM "Posts"
    WHERE "PostTypeId" IN (1, 2)
    GROUP BY "OwnerUserId"
    ORDER BY post_count DESC
    LIMIT 20
    $SQL$,
    20);

-- ─── T8 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'INSERT', 'insert_comment',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-910001,
            (SELECT question_id FROM benchmark_values_p2),
            0, 'benchmark_insert_comment', NOW(),
            (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -910001 $SQL$);

-- ─── T9 ─────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'INSERT', 'insert_lote_1000',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 210000000 + b.gid, b.question_id, 0, 'benchmark_insert_lote', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_1000 b
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 210000001 AND 210001000 $SQL$);

-- ─── T10 ────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'UPDATE', 'update_comment_score_non_indexed',
    $SQL$
    UPDATE "Comments" SET "Score" = "Score" + 1
    WHERE "Text" = 'benchmark_update_score'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-920002, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_update_score', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -920002 $SQL$);

SELECT run_benchmark(
    'pg_com_indice', 'UPDATE', 'update_comment_text_indexed_column',
    $SQL$
    UPDATE "Comments" SET "Text" = 'benchmark_update_text_new'
    WHERE "Text" = 'benchmark_update_text_old'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-920001, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_update_text_old', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -920001 $SQL$);

-- ─── T11 ────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'DELETE', 'delete_comment_by_pk',
    $SQL$ DELETE FROM "Comments" WHERE "Id" = -930001 $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-930001, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_delete_by_pk', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    NULL);

SELECT run_benchmark(
    'pg_com_indice', 'DELETE', 'delete_comment_by_text',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_delete_comment' $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    VALUES (-930002, (SELECT question_id FROM benchmark_values_p2), 0,
            'benchmark_delete_comment', NOW(), (SELECT user_id FROM benchmark_values_p2))
    $SQL$,
    NULL);

-- ─── T12 ────────────────────────────────────────────────────────────────────
SELECT run_benchmark(
    'pg_com_indice', 'INSERT', 'mass_insert_100k',
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_insert', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    20,
    NULL,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000 $SQL$);

SELECT run_benchmark(
    'pg_com_indice', 'UPDATE', 'mass_update_100k',
    $SQL$
    UPDATE "Comments" SET "Score" = "Score" + 1
    WHERE "Text" = 'benchmark_mass_update'
    $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_update', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    $SQL$ DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000 $SQL$);

SELECT run_benchmark(
    'pg_com_indice', 'DELETE', 'mass_delete_100k',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_mass_delete' $SQL$,
    20,
    $SQL$
    INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
    SELECT 220000000 + b.gid, b.question_id, 0, 'benchmark_mass_delete', NOW(),
           (SELECT user_id FROM benchmark_values_p2)
    FROM bench_qids_100k b
    $SQL$,
    NULL);

-- 3.17 Planos de execução do cenário com índice
SELECT save_explain('pg_com_indice', 'SELECT', 'select_post_by_pk',
    $SQL$ SELECT * FROM "Posts" WHERE "Id" = (SELECT question_id FROM benchmark_values_p2) $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'select_posts_by_owner_user_id',
    $SQL$ SELECT "Id", "OwnerUserId", "Title", "Score", "ViewCount" FROM "Posts"
          WHERE "PostTypeId" = 1
            AND "OwnerUserId" = (SELECT owner_user_id FROM benchmark_values_p2) $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'select_posts_date_between',
    $SQL$ SELECT "Id", "Title", "CreationDate" FROM "Posts"
          WHERE "PostTypeId" = 1
            AND "CreationDate" >= '2010-01-01 00:00:00+00'
            AND "CreationDate" <  '2010-02-01 00:00:00+00' $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'select_posts_order_by_score',
    $SQL$ SELECT "Id", "Title", "Score" FROM "Posts"
          WHERE "PostTypeId" = 1 ORDER BY "Score" DESC LIMIT 20 $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'select_comments_like_prefix',
    $SQL$ SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE 'I %' $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'select_comments_like_infix',
    $SQL$ SELECT "Id", "Text" FROM "Comments" WHERE "Text" LIKE '%error%' $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'join_pergunta_respostas',
    $SQL$
    SELECT q."Id", q."Title", q."Body", q."Score",
           (SELECT json_agg(json_build_object('id', c."Id", 'text', c."Text", 'score', c."Score"))
              FROM "Comments" c WHERE c."PostId" = q."Id")     AS comments,
           (SELECT json_agg(json_build_object('id', a."Id", 'body', a."Body", 'score', a."Score",
                      'comments', (SELECT json_agg(json_build_object('id', c2."Id", 'text', c2."Text", 'score', c2."Score"))
                                     FROM "Comments" c2 WHERE c2."PostId" = a."Id")))
              FROM "Posts" a WHERE a."ParentId" = q."Id")      AS answers
    FROM "Posts" q WHERE q."Id" = (SELECT question_id FROM benchmark_values_p2)
    $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'join_top_posts_users',
    $SQL$ SELECT p."Id", p."Title", p."Score", u."DisplayName" FROM "Posts" p
          LEFT JOIN "Users" u ON u."Id" = p."OwnerUserId"
          WHERE p."PostTypeId" = 1 ORDER BY p."Score" DESC LIMIT 20 $SQL$);
SELECT save_explain('pg_com_indice', 'SELECT', 'agg_group_by_owner',
    $SQL$ SELECT "OwnerUserId", COUNT(*) AS post_count FROM "Posts"
          WHERE "PostTypeId" IN (1, 2)
          GROUP BY "OwnerUserId" ORDER BY post_count DESC LIMIT 20 $SQL$);

INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
VALUES (-920002, (SELECT question_id FROM benchmark_values_p2), 0,
        'benchmark_update_score', NOW(), (SELECT user_id FROM benchmark_values_p2));
SELECT save_explain('pg_com_indice', 'UPDATE', 'update_comment_score_non_indexed',
    $SQL$ UPDATE "Comments" SET "Score" = "Score" + 1 WHERE "Text" = 'benchmark_update_score' $SQL$);
DELETE FROM "Comments" WHERE "Id" = -920002;

INSERT INTO "Comments" ("Id", "PostId", "Score", "Text", "CreationDate", "UserId")
VALUES (-930002, (SELECT question_id FROM benchmark_values_p2), 0,
        'benchmark_delete_comment', NOW(), (SELECT user_id FROM benchmark_values_p2));
SELECT save_explain('pg_com_indice', 'DELETE', 'delete_comment_by_text',
    $SQL$ DELETE FROM "Comments" WHERE "Text" = 'benchmark_delete_comment' $SQL$);
DELETE FROM "Comments" WHERE "Id" = -930002;


-- ============================================================================
-- SEÇÃO 4 — Estado final: derruba índices do benchmark (deixa o banco limpo)
-- ============================================================================
-- (a medição de armazenamento foi feita na Seção 3.0, em estado limpo)
DROP INDEX IF EXISTS idx_posts_owneruserid_btree;
DROP INDEX IF EXISTS idx_posts_creationdate_btree;
DROP INDEX IF EXISTS idx_posts_score_btree;
DROP INDEX IF EXISTS idx_posts_parentid_btree;
DROP INDEX IF EXISTS idx_posts_posttype_score_btree;
DROP INDEX IF EXISTS idx_comments_postid_btree;
DROP INDEX IF EXISTS idx_comments_text_btree;
DROP INDEX IF EXISTS idx_comments_text_pattern_btree;

-- Limpeza defensiva final
DELETE FROM "Comments" WHERE "Id" IN (-910001, -920001, -920002, -930001, -930002);
DELETE FROM "Comments" WHERE "Id" BETWEEN 210000001 AND 210001000;
DELETE FROM "Comments" WHERE "Id" BETWEEN 220000001 AND 220100000;
VACUUM "Comments";

-- ============================================================================
-- SEÇÃO 5 — Conferência rápida dos resultados
-- ============================================================================
SELECT scenario, operation, test_name, repetitions,
       ROUND(mean_ms, 2)  AS mean_ms,
       ROUND(stddev_ms, 2) AS stddev_ms,
       ROUND(min_ms, 2)   AS min_ms,
       ROUND(max_ms, 2)   AS max_ms
FROM benchmark_results
WHERE scenario IN ('pg_sem_indice', 'pg_com_indice')
ORDER BY test_name, scenario;
