/* ============================================================================
 * Projeto 2 — Benchmark MongoDB (cenários `mongo_ref` e `mongo_emb`)
 * ============================================================================
 * Espelha a infraestrutura run_benchmark() do Projeto 1 (PostgreSQL):
 *   - N = 20 repetições medidas + 5 de warmup (is_warmup=True), por teste;
 *   - setup/cleanup FORA da janela de tempo; só a operação-alvo é cronometrada;
 *   - agregação média/desvio/min/max por teste;
 *   - explain("executionStats") por tarefa de leitura (plano de execução);
 *   - tempo de criação de cada índice (equivalentes aos B-tree do PG);
 *   - CSVs no MESMO schema do Projeto 1 + coluna index_state.
 *
 * Equivalências de medição com o lado PG:
 *   - No PG, SELECTs são envelopados em `SELECT count(resultado) FROM (...)`:
 *     o servidor materializa todas as linhas sem transferi-las ao cliente.
 *     Aqui, o equivalente é executar o pipeline com um {$count} final — o
 *     servidor materializa os documentos e devolve só a contagem.
 *   - PG cronometra dentro do plpgsql (clock_timestamp); aqui cronometramos
 *     no cliente (performance.now) via socket local — o roundtrip (~0,1 ms)
 *     é registrado como limitação para os testes sub-milissegundo.
 *
 * Execução (a partir da pasta project2/):
 *   mongosh --quiet --file scripts/bench_mongo.js
 * ============================================================================ */

'use strict';

const REPS   = parseInt(process.env.BENCH_REPS   || '20');
const WARMUP = parseInt(process.env.BENCH_WARMUP || '5');
const SKIP_MASS = process.env.BENCH_SKIP_MASS === '1';
const SCENARIOS = (process.env.BENCH_SCENARIOS || 'mongo_ref,mongo_emb').split(',');
// BENCH_APPEND=1: não trunca os CSVs — acrescenta às linhas já gravadas.
// Usado para retomar um cenário depois de uma falha, sem perder o cenário já
// medido (ex.: re-rodar só mongo_emb preservando mongo_ref).
const APPEND = process.env.BENCH_APPEND === '1';

const OUT_DIR = 'results/data';
const EXPLAIN_DIR = `${OUT_DIR}/explain_mongo`;
fs.mkdirSync(OUT_DIR, { recursive: true });
fs.mkdirSync(EXPLAIN_DIR, { recursive: true });

const refDb = db.getSiblingDB('stackoverflow_ref');
const embDb = db.getSiblingDB('stackoverflow_emb');

/* ── escrita de CSV (mesma convenção de aspas do Projeto 1) ────────────────── */
function csvCell(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'True' : 'False';   // como no P1
  return '"' + String(v).replace(/"/g, '""') + '"';
}
function csvInit(file, header) {
  if (APPEND) return;   // preserva CSVs de cenários já medidos
  fs.writeFileSync(`${OUT_DIR}/${file}`, header.join(',') + '\n');
}
function csvAppend(file, rows) {
  const txt = rows.map(r => r.map(csvCell).join(',')).join('\n') + '\n';
  fs.appendFileSync(`${OUT_DIR}/${file}`, txt);
}

const RUNS_FILE    = 'runs_mongo.csv';
const RESULTS_FILE = 'results_mongo.csv';
const IDX_FILE     = 'mongo_index_creation.csv';
const EXPLAIN_FILE = 'mongo_explain.csv';
const STORAGE_FILE = 'storage_mongo.csv';

let runId = APPEND ? 1000000 : 0;   // evita colisão de id ao acrescentar
csvInit(RUNS_FILE, ['id','created_at','scenario','operation','test_name',
                    'run_number','time_ms','rows_affected','is_warmup','index_state']);
csvInit(RESULTS_FILE, ['scenario','operation','test_name','repetitions',
                       'mean_ms','stddev_ms','min_ms','max_ms','index_state']);
csvInit(IDX_FILE, ['scenario','index_name','create_cmd','time_ms']);
csvInit(EXPLAIN_FILE, ['scenario','index_state','operation','test_name','plan_line']);
csvInit(STORAGE_FILE, ['scenario','object','size_bytes','index_size_bytes',
                       'data_size_bytes','doc_count','state']);

/* ── protocolo de medição (espelho do run_benchmark do P1) ─────────────────── */
function runBenchmark(scenario, indexState, operation, testName, fn, opts = {}) {
  const reps   = opts.reps   ?? REPS;
  const warmup = opts.warmup ?? WARMUP;
  const measured = [];
  const phases = [[true, warmup], [false, reps]];
  for (const [isWarmup, n] of phases) {
    for (let i = 1; i <= n; i++) {
      if (opts.setup) opts.setup();
      const t0 = performance.now();
      const affected = fn();
      const ms = performance.now() - t0;
      if (opts.cleanup) opts.cleanup();
      runId += 1;
      csvAppend(RUNS_FILE, [[runId, new Date().toISOString(), scenario, operation,
                             testName, i, ms, affected, isWarmup, indexState]]);
      if (!isWarmup) measured.push(ms);
    }
  }
  const mean = measured.reduce((a, b) => a + b, 0) / measured.length;
  const sd = measured.length > 1
    ? Math.sqrt(measured.reduce((a, b) => a + (b - mean) ** 2, 0) / (measured.length - 1))
    : 0;
  csvAppend(RESULTS_FILE, [[scenario, operation, testName, measured.length,
                            mean, sd, Math.min(...measured), Math.max(...measured),
                            indexState]]);
  print(`  [${scenario}/${indexState}] ${testName}: media=${mean.toFixed(2)}ms ` +
        `dp=${sd.toFixed(2)} (${measured.length} reps)`);
}

/* ── explain("executionStats") — resumo em CSV + JSON completo em arquivo ──── */
function summarizeStages(stage, acc) {
  if (!stage) return acc;
  acc.push(stage.stage || stage.queryPlan?.stage || '?');
  if (stage.inputStage) summarizeStages(stage.inputStage, acc);
  if (stage.inputStages) stage.inputStages.forEach(s => summarizeStages(s, acc));
  return acc;
}
function saveExplain(scenario, indexState, operation, testName, explainDoc) {
  const fname = `${EXPLAIN_DIR}/${scenario}_${indexState}_${testName}.json`;
  fs.writeFileSync(fname, JSON.stringify(explainDoc, null, 1));
  const rows = [];
  const push = l => rows.push([scenario, indexState, operation, testName, l]);
  try {
    // explain de aggregate: stats no topo ou por estágio ($cursor)
    const es = explainDoc.executionStats
      || explainDoc.stages?.[0]?.$cursor?.executionStats;
    const qp = explainDoc.queryPlanner
      || explainDoc.stages?.[0]?.$cursor?.queryPlanner;
    if (qp) {
      const chain = summarizeStages(qp.winningPlan, []).join(' <- ');
      push(`winningPlan: ${chain}`);
      const idx = JSON.stringify(qp.winningPlan?.inputStage?.indexName
        || qp.winningPlan?.indexName
        || qp.winningPlan?.queryPlan?.inputStage?.indexName || null);
      push(`indexName: ${idx}`);
    }
    if (es) {
      push(`nReturned: ${es.nReturned}  totalKeysExamined: ${es.totalKeysExamined}  ` +
           `totalDocsExamined: ${es.totalDocsExamined}  executionTimeMillis: ${es.executionTimeMillis}`);
    }
    if (explainDoc.stages) {
      push('pipelineStages: ' + explainDoc.stages.map(s => Object.keys(s)[0]).join(' -> '));
    }
  } catch (e) {
    push(`erro_resumo: ${e.message}`);
  }
  push(`json_completo: results/data/explain_mongo/${scenario}_${indexState}_${testName}.json`);
  csvAppend(EXPLAIN_FILE, rows);
}

/* ── armazenamento: db.coll.stats() ───────────────────────── */
function snapshotStorage(scenario, database, colls, state) {
  for (const c of colls) {
    const s = database[c].stats();
    csvAppend(STORAGE_FILE, [[scenario, c, s.storageSize, s.totalIndexSize,
                              s.size, s.count, state]]);
  }
  print(`  [${scenario}] storage snapshot (${state}) gravado`);
}

/* ── criação de índice cronometrada (espelho de create_index_timed) ────────── */
function createIndexTimed(scenario, coll, spec, name) {
  const cmd = `db.${coll.getName()}.createIndex(${JSON.stringify(spec)}, {name: "${name}"})`;
  const t0 = performance.now();
  coll.createIndex(spec, { name });
  const ms = performance.now() - t0;
  csvAppend(IDX_FILE, [[scenario, name, cmd, ms]]);
  print(`  [${scenario}] índice ${name}: ${(ms / 1000).toFixed(2)}s`);
}

/* ── aquecimento de cache (equivalente ao pg_prewarm do P1) ────────────────── */
function prewarm(database, colls) {
  for (const c of colls) {
    database[c].aggregate([{ $group: { _id: null, n: { $sum: 1 } } }],
                          { allowDiskUse: true }).toArray();
  }
}

/* ── contagem server-side (equivalente ao count(resultado) do P1) ──────────── */
function countPipe(coll, pipeline) {
  const r = coll.aggregate([...pipeline, { $count: 'n' }],
                           { allowDiskUse: true }).toArray();
  return r.length ? r[0].n : 0;
}

/* ============================================================================
 * Valores de teste determinísticos — MESMOS critérios do benchmark_values_p2
 * do lado PostgreSQL (scripts/postgresql.sql §1.5). Como os dados são idênticos,
 * os alvos resultantes são idênticos.
 * ==========================================================================*/
/* limpeza defensiva ANTES de derivar os alvos (execuções abortadas anteriores
 * não podem deslocar os valores determinísticos) */
refDb.comments.deleteMany({ _id: { $lt: 0 } });
refDb.comments.deleteMany({ _id: { $gte: 210000001, $lte: 220100000 } });
embDb.questions.updateMany({ 'comments._id': { $lt: 0 } },
                           { $pull: { comments: { _id: { $lt: 0 } } } });
for (const t of ['benchmark_insert_lote', 'benchmark_mass_insert',
                 'benchmark_mass_update', 'benchmark_mass_delete']) {
  embDb.questions.updateMany({ 'comments.text': t },
                             { $pull: { comments: { text: t } } });
}

print('Derivando valores de teste deterministicos...');

// pergunta "rica": 20–40 respostas e >= 10 comentários; menor Id
// (mesma semântica do min(q."Id") do lado PG — varre candidatos em ordem)
const candIds = refDb.posts.aggregate([
  { $match: { postTypeId: 2 } },
  { $group: { _id: '$parentId', n: { $sum: 1 } } },
  { $match: { n: { $gte: 20, $lte: 40 } } },
  { $project: { _id: 1 } },
  { $sort: { _id: 1 } },
], { allowDiskUse: true }).toArray().map(c => c._id);
let QUESTION_ID = null;
for (let i = 0; i < candIds.length && QUESTION_ID === null; i += 500) {
  const chunk = candIds.slice(i, i + 500);
  const commentCounts = {};
  refDb.comments.aggregate([
    { $match: { postId: { $in: chunk } } },
    { $group: { _id: '$postId', n: { $sum: 1 } } },
  ], { allowDiskUse: true }).forEach(d => { commentCounts[d._id] = d.n; });
  QUESTION_ID = chunk.find(id => (commentCounts[id] || 0) >= 10) ?? null;
}

// usuário prolífico: 40–60 PERGUNTAS; menor OwnerUserId (T2–T4 são definidos
// sobre perguntas, para equivalência lógica com o modelo embutido)
const OWNER_USER_ID = refDb.posts.aggregate([
  { $match: { postTypeId: 1, ownerUserId: { $ne: null } } },
  { $group: { _id: '$ownerUserId', n: { $sum: 1 } } },
  { $match: { n: { $gte: 40, $lte: 60 } } },
  { $sort: { _id: 1 } },
  { $limit: 1 },
], { allowDiskUse: true }).toArray()[0]._id;

// usuário para comentários inseridos: menor Id com reputação > 1000
const USER_ID = refDb.users.aggregate([
  { $match: { reputation: { $gt: 1000 } } },
  { $sort: { _id: 1 } },
  { $limit: 1 },
  { $project: { _id: 1 } },
], { allowDiskUse: true }).toArray()[0]._id;

// alvos de lote: primeiras N perguntas por Id (mesmo critério do bench_qids_*)
function firstQuestionIds(n) {
  return refDb.posts.aggregate([
    { $match: { postTypeId: 1 } },
    { $project: { _id: 1 } },
    { $sort: { _id: 1 } },
    { $limit: n },
  ], { allowDiskUse: true }).toArray().map(d => d._id);
}
const MASS_N = parseInt(process.env.BENCH_MASS_N || '100000');
const QIDS_1000 = firstQuestionIds(1000);
const QIDS_100K = SKIP_MASS ? [] : firstQuestionIds(MASS_N);
const DATE_LO = new Date('2010-01-01T00:00:00Z');
const DATE_HI = new Date('2010-02-01T00:00:00Z');

print(`  question_id=${QUESTION_ID}  owner_user_id=${OWNER_USER_ID}  user_id=${USER_ID}`);
print(`  qids_1000: ${QIDS_1000.length}  qids_100k: ${QIDS_100K.length}`);

/* fábrica de documentos de comentário (modelo R) */
function refCommentDoc(id, postId, text) {
  return { _id: id, postId, score: 0, text, creationDate: new Date(), userId: USER_ID };
}
/* subdocumento de comentário (modelo E) */
function embCommentDoc(id, text) {
  return { _id: id, text, score: 0, creationDate: new Date(), user: { userId: USER_ID } };
}

/* ============================================================================
 * Definição das tarefas T1–T12 por cenário
 * Cada entrada: {op, name, fn|pipeline, setup, cleanup, explain}
 * ==========================================================================*/

/* ---------- Modelo R (referenciado) --------------------------------------- */
function refTests(d) {
  const posts = d.posts, comments = d.comments;

  // T6 — agregado pergunta+respostas+comentários via $lookup aninhado
  const T6_PIPE = [
    { $match: { _id: QUESTION_ID } },
    { $lookup: { from: 'comments', localField: '_id', foreignField: 'postId',
                 as: 'comments',
                 pipeline: [{ $project: { text: 1, score: 1 } }] } },
    { $lookup: { from: 'posts', localField: '_id', foreignField: 'parentId',
                 as: 'answers',
                 pipeline: [
                   { $lookup: { from: 'comments', localField: '_id',
                                foreignField: 'postId', as: 'comments',
                                pipeline: [{ $project: { text: 1, score: 1 } }] } },
                   { $project: { body: 1, score: 1, comments: 1 } },
                 ] } },
    { $project: { title: 1, body: 1, score: 1, comments: 1, answers: 1 } },
    // materialização server-side + contagem (simetria com count(resultado)):
    // $bsonSize força a montagem completa do documento agregado no servidor
    { $project: { sz: { $bsonSize: '$$ROOT' } } },
  ];
  const T6B_PIPE = [
    { $match: { postTypeId: 1 } },
    { $sort: { score: -1 } },
    { $limit: 20 },
    { $lookup: { from: 'users', localField: 'ownerUserId', foreignField: '_id',
                 as: 'u', pipeline: [{ $project: { displayName: 1 } }] } },
    { $project: { title: 1, score: 1, displayName: { $first: '$u.displayName' } } },
  ];
  const T7_PIPE = [
    { $match: { postTypeId: { $in: [1, 2] } } },
    { $group: { _id: '$ownerUserId', post_count: { $sum: 1 } } },
    { $sort: { post_count: -1 } },
    { $limit: 20 },
  ];

  return [
    // T1 — busca por _id (PK); $bsonSize materializa o doc no servidor e só a
    // contagem cruza o socket (equivalente ao count(resultado) do PG)
    { op: 'SELECT', name: 'select_post_by_pk',
      pipeline: [{ $match: { _id: QUESTION_ID } },
                 { $project: { sz: { $bsonSize: '$$ROOT' } } }],
      coll: () => posts,
      explain: () => posts.find({ _id: QUESTION_ID }).explain('executionStats') },

    // T2 — campo secundário (igualdade; perguntas, como no PG e no emb)
    { op: 'SELECT', name: 'select_posts_by_owner_user_id',
      pipeline: [{ $match: { postTypeId: 1, ownerUserId: OWNER_USER_ID } },
                 { $project: { ownerUserId: 1, title: 1, score: 1, viewCount: 1 } }],
      coll: () => posts },

    // T3 — intervalo de data (perguntas)
    { op: 'SELECT', name: 'select_posts_date_between',
      pipeline: [{ $match: { postTypeId: 1,
                             creationDate: { $gte: DATE_LO, $lt: DATE_HI } } },
                 { $project: { title: 1, creationDate: 1 } }],
      coll: () => posts },

    // T4 — top-N por score (perguntas)
    { op: 'SELECT', name: 'select_posts_order_by_score',
      pipeline: [{ $match: { postTypeId: 1 } },
                 { $sort: { score: -1 } }, { $limit: 20 },
                 { $project: { title: 1, score: 1 } }],
      coll: () => posts },

    // T5 — busca textual: prefixo (regex ancorado) e infixo
    { op: 'SELECT', name: 'select_comments_like_prefix',
      pipeline: [{ $match: { text: { $regex: '^I ' } } }, { $project: { text: 1 } }],
      coll: () => comments },
    { op: 'SELECT', name: 'select_comments_like_infix',
      pipeline: [{ $match: { text: { $regex: 'error' } } }, { $project: { text: 1 } }],
      coll: () => comments },

    // T6 — agregado montado no servidor via $lookup aninhado (1 doc contado)
    { op: 'SELECT', name: 'join_pergunta_respostas',
      pipeline: T6_PIPE, coll: () => posts,
      explain: () => posts.explain('executionStats').aggregate(T6_PIPE) },

    // T6b — junção N:1 com users (top-20 + autor)
    { op: 'SELECT', name: 'join_top_posts_users',
      pipeline: T6B_PIPE, coll: () => posts },

    // T7 — agregação por grupo
    { op: 'SELECT', name: 'agg_group_by_owner',
      pipeline: T7_PIPE, coll: () => posts },

    // T8 — inserção unitária
    { op: 'INSERT', name: 'insert_comment',
      fn: () => comments.insertOne(
        refCommentDoc(-910001, QUESTION_ID, 'benchmark_insert_comment')
      ).insertedId !== undefined ? 1 : 0,
      cleanup: () => comments.deleteOne({ _id: -910001 }) },

    // T9 — lote de 1.000 comentários em 1.000 perguntas
    { op: 'INSERT', name: 'insert_lote_1000',
      setupState: {},
      setup: function () {
        this.docs = QIDS_1000.map((q, i) =>
          refCommentDoc(210000001 + i, q, 'benchmark_insert_lote'));
      },
      fn: function () {
        const r = comments.insertMany(this.docs, { ordered: false });
        return r.insertedCount ?? Object.keys(r.insertedIds).length;
      },
      cleanup: () => comments.deleteMany(
        { _id: { $gte: 210000001, $lte: 210001000 } }) },

    // T10 — update em campo não indexado / indexado
    { op: 'UPDATE', name: 'update_comment_score_non_indexed',
      setup: () => comments.insertOne(
        refCommentDoc(-920002, QUESTION_ID, 'benchmark_update_score')),
      fn: () => comments.updateMany({ text: 'benchmark_update_score' },
                                    { $inc: { score: 1 } }).modifiedCount,
      cleanup: () => comments.deleteOne({ _id: -920002 }),
      explain: () => d.runCommand({ explain: {
        update: 'comments',
        updates: [{ q: { text: 'benchmark_update_score' },
                    u: { $inc: { score: 1 } }, multi: true }] },
        verbosity: 'executionStats' }) },
    { op: 'UPDATE', name: 'update_comment_text_indexed_column',
      setup: () => comments.insertOne(
        refCommentDoc(-920001, QUESTION_ID, 'benchmark_update_text_old')),
      fn: () => comments.updateMany({ text: 'benchmark_update_text_old' },
                                    { $set: { text: 'benchmark_update_text_new' } }).modifiedCount,
      cleanup: () => comments.deleteOne({ _id: -920001 }) },

    // T11 — delete por PK e por coluna comum
    // (cleanup idempotente: o explain de write NO MongoDB não executa a
    //  escrita — diferente do EXPLAIN ANALYZE — e deixaria o marcador para trás)
    { op: 'DELETE', name: 'delete_comment_by_pk',
      setup: () => comments.insertOne(
        refCommentDoc(-930001, QUESTION_ID, 'benchmark_delete_by_pk')),
      fn: () => comments.deleteOne({ _id: -930001 }).deletedCount,
      cleanup: () => comments.deleteOne({ _id: -930001 }) },
    { op: 'DELETE', name: 'delete_comment_by_text',
      setup: () => comments.insertOne(
        refCommentDoc(-930002, QUESTION_ID, 'benchmark_delete_comment')),
      fn: () => comments.deleteMany({ text: 'benchmark_delete_comment' }).deletedCount,
      cleanup: () => comments.deleteOne({ _id: -930002 }),
      explain: () => d.runCommand({ explain: {
        delete: 'comments',
        deletes: [{ q: { text: 'benchmark_delete_comment' }, limit: 0 }] },
        verbosity: 'executionStats' }) },

    // T12 — DML em massa (100k comentários em 100k perguntas)
    ...(SKIP_MASS ? [] : [
      { op: 'INSERT', name: 'mass_insert_100k',
        setup: function () {
          this.docs = QIDS_100K.map((q, i) =>
            refCommentDoc(220000001 + i, q, 'benchmark_mass_insert'));
        },
        fn: function () {
          const r = comments.insertMany(this.docs, { ordered: false });
          return r.insertedCount ?? Object.keys(r.insertedIds).length;
        },
        cleanup: () => comments.deleteMany(
          { _id: { $gte: 220000001, $lte: 220100000 } }) },
      { op: 'UPDATE', name: 'mass_update_100k',
        setup: () => comments.insertMany(
          QIDS_100K.map((q, i) => refCommentDoc(220000001 + i, q, 'benchmark_mass_update')),
          { ordered: false }),
        fn: () => comments.updateMany({ text: 'benchmark_mass_update' },
                                      { $inc: { score: 1 } }).modifiedCount,
        cleanup: () => comments.deleteMany(
          { _id: { $gte: 220000001, $lte: 220100000 } }) },
      { op: 'DELETE', name: 'mass_delete_100k',
        setup: () => comments.insertMany(
          QIDS_100K.map((q, i) => refCommentDoc(220000001 + i, q, 'benchmark_mass_delete')),
          { ordered: false }),
        fn: () => comments.deleteMany({ text: 'benchmark_mass_delete' }).deletedCount,
        cleanup: () => comments.deleteMany(
          { _id: { $gte: 220000001, $lte: 220100000 } }) },
    ]),
  ];
}

/* ---------- Modelo E (embutido) -------------------------------------------- */
function embTests(d) {
  const questions = d.questions;
  const LAST_QID_100K = QIDS_100K.length ? QIDS_100K[QIDS_100K.length - 1] : null;

  // T7 — posts por usuário no modelo E: pergunta + respostas embutidas
  // (mostra o custo de agrupar sobre o agregado desnormalizado)
  const T7_PIPE = [
    { $project: { owners: { $concatArrays: [
      [{ $ifNull: ['$owner.userId', null] }],
      { $map: { input: { $ifNull: ['$answers', []] },
                in: { $ifNull: ['$$this.owner.userId', null] } } },
    ] } } },
    { $unwind: '$owners' },
    { $group: { _id: '$owners', post_count: { $sum: 1 } } },
    { $sort: { post_count: -1 } },
    { $limit: 20 },
  ];
  // T5 — comentários estão em dois níveis do agregado; após localizar os
  // documentos ($match, que usa índice em com_indice), achata os dois níveis
  // e conta os COMENTÁRIOS que casam (mesma granularidade do PG/ref)
  const likePipe = rx => [
    { $match: { $or: [{ 'comments.text': { $regex: rx } },
                      { 'answers.comments.text': { $regex: rx } }] } },
    { $project: { cs: { $concatArrays: [
        { $ifNull: ['$comments', []] },
        { $reduce: { input: { $ifNull: ['$answers', []] }, initialValue: [],
                     in: { $concatArrays: ['$$value',
                                           { $ifNull: ['$$this.comments', []] }] } } },
    ] } } },
    { $unwind: '$cs' },
    { $match: { 'cs.text': { $regex: rx } } },
    { $project: { text: '$cs.text' } },
  ];

  return [
    // T1 — busca por _id ($bsonSize: materialização no servidor, só contagem
    // cruza o socket — simetria com count(resultado) do PG)
    { op: 'SELECT', name: 'select_post_by_pk',
      pipeline: [{ $match: { _id: QUESTION_ID } },
                 { $project: { sz: { $bsonSize: '$$ROOT' } } }],
      coll: () => questions,
      explain: () => questions.find({ _id: QUESTION_ID }).explain('executionStats') },

    // T2 — campo secundário (perguntas por autor; owner denormalizado)
    { op: 'SELECT', name: 'select_posts_by_owner_user_id',
      pipeline: [{ $match: { 'owner.userId': OWNER_USER_ID } },
                 { $project: { 'owner.userId': 1, title: 1, score: 1, viewCount: 1 } }],
      coll: () => questions },

    // T3 — intervalo de data
    { op: 'SELECT', name: 'select_posts_date_between',
      pipeline: [{ $match: { creationDate: { $gte: DATE_LO, $lt: DATE_HI } } },
                 { $project: { title: 1, creationDate: 1 } }],
      coll: () => questions },

    // T4 — top-N por score
    { op: 'SELECT', name: 'select_posts_order_by_score',
      pipeline: [{ $sort: { score: -1 } }, { $limit: 20 },
                 { $project: { title: 1, score: 1 } }],
      coll: () => questions },

    // T5 — busca textual em subdocumentos (2 níveis)
    { op: 'SELECT', name: 'select_comments_like_prefix',
      pipeline: likePipe('^I '), coll: () => questions },
    { op: 'SELECT', name: 'select_comments_like_infix',
      pipeline: likePipe('error'), coll: () => questions },

    // T6 — LEITURA DIRETA do agregado (tarefa-chave do modelo embutido);
    // o documento inteiro é materializado no servidor ($bsonSize) e contado
    { op: 'SELECT', name: 'join_pergunta_respostas',
      pipeline: [{ $match: { _id: QUESTION_ID } },
                 { $project: { sz: { $bsonSize: '$$ROOT' } } }],
      coll: () => questions,
      explain: () => questions.find({ _id: QUESTION_ID }).explain('executionStats') },

    // T6b — top-20 + autor: owner já denormalizado (sem $lookup)
    { op: 'SELECT', name: 'join_top_posts_users',
      pipeline: [{ $sort: { score: -1 } }, { $limit: 20 },
                 { $project: { title: 1, score: 1, 'owner.displayName': 1 } }],
      coll: () => questions },

    // T7 — agregação por grupo sobre o agregado ($unwind)
    { op: 'SELECT', name: 'agg_group_by_owner',
      pipeline: T7_PIPE, coll: () => questions },

    // T8 — inserir comentário = $push no documento-pai
    { op: 'INSERT', name: 'insert_comment',
      fn: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $push: { comments: embCommentDoc(-910001, 'benchmark_insert_comment') } }
      ).modifiedCount,
      cleanup: () => questions.updateOne(
        { _id: QUESTION_ID }, { $pull: { comments: { _id: -910001 } } }) },

    // T9 — lote de 1.000 comentários em 1.000 perguntas (bulkWrite de $push)
    { op: 'INSERT', name: 'insert_lote_1000',
      setup: function () {
        this.ops = QIDS_1000.map((q, i) => ({
          updateOne: { filter: { _id: q },
                       update: { $push: { comments:
                         embCommentDoc(210000001 + i, 'benchmark_insert_lote') } } } }));
      },
      fn: function () {
        return questions.bulkWrite(this.ops, { ordered: false }).modifiedCount;
      },
      cleanup: () => questions.updateMany(
        { _id: { $in: QIDS_1000 } },
        { $pull: { comments: { text: 'benchmark_insert_lote' } } }) },

    // T10 — update de subdocumento embutido (não indexado / indexado)
    { op: 'UPDATE', name: 'update_comment_score_non_indexed',
      setup: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $push: { comments: embCommentDoc(-920002, 'benchmark_update_score') } }),
      fn: () => questions.updateMany(
        { 'comments.text': 'benchmark_update_score' },
        { $inc: { 'comments.$[c].score': 1 } },
        { arrayFilters: [{ 'c.text': 'benchmark_update_score' }] }).modifiedCount,
      cleanup: () => questions.updateOne(
        { _id: QUESTION_ID }, { $pull: { comments: { _id: -920002 } } }),
      explain: () => d.runCommand({ explain: {
        update: 'questions',
        updates: [{ q: { 'comments.text': 'benchmark_update_score' },
                    u: { $inc: { 'comments.$[c].score': 1 } },
                    arrayFilters: [{ 'c.text': 'benchmark_update_score' }],
                    multi: true }] },
        verbosity: 'executionStats' }) },
    { op: 'UPDATE', name: 'update_comment_text_indexed_column',
      setup: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $push: { comments: embCommentDoc(-920001, 'benchmark_update_text_old') } }),
      fn: () => questions.updateMany(
        { 'comments.text': 'benchmark_update_text_old' },
        { $set: { 'comments.$[c].text': 'benchmark_update_text_new' } },
        { arrayFilters: [{ 'c.text': 'benchmark_update_text_old' }] }).modifiedCount,
      cleanup: () => questions.updateOne(
        { _id: QUESTION_ID }, { $pull: { comments: { _id: -920001 } } }) },

    // T11 — delete de subdocumento: via PK do pai ($pull) e por campo comum
    { op: 'DELETE', name: 'delete_comment_by_pk',
      setup: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $push: { comments: embCommentDoc(-930001, 'benchmark_delete_by_pk') } }),
      fn: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $pull: { comments: { _id: -930001 } } }).modifiedCount,
      cleanup: () => questions.updateOne(
        { _id: QUESTION_ID }, { $pull: { comments: { _id: -930001 } } }) },
    { op: 'DELETE', name: 'delete_comment_by_text',
      setup: () => questions.updateOne(
        { _id: QUESTION_ID },
        { $push: { comments: embCommentDoc(-930002, 'benchmark_delete_comment') } }),
      fn: () => questions.updateMany(
        { 'comments.text': 'benchmark_delete_comment' },
        { $pull: { comments: { text: 'benchmark_delete_comment' } } }).modifiedCount,
      cleanup: () => questions.updateOne(
        { _id: QUESTION_ID }, { $pull: { comments: { _id: -930002 } } }) },

    // T12 — DML em massa sobre subdocumentos
    ...(SKIP_MASS ? [] : [
      { op: 'INSERT', name: 'mass_insert_100k',
        setup: function () {
          this.ops = QIDS_100K.map((q, i) => ({
            updateOne: { filter: { _id: q },
                         update: { $push: { comments:
                           embCommentDoc(220000001 + i, 'benchmark_mass_insert') } } } }));
        },
        fn: function () {
          return questions.bulkWrite(this.ops, { ordered: false }).modifiedCount;
        },
        cleanup: () => questions.updateMany(
          { _id: { $lte: LAST_QID_100K } },
          { $pull: { comments: { text: 'benchmark_mass_insert' } } }) },
      { op: 'UPDATE', name: 'mass_update_100k',
        setup: () => questions.bulkWrite(
          QIDS_100K.map((q, i) => ({
            updateOne: { filter: { _id: q },
                         update: { $push: { comments:
                           embCommentDoc(220000001 + i, 'benchmark_mass_update') } } } })),
          { ordered: false }),
        fn: () => questions.updateMany(
          { 'comments.text': 'benchmark_mass_update' },
          { $inc: { 'comments.$[c].score': 1 } },
          { arrayFilters: [{ 'c.text': 'benchmark_mass_update' }] }).modifiedCount,
        cleanup: () => questions.updateMany(
          { _id: { $lte: LAST_QID_100K } },
          { $pull: { comments: { text: 'benchmark_mass_update' } } }) },
      { op: 'DELETE', name: 'mass_delete_100k',
        setup: () => questions.bulkWrite(
          QIDS_100K.map((q, i) => ({
            updateOne: { filter: { _id: q },
                         update: { $push: { comments:
                           embCommentDoc(220000001 + i, 'benchmark_mass_delete') } } } })),
          { ordered: false }),
        fn: () => questions.updateMany(
          { 'comments.text': 'benchmark_mass_delete' },
          { $pull: { comments: { text: 'benchmark_mass_delete' } } }).modifiedCount },
    ]),
  ];
}

/* ============================================================================
 * Índices equivalentes
 * ==========================================================================*/
const REF_INDEXES = [
  ['posts',    { ownerUserId: 1 },              'idx_posts_owneruserid'],
  ['posts',    { creationDate: 1 },             'idx_posts_creationdate'],
  ['posts',    { parentId: 1 },                 'idx_posts_parentid'],
  ['posts',    { postTypeId: 1, score: -1 },    'idx_posts_posttype_score'],
  ['comments', { postId: 1 },                   'idx_comments_postid'],
  ['comments', { text: 1 },                     'idx_comments_text'],
];
const EMB_INDEXES = [
  ['questions', { 'owner.userId': 1 },          'idx_questions_owner'],
  ['questions', { creationDate: 1 },            'idx_questions_creationdate'],
  ['questions', { score: -1 },                  'idx_questions_score'],
  ['questions', { 'comments.text': 1 },         'idx_questions_comments_text'],
  ['questions', { 'answers.comments.text': 1 }, 'idx_questions_answers_comments_text'],
];

function dropExtraIndexes(database, colls) {
  for (const c of colls) {
    for (const ix of database[c].getIndexes()) {
      if (ix.name !== '_id_') database[c].dropIndex(ix.name);
    }
  }
}

/* ============================================================================
 * Execução de um cenário completo (sem_indice -> com_indice)
 * ==========================================================================*/
function runScenario(scenario, database, colls, tests, indexes) {
  print(`\n=== Cenário ${scenario} ===`);

  // limpeza defensiva de marcadores de execuções anteriores
  if (scenario === 'mongo_ref') {
    database.comments.deleteMany({ _id: { $lt: 0 } });
    database.comments.deleteMany({ _id: { $gte: 210000001, $lte: 220100000 } });
  } else {
    database.questions.updateMany(
      {}, { $pull: { comments: { _id: { $lt: 0 } } } });
    // marcadores de lote/massa: por texto (ids sentinela dentro de subdocs)
    for (const t of ['benchmark_insert_lote', 'benchmark_mass_insert',
                     'benchmark_mass_update', 'benchmark_mass_delete']) {
      database.questions.updateMany(
        { 'comments.text': t }, { $pull: { comments: { text: t } } });
    }
  }

  for (const state of ['sem_indice', 'com_indice']) {
    if (state === 'sem_indice') {
      dropExtraIndexes(database, colls);
      snapshotStorage(scenario, database, colls, 'inicio_sem_indice');
    } else {
      for (const [coll, spec, name] of indexes) {
        createIndexTimed(scenario, database[coll], spec, name);
      }
      snapshotStorage(scenario, database, colls, 'apos_criacao_indices');
    }
    prewarm(database, colls);   // equivalente ao pg_prewarm (cache quente)

    // 1º passe: testes cronometrados (sem nenhuma execução extra intercalada)
    for (const t of tests) {
      const fn = t.fn
        ? t.fn.bind(t)
        : () => countPipe(t.coll(), t.pipeline);
      runBenchmark(scenario, state, t.op, t.name, fn, {
        setup:   t.setup ? t.setup.bind(t) : undefined,
        cleanup: t.cleanup ? t.cleanup.bind(t) : undefined,
      });
    }
    // 2º passe: planos de execução, ao final do bloco (como no lado PG, em que
    // os save_explain rodam depois de todos os testes do cenário)
    for (const t of tests) {
      try {
        let ex;
        if (t.explain) {
          if (t.setup) t.setup.call(t);
          ex = t.explain();
          if (t.cleanup) t.cleanup.call(t);
        } else if (t.pipeline) {
          ex = t.coll().explain('executionStats')
                 .aggregate(t.pipeline, { allowDiskUse: true });
        }
        if (ex) saveExplain(scenario, state, t.op, t.name, ex);
      } catch (e) {
        print(`  aviso: explain falhou para ${t.name}: ${e.message}`);
      }
    }
  }

  // estado final: derruba índices do benchmark (deixa a base limpa)
  dropExtraIndexes(database, colls);
  snapshotStorage(scenario, database, colls, 'final_pos_benchmark');
}

/* ============================================================================
 * Main
 * ==========================================================================*/
const t0 = performance.now();
print(`MongoDB ${db.version()} — reps=${REPS} warmup=${WARMUP} ` +
      `skip_mass=${SKIP_MASS} cenários=${SCENARIOS.join(',')}`);

if (SCENARIOS.includes('mongo_ref')) {
  runScenario('mongo_ref', refDb, ['posts', 'comments', 'users'],
              refTests(refDb), REF_INDEXES);
}
if (SCENARIOS.includes('mongo_emb')) {
  runScenario('mongo_emb', embDb, ['questions'],
              embTests(embDb), EMB_INDEXES);
}

print(`\nConcluído em ${((performance.now() - t0) / 60000).toFixed(1)} min`);
print(`CSVs em ${OUT_DIR}/: ${RUNS_FILE}, ${RESULTS_FILE}, ${IDX_FILE}, ` +
      `${EXPLAIN_FILE}, ${STORAGE_FILE}`);
