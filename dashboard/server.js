// =============================================================================
// Dashboard da APS LPBD - servidor (Express + PostgreSQL + Server-Sent Events)
//   - envia um "retrato" da planta a cada segundo para todos os navegadores
//   - repassa em tempo real as notificações da trigger (LISTEN alertas_fabrica)
//   - executa as demonstrações: leitura manual, simulador, carga concorrente,
//     benchmark, EXPLAIN comparativo, arquivamento e tratamento de alertas
// Uso: npm start   (variáveis opcionais: PGHOST, PGPORT, PGUSER, PGPASSWORD,
//                   PGDATABASE, PORT, HOST)
// =============================================================================
const path = require("path");
const os = require("os");
const express = require("express");
const { Pool, Client } = require("pg");

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || "127.0.0.1";

const configBanco = {
  host: process.env.PGHOST || "/var/run/postgresql",
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || os.userInfo().username,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE || "fabrica_iot",
  application_name: "dashboard-aps-lpbd",
};

const pool = new Pool({ ...configBanco, max: 8 });
pool.on("error", (e) => console.error("[pool]", e.message));

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));
app.get("/vendor/chart.js", (req, res) => res.sendFile(path.join(__dirname, "node_modules/chart.js/dist/chart.umd.min.js")));
app.use("/vendor/fontes/barlow", express.static(path.join(__dirname, "node_modules/@fontsource/barlow/files")));
app.use("/vendor/fontes/barlow-condensed", express.static(path.join(__dirname, "node_modules/@fontsource/barlow-condensed/files")));

const q = (sql, params) => pool.query(sql, params);
const um = async (sql, params) => (await q(sql, params)).rows[0];

// -----------------------------------------------------------------------------
// Server-Sent Events
// -----------------------------------------------------------------------------
const clientes = new Set();
function enviar(evento, dados) {
  const msg = `event: ${evento}\ndata: ${JSON.stringify(dados)}\n\n`;
  for (const res of clientes) res.write(msg);
}

app.get("/api/eventos", (req, res) => {
  res.set({ "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
  res.flushHeaders();
  res.write(`event: job\ndata: ${JSON.stringify(estadoJob())}\n\n`);
  if (ultimoRetrato) res.write(`event: retrato\ndata: ${JSON.stringify(ultimoRetrato)}\n\n`);
  clientes.add(res);
  req.on("close", () => clientes.delete(res));
});
setInterval(() => { for (const res of clientes) res.write(": ping\n\n"); }, 20000);

// -----------------------------------------------------------------------------
// Retrato da planta (1x por segundo). A vazão vem da diferença do contador da
// sequência de telemetria entre duas leituras: custo zero, mesmo sob carga.
// -----------------------------------------------------------------------------
let ultimoRetrato = null;
let anterior = null; // { t, valor }
const historicoVazao = []; // [{ t, lps }]
let sequencia = null;

async function retrato() {
  if (!sequencia) {
    sequencia = (await um("SELECT pg_get_serial_sequence('fabrica.telemetria', 'id') AS s")).s;
  }
  const agora = Date.now();
  const c = await um(`SELECT last_value::bigint AS v, is_called FROM ${sequencia}`);
  const valor = Number(c.is_called ? c.v : c.v - 1);
  if (anterior) {
    const dt = (agora - anterior.t) / 1000;
    historicoVazao.push({ t: agora, lps: Math.max(0, Math.round((valor - anterior.valor) / dt)) });
    while (historicoVazao.length > 120) historicoVazao.shift();
  }
  anterior = { t: agora, valor };

  const leve = jobAtual && jobAtual.tipo === "benchmark"; // não disputar recursos com o benchmark
  const [equip, alertas, resumo] = await Promise.all([
    q(`SELECT e.id, e.codigo, e.nome, e.categoria, a.nome AS area, e.status, e.status_desde,
              COALESCE(al.abertos, 0) AS abertos, al.maior_severidade, COALESCE(al.ocorrencias, 0) AS ocorrencias,
              COALESCE(al.nao_reconhecidos, 0) AS nao_reconhecidos
         FROM fabrica.equipamento e
         JOIN fabrica.area a ON a.id = e.area_id
         LEFT JOIN LATERAL (
              SELECT count(*) AS abertos, max(x.severidade)::text AS maior_severidade,
                     sum(x.ocorrencias) AS ocorrencias,
                     count(*) FILTER (WHERE x.situacao = 'ABERTO') AS nao_reconhecidos
                FROM fabrica.alerta x
               WHERE x.equipamento_id = e.id AND x.situacao <> 'RESOLVIDO') al ON true
        ORDER BY a.id, e.codigo`),
    q(`SELECT x.id, e.codigo AS equipamento, s.codigo AS sensor, ts.codigo AS grandeza, ts.unidade,
              x.severidade::text, x.situacao::text, x.ocorrencias, x.valor_pico, x.limite_violado,
              x.primeira_ocorrencia, x.ultima_ocorrencia
         FROM fabrica.alerta x
         JOIN fabrica.equipamento e ON e.id = x.equipamento_id
         JOIN fabrica.sensor s ON s.id = x.sensor_id
         JOIN fabrica.tipo_sensor ts ON ts.id = s.tipo_sensor_id
        WHERE x.situacao <> 'RESOLVIDO'
        ORDER BY x.severidade DESC, x.ultima_ocorrencia DESC
        LIMIT 40`),
    leve ? Promise.resolve({ rows: [{}] }) : q(`SELECT
          (SELECT count(*) FROM fabrica.alerta WHERE situacao <> 'RESOLVIDO') AS alertas_ativos,
          (SELECT COALESCE(sum(ocorrencias), 0) FROM fabrica.alerta WHERE registrado_em >= current_date) AS violacoes_hoje,
          (SELECT count(*) FROM pg_inherits WHERE inhparent = 'fabrica.telemetria'::regclass) AS particoes,
          pg_database_size(current_database()) AS tamanho_banco`),
  ]);

  ultimoRetrato = {
    t: agora,
    leituras_total: valor,
    vazao: historicoVazao,
    equipamentos: equip.rows,
    alertas: alertas.rows,
    resumo: resumo.rows[0],
    job: estadoJob(),
  };
  enviar("retrato", ultimoRetrato);
}

let retratoRodando = false;
setInterval(async () => {
  if (retratoRodando) return;
  retratoRodando = true;
  try { await retrato(); } catch (e) { enviar("erro_banco", { mensagem: e.message }); }
  finally { retratoRodando = false; }
}, 1000);

// -----------------------------------------------------------------------------
// LISTEN alertas_fabrica -> navegador (reconecta sozinho se cair)
// -----------------------------------------------------------------------------
async function escutar() {
  const c = new Client(configBanco);
  c.on("notification", (n) => {
    try { enviar("alerta", JSON.parse(n.payload)); } catch { /* payload inválido: ignora */ }
  });
  c.on("error", () => setTimeout(escutar, 3000));
  try {
    await c.connect();
    await c.query("LISTEN alertas_fabrica");
    console.log("Escutando o canal alertas_fabrica");
  } catch (e) {
    console.error("[listen]", e.message);
    setTimeout(escutar, 3000);
  }
}

// -----------------------------------------------------------------------------
// Tarefas longas (uma por vez): simulador, carga, benchmark, arquivamento
// -----------------------------------------------------------------------------
let jobAtual = null;
const estadoJob = () => (jobAtual ? { tipo: jobAtual.tipo, inicio: jobAtual.inicio, progresso: jobAtual.progresso || null } : null);

function iniciarJob(tipo, res) {
  if (jobAtual) {
    res.status(409).json({ erro: `Aguarde: "${jobAtual.tipo}" ainda está em execução.` });
    return null;
  }
  jobAtual = { tipo, inicio: Date.now() };
  enviar("job", estadoJob());
  return jobAtual;
}
function finalizarJob(resultado, erro) {
  const tipo = jobAtual && jobAtual.tipo;
  const duracao = jobAtual ? (Date.now() - jobAtual.inicio) / 1000 : 0;
  jobAtual = null;
  enviar("job", null);
  enviar("job_fim", { tipo, duracao, resultado, erro: erro ? erro.message : null });
}

// Executa um CALL em conexão própria, repassando os RAISE NOTICE como log ao vivo.
async function chamarComLog(tipo, sql) {
  const c = new Client(configBanco);
  await c.connect();
  c.on("notice", (m) => enviar("job_log", { tipo, texto: m.message }));
  try { await c.query(sql); } finally { await c.end(); }
}

const inteiro = (v, min, max, padrao) => {
  const n = Math.round(Number(v));
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : padrao;
};
const decimal = (v, min, max, padrao) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : padrao;
};

// Simulador de fluxo (stored procedure)
app.post("/api/simular", (req, res) => {
  const total = inteiro(req.body.total, 1000, 5000000, 100000);
  const pct = decimal(req.body.pct, 0, 20, 0.05);
  const triggers = req.body.triggers !== false;
  if (!iniciarJob("simulador", res)) return;
  res.json({ ok: true });
  const lote = Math.min(50000, total);
  chamarComLog("simulador",
    `CALL fabrica.sp_simular_fluxo(${total}, ${pct}, NULL, NULL, ${lote}, ${triggers})`)
    .then(async () => {
      const log = await um(`SELECT linhas, detalhes FROM fabrica.log_rotina WHERE rotina = 'SIMULADOR_FLUXO' ORDER BY id DESC LIMIT 1`);
      finalizarJob(log);
    })
    .catch((e) => finalizarJob(null, e));
});

// Carga concorrente: N conexões simultâneas, cada transação = 1 gateway
let pararCarga = false;
app.post("/api/carga", async (req, res) => {
  const clientesN = inteiro(req.body.clientes, 1, 64, 16);
  const segundos = inteiro(req.body.segundos, 5, 300, 30);
  const pct = decimal(req.body.pct, 0, 20, 0.02);
  const job = iniciarJob("carga", res);
  if (!job) return;
  res.json({ ok: true });
  pararCarga = false;

  const poolCarga = new Pool({ ...configBanco, max: clientesN, application_name: "dashboard-carga" });
  const nEquip = Number((await um("SELECT max(id) AS n FROM fabrica.equipamento")).n);
  await q("SELECT fabrica.fn_garantir_particoes(current_date, current_date + 1)");
  const fim = Date.now() + segundos * 1000;
  let tx = 0, linhas = 0, erros = 0, txJanela = 0, linhasJanela = 0;
  const latencias = [];

  const relogio = setInterval(() => {
    job.progresso = { tps: txJanela, lps: linhasJanela, tx, linhas, erros, restante: Math.max(0, Math.round((fim - Date.now()) / 1000)), clientes: clientesN };
    enviar("job", estadoJob());
    txJanela = 0; linhasJanela = 0;
  }, 1000);

  const trabalhador = async () => {
    const c = await poolCarga.connect();
    try {
      while (Date.now() < fim && !pararCarga) {
        const equip = 1 + Math.floor(Math.random() * nEquip);
        const t0 = process.hrtime.bigint();
        try {
          const r = await c.query(
            `INSERT INTO fabrica.telemetria (sensor_id, valor)
             SELECT s.id, fabrica.fn_leitura_simulada(s.id, $2) FROM fabrica.sensor s
              WHERE s.equipamento_id = $1 AND s.ativo`, [equip, pct]);
          tx++; txJanela++; linhas += r.rowCount; linhasJanela += r.rowCount;
          if (latencias.length < 200000) latencias.push(Number(process.hrtime.bigint() - t0) / 1e6);
        } catch { erros++; }
      }
    } finally { c.release(); }
  };

  try {
    await Promise.all(Array.from({ length: clientesN }, trabalhador));
    clearInterval(relogio);
    const dur = (Date.now() - job.inicio) / 1000;
    latencias.sort((a, b) => a - b);
    const p = (x) => (latencias.length ? latencias[Math.min(latencias.length - 1, Math.floor(x * latencias.length))] : 0);
    const resultado = {
      clientes: clientesN, segundos: Math.round(dur), transacoes: tx, leituras: linhas, erros,
      tps: Math.round(tx / dur), leituras_por_segundo: Math.round(linhas / dur),
      latencia_p50_ms: +p(0.5).toFixed(2), latencia_p95_ms: +p(0.95).toFixed(2),
    };
    await q(`INSERT INTO fabrica.log_rotina (rotina, iniciado_em, finalizado_em, situacao, linhas, parametros, detalhes)
             VALUES ('CARGA_CONCORRENTE', to_timestamp($1 / 1000.0), clock_timestamp(), 'OK', $2, $3, $4)`,
      [job.inicio, linhas, { clientes: clientesN, segundos, pct, triggers: true }, resultado]);
    finalizarJob(resultado);
  } catch (e) {
    clearInterval(relogio);
    finalizarJob(null, e);
  } finally {
    poolCarga.end();
  }
});
app.post("/api/carga/parar", (req, res) => { pararCarga = true; res.json({ ok: true }); });

// Benchmark comparativo (sp_executar_benchmark)
app.post("/api/benchmark", (req, res) => {
  const rep = inteiro(req.body.repeticoes, 1, 20, 5);
  if (!iniciarJob("benchmark", res)) return;
  res.json({ ok: true });
  chamarComLog("benchmark", `CALL fabrica.sp_executar_benchmark(${rep})`)
    .then(() => finalizarJob({ ok: true }))
    .catch((e) => finalizarJob(null, e));
});

// Arquivamento (> N dias)
app.post("/api/arquivar", async (req, res) => {
  const dias = inteiro(req.body.dias, 1, 365, 30);
  if (!iniciarJob("arquivamento", res)) return;
  res.json({ ok: true });
  try {
    const contar = () => um(`SELECT (SELECT count(*) FROM fabrica.telemetria) AS operacional,
                                    (SELECT count(*) FROM fabrica.telemetria_historico) AS historico,
                                    (SELECT min(lido_em) FROM fabrica.telemetria) AS mais_antiga`);
    const antes = await contar();
    await chamarComLog("arquivamento", `CALL fabrica.sp_arquivar_telemetria(${dias})`);
    const depois = await contar();
    const log = await um(`SELECT situacao, linhas, detalhes FROM fabrica.log_rotina WHERE rotina = 'ARQUIVAMENTO' ORDER BY id DESC LIMIT 1`);
    finalizarJob({ antes, depois, log });
  } catch (e) { finalizarJob(null, e); }
});

app.post("/api/relatorios/atualizar", async (req, res) => {
  try {
    const t0 = Date.now();
    await q("CALL fabrica.sp_atualizar_relatorios()");
    res.json({ ok: true, ms: Date.now() - t0 });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

// -----------------------------------------------------------------------------
// Leitura manual: mostra exatamente o que a trigger fez
// -----------------------------------------------------------------------------
app.post("/api/leitura", async (req, res) => {
  const sensorId = inteiro(req.body.sensor_id, 1, 1e9, null);
  const valor = Number(req.body.valor);
  if (!sensorId || !Number.isFinite(valor)) return res.status(400).json({ erro: "Informe o sensor e um valor numérico." });

  const c = await pool.connect();
  try {
    const alertaSql = `SELECT id, severidade::text, ocorrencias, valor_pico, limite_violado, situacao::text
                         FROM fabrica.alerta WHERE sensor_id = $1 AND situacao <> 'RESOLVIDO'`;
    const statusSql = `SELECT e.codigo, e.status::text FROM fabrica.sensor s JOIN fabrica.equipamento e ON e.id = s.equipamento_id WHERE s.id = $1`;
    await c.query("BEGIN");
    const antesAlerta = (await c.query(alertaSql, [sensorId])).rows[0] || null;
    const antesStatus = (await c.query(statusSql, [sensorId])).rows[0];
    if (!antesStatus) { await c.query("ROLLBACK"); return res.status(404).json({ erro: "Sensor não encontrado." }); }
    const t0 = process.hrtime.bigint();
    const ins = await c.query("INSERT INTO fabrica.telemetria (sensor_id, valor) VALUES ($1, $2) RETURNING id, lido_em", [sensorId, valor]);
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const depoisAlerta = (await c.query(alertaSql, [sensorId])).rows[0] || null;
    const depoisStatus = (await c.query(statusSql, [sensorId])).rows[0];
    await c.query("COMMIT");
    res.json({ leitura: ins.rows[0], ms, antes: { alerta: antesAlerta, status: antesStatus.status },
      depois: { alerta: depoisAlerta, status: depoisStatus.status }, equipamento: antesStatus.codigo });
  } catch (e) {
    await c.query("ROLLBACK").catch(() => {});
    res.status(500).json({ erro: e.message });
  } finally { c.release(); }
});

// -----------------------------------------------------------------------------
// Alertas e status
// -----------------------------------------------------------------------------
app.post("/api/alertas/:id/reconhecer", async (req, res) => {
  try { await q("CALL fabrica.sp_reconhecer_alerta($1::bigint, 'dashboard')", [inteiro(req.params.id, 1, 1e15, 0)]); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ erro: e.message }); }
});
app.post("/api/alertas/:id/resolver", async (req, res) => {
  try { await q("CALL fabrica.sp_resolver_alerta($1::bigint, 'dashboard', 'Resolvido pelo dashboard')", [inteiro(req.params.id, 1, 1e15, 0)]); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ erro: e.message }); }
});
app.post("/api/alertas/resolver-todos", async (req, res) => {
  try { await q("CALL fabrica.sp_resolver_alerta(NULL, 'dashboard', 'Resolvidos em lote pelo dashboard')"); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ erro: e.message }); }
});
app.post("/api/equipamentos/:codigo/status", async (req, res) => {
  const status = String(req.body.status || "");
  if (!["OPERANDO", "MANUTENCAO", "DESLIGADO"].includes(status)) return res.status(400).json({ erro: "Status inválido." });
  try {
    await q("CALL fabrica.sp_definir_status_manual($1, $2::fabrica.equipamento_status, $3)",
      [req.params.codigo, status, status === "OPERANDO" ? "Retorno à operação (dashboard)" : `Colocado em ${status.toLowerCase()} pelo dashboard`]);
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ erro: e.message }); }
});

// -----------------------------------------------------------------------------
// Consultas para as abas
// -----------------------------------------------------------------------------
app.get("/api/meta", async (req, res) => {
  try {
    const sensores = await q(`SELECT s.id, s.codigo, e.codigo AS equipamento, e.categoria, ts.codigo AS grandeza,
                                     ts.descricao, ts.unidade, l.normal_min, l.normal_max, l.critico_min, l.critico_max
                                FROM fabrica.sensor s
                                JOIN fabrica.equipamento e ON e.id = s.equipamento_id
                                JOIN fabrica.tipo_sensor ts ON ts.id = s.tipo_sensor_id
                                JOIN fabrica.limite_operacional l ON l.equipamento_id = s.equipamento_id AND l.tipo_sensor_id = s.tipo_sensor_id
                               ORDER BY e.codigo, ts.id`);
    const banco = await um(`SELECT current_database() AS banco, current_setting('server_version') AS versao,
                                   EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AS pg_cron`);
    res.json({ sensores: sensores.rows, banco });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/sensor/:id/ultimas", async (req, res) => {
  try {
    const r = await q(`SELECT lido_em, valor FROM fabrica.telemetria
                        WHERE sensor_id = $1 AND lido_em >= now() - interval '6 hours'
                        ORDER BY lido_em DESC LIMIT 60`, [inteiro(req.params.id, 1, 1e9, 0)]);
    res.json(r.rows.reverse());
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/benchmark", async (req, res) => {
  try {
    const execs = await q(`SELECT execucao, min(executado_em) AS em, count(*) AS consultas
                             FROM fabrica.benchmark_resultado GROUP BY execucao ORDER BY execucao DESC`);
    const exec = req.query.execucao ? inteiro(req.query.execucao, 1, 1e9, 0) : execs.rows[0] && execs.rows[0].execucao;
    if (!exec) return res.json({ execucoes: [], resultados: [], indices: [] });
    const r = await q(`SELECT consulta, cenario, repeticoes, media_ms, mediana_ms, min_ms, max_ms, nos_plano
                         FROM fabrica.benchmark_resultado WHERE execucao = $1 ORDER BY consulta, cenario`, [exec]);
    const i = await q(`SELECT cenario, indice, metodo, tamanho_bytes, tempo_criacao_ms FROM fabrica.benchmark_indice
                        WHERE execucao = $1 ORDER BY cenario, indice`, [exec]);
    res.json({ execucao: exec, execucoes: execs.rows, resultados: r.rows, indices: i.rows });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/escrita", async (req, res) => {
  try {
    const r = await q(`SELECT id, rotina, iniciado_em, linhas, parametros, detalhes
                         FROM fabrica.log_rotina
                        WHERE rotina IN ('SIMULADOR_FLUXO', 'CARGA_CONCORRENTE') AND situacao = 'OK'
                        ORDER BY id DESC LIMIT 12`);
    res.json(r.rows.reverse());
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/particoes", async (req, res) => {
  try {
    const op = await q(`SELECT tableoid::regclass::text AS particao, count(*) AS linhas, min(lido_em) AS de
                          FROM fabrica.telemetria GROUP BY 1 ORDER BY 3`);
    const hist = await q(`SELECT tableoid::regclass::text AS particao, count(*) AS linhas, min(lido_em) AS de
                            FROM fabrica.telemetria_historico GROUP BY 1 ORDER BY 3`);
    const tam = await q(`SELECT particao, tamanho_bytes FROM fabrica.vw_particoes`);
    const vazias = await um(`SELECT count(*) AS n FROM fabrica.vw_particoes WHERE tabela_pai = 'telemetria'`);
    res.json({ operacional: op.rows, historico: hist.rows, tamanhos: tam.rows, total_particoes: Number(vazias.n) });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/linha-do-tempo", async (req, res) => {
  const minutos = inteiro(req.query.minutos, 5, 1440, 30);
  try {
    const r = await q(`SELECT e.codigo, h.status::text, lower(h.periodo) AS inicio, upper(h.periodo) AS fim, h.motivo
                         FROM fabrica.equipamento_status_historico h
                         JOIN fabrica.equipamento e ON e.id = h.equipamento_id
                        WHERE h.periodo && tstzrange(now() - make_interval(mins => $1), now())
                        ORDER BY e.codigo, lower(h.periodo)`, [minutos]);
    const disp = await q(`SELECT * FROM fabrica.fn_disponibilidade(now() - make_interval(mins => $1), now())`, [minutos]);
    res.json({ agora: new Date(), minutos, periodos: r.rows, disponibilidade: disp.rows });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

app.get("/api/relatorio", async (req, res) => {
  try {
    const r = await q(`SELECT * FROM fabrica.vw_relatorio_producao_diario WHERE dia = current_date ORDER BY equipamento, grandeza`);
    const at = await um(`SELECT finalizado_em FROM fabrica.log_rotina WHERE rotina = 'REFRESH_RELATORIOS' ORDER BY id DESC LIMIT 1`);
    res.json({ linhas: r.rows, atualizado_em: at && at.finalizado_em });
  } catch (e) { res.status(500).json({ erro: e.message }); }
});

// -----------------------------------------------------------------------------
// Laboratório de EXPLAIN: mesmas perguntas, duas formas de responder
// -----------------------------------------------------------------------------
const EXPERIMENTOS = {
  periodo: {
    titulo: "Filtro de período e partition pruning",
    variantes: [
      { nome: "Sem filtro de período", sql: (p) => `SELECT lido_em, valor FROM fabrica.telemetria WHERE sensor_id = ${p.sensor} ORDER BY lido_em DESC LIMIT 100` },
      { nome: "Com filtro de período (hoje)", sql: (p) => `SELECT lido_em, valor FROM fabrica.telemetria WHERE sensor_id = ${p.sensor} AND lido_em >= current_date AND lido_em < current_date + 1 ORDER BY lido_em DESC LIMIT 100` },
    ],
  },
  relatorio: {
    titulo: "Relatório horário: dados brutos × view materializada",
    variantes: [
      { nome: "Agregando a telemetria", sql: (p) => `SELECT date_trunc('hour', t.lido_em) AS hora, s.equipamento_id, s.tipo_sensor_id, count(*), avg(t.valor), max(t.valor) FROM fabrica.telemetria t JOIN fabrica.sensor s ON s.id = t.sensor_id WHERE t.lido_em >= '${p.dia}' AND t.lido_em < '${p.dia}'::timestamptz + interval '1 day' GROUP BY 1, 2, 3` },
      { nome: "Lendo a view materializada", sql: (p) => `SELECT hora, equipamento_id, tipo_sensor_id, sum(leituras), sum(soma) / sum(leituras), max(maximo) FROM fabrica.mv_resumo_horario WHERE hora >= '${p.dia}' AND hora < '${p.dia}'::timestamptz + interval '1 day' GROUP BY 1, 2, 3` },
    ],
  },
  identificador: {
    titulo: "Busca por identificador em tabela particionada",
    variantes: [
      { nome: "Só pelo id", sql: (p) => `SELECT * FROM fabrica.telemetria WHERE id = ${p.id}` },
      { nome: "Pelo id e pela data da leitura", sql: (p) => `SELECT * FROM fabrica.telemetria WHERE id = ${p.id} AND lido_em >= '${p.dia}' AND lido_em < '${p.dia}'::timestamptz + interval '1 day'` },
    ],
  },
};

function resumirPlano(plano) {
  const nos = [];
  const relacoes = new Set();
  let removidas = 0;
  (function andar(n) {
    if (!n || typeof n !== "object") return;
    if (n["Node Type"]) {
      nos.push(n["Node Type"] + (n["Index Name"] ? ` (${n["Index Name"].replace(/^telemetria_p\d{8}_/, "")})` : ""));
      if (n["Relation Name"]) relacoes.add(n["Relation Name"]);
      if (n["Subplans Removed"]) removidas += n["Subplans Removed"];
    }
    for (const v of Object.values(n)) if (Array.isArray(v)) v.forEach(andar); else if (v && typeof v === "object") andar(v);
  })(plano);
  const particoes = [...relacoes].filter((r) => /^telemetria_(p\d{8}|default)$/.test(r)).length;
  return { nos: [...new Set(nos)], particoes, removidas };
}

app.get("/api/experimentos", (req, res) => {
  res.json(Object.entries(EXPERIMENTOS).map(([id, e]) => ({ id, titulo: e.titulo, variantes: e.variantes.map((v) => v.nome) })));
});

app.post("/api/explain", async (req, res) => {
  const exp = EXPERIMENTOS[req.body.experimento];
  if (!exp) return res.status(400).json({ erro: "Experimento desconhecido." });
  const c = await pool.connect();
  try {
    const p = await (async () => {
      const sensor = (await c.query("SELECT id FROM fabrica.sensor WHERE codigo = 'MOT-01-VIB'")).rows[0].id;
      const dia = (await c.query("SELECT (max(lido_em)::date - 2)::text AS d FROM fabrica.telemetria")).rows[0].d;
      const id = (await c.query(`SELECT id FROM fabrica.telemetria WHERE lido_em >= $1::date AND lido_em < $1::date + 1 LIMIT 1`, [dia])).rows[0];
      return { sensor, dia, id: id ? id.id : 1 };
    })();
    const total = Number((await c.query("SELECT count(*) AS n FROM pg_inherits WHERE inhparent = 'fabrica.telemetria'::regclass")).rows[0].n);
    await c.query("SET jit = off");
    const saida = [];
    for (const v of exp.variantes) {
      const sql = v.sql(p);
      await c.query(`EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ${sql}`); // aquecimento
      const tempos = [];
      let plano;
      for (let i = 0; i < 5; i++) {
        plano = (await c.query(`EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) ${sql}`)).rows[0]["QUERY PLAN"][0];
        tempos.push(plano["Execution Time"]);
      }
      tempos.sort((a, b) => a - b);
      const texto = (await c.query(`EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) ${sql}`)).rows.map((r) => r["QUERY PLAN"]).join("\n");
      const r = resumirPlano(plano.Plan);
      saida.push({
        nome: v.nome, sql, mediana_ms: tempos[2], planejamento_ms: plano["Planning Time"],
        buffers: (plano.Plan["Shared Hit Blocks"] || 0) + (plano.Plan["Shared Read Blocks"] || 0),
        linhas: plano.Plan["Actual Rows"], ...r, particoes_total: total, plano_texto: texto,
      });
    }
    await c.query("RESET jit");
    res.json({ titulo: exp.titulo, parametros: p, variantes: saida });
  } catch (e) {
    res.status(500).json({ erro: e.message });
  } finally { c.release(); }
});

// -----------------------------------------------------------------------------
app.listen(PORT, HOST, async () => {
  try {
    const v = await um("SELECT current_database() AS db, current_user AS u");
    console.log(`Conectado ao banco ${v.db} como ${v.u}`);
  } catch (e) {
    console.error(`Não foi possível conectar ao PostgreSQL (${e.message}). Confira PGHOST/PGUSER/PGDATABASE.`);
  }
  escutar();
  console.log(`Dashboard em http://${HOST === "0.0.0.0" ? "localhost" : HOST}:${PORT}`);
});
