/* Dashboard da planta simulada - cliente */
"use strict";

// ----------------------------------------------------------------------------- utilidades
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const nf = new Intl.NumberFormat("pt-BR");
const num = (v, casas = 0) => Number(v).toLocaleString("pt-BR", { minimumFractionDigits: casas, maximumFractionDigits: casas });
const ms = (v) => (v >= 100 ? num(v, 0) : v >= 10 ? num(v, 1) : v >= 1 ? num(v, 2) : num(v, 3));
const hora = (d) => new Date(d).toLocaleTimeString("pt-BR");
const bytes = (b) => (b >= 1073741824 ? num(b / 1073741824, 2) + " GB" : b >= 1048576 ? num(b / 1048576, 1) + " MB" : num(b / 1024, 0) + " kB");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const NOME_STATUS = { OPERANDO: "Operando", ATENCAO: "Atenção", FALHA: "Falha", MANUTENCAO: "Manutenção", DESLIGADO: "Desligado" };
const SINAL_STATUS = { OPERANDO: "sinal-ok", ATENCAO: "sinal-atencao", FALHA: "sinal-falha", MANUTENCAO: "sinal-manutencao", DESLIGADO: "sinal-manutencao" };
const SINAL_SEV = { ATENCAO: "sinal-atencao", CRITICO: "sinal-falha" };
const NOME_SEV = { ATENCAO: "Atenção", CRITICO: "Crítico" };
const COR = {
  processo: "#34536b", tinta: "#1d221f", tinta2: "#535b56", grade: "#c9cec7",
  atencao: "#e8a200", falha: "#c4122f", manutencao: "#2a7092", operando: "#c3c8c1",
  cenario: { A: "#8a918c", B: "#2a78d6", C: "#eb6834", D: "#1baf7a", E: "#eda100" },
};
const DECADAS = [0.001, 0.01, 0.1, 1, 10, 100, 1000];
const NOME_INDICE = {
  bx_btree_id: "B-Tree (id)", bx_btree_tempo: "B-Tree (lido_em)", bx_btree_sensor_tempo: "B-Tree (sensor_id, lido_em)",
  bx_hash_id: "Hash (id)", ix_telemetria_sensor_tempo: "B-Tree (sensor_id, lido_em DESC)",
  ix_telemetria_tempo_brin: "BRIN (lido_em)", telemetria_pkey: "Chave primária (id, lido_em)",
};
const NOME_CENARIO = {
  A: "A) Tabela única sem índices", B: "B) Tabela única + B-Tree", C: "C) Tabela única + Hash (id)",
  D: "D) Particionada por dia + índices", E: "E) View materializada",
};

async function api(url, corpo) {
  const r = await fetch(url, corpo === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(corpo) });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.erro || `Erro ${r.status}`);
  return d;
}

let avisoTimer;
function aviso(texto, tipo = "info") {
  const el = $("#aviso");
  el.textContent = texto;
  el.dataset.tipo = tipo;
  el.hidden = false;
  clearTimeout(avisoTimer);
  avisoTimer = setTimeout(() => (el.hidden = true), tipo === "erro" ? 7000 : 3500);
}

// ----------------------------------------------------------------------------- Chart.js
Chart.defaults.font.family = "Barlow, system-ui, sans-serif";
Chart.defaults.font.size = 12;
Chart.defaults.color = COR.tinta2;
Chart.defaults.borderColor = COR.grade;
Chart.defaults.animation = false;
Chart.defaults.maintainAspectRatio = false;
Chart.defaults.plugins.legend.labels.boxWidth = 12;
Chart.defaults.plugins.tooltip.backgroundColor = "#1d221f";

// Rótulo de valor na ponta de cada barra (o texto usa a cor da tinta, não a da série)
const rotulosBarras = {
  id: "rotulosBarras",
  afterDatasetsDraw(chart, _a, opts) {
    if (!opts || !opts.formatar) return;
    const { ctx } = chart;
    ctx.save();
    ctx.font = "500 11px Barlow, sans-serif";
    ctx.fillStyle = COR.tinta;
    const horizontal = chart.options.indexAxis === "y";
    chart.data.datasets.forEach((ds, i) => {
      const meta = chart.getDatasetMeta(i);
      if (meta.hidden) return;
      meta.data.forEach((barra, j) => {
        const v = ds.data[j];
        if (v === null || v === undefined) return;
        const texto = opts.formatar(v, ds, j);
        if (horizontal) { ctx.textBaseline = "middle"; ctx.textAlign = "left"; ctx.fillText(texto, barra.x + 4, barra.y); }
        else { ctx.textBaseline = "bottom"; ctx.textAlign = "center"; ctx.fillText(texto, barra.x, barra.y - 3); }
      });
    });
    ctx.restore();
  },
};
Chart.register(rotulosBarras);

const graficos = {};
function grafico(id, config) {
  if (graficos[id]) graficos[id].destroy();
  graficos[id] = new Chart(document.getElementById(id), config);
  return graficos[id];
}

// ----------------------------------------------------------------------------- abas
const carregadas = new Set();
function abrirAba(botao) {
  $$(".aba").forEach((b) => {
    const ativa = b === botao;
    b.setAttribute("aria-selected", ativa);
    b.tabIndex = ativa ? 0 : -1;
    document.getElementById(b.getAttribute("aria-controls")).hidden = !ativa;
  });
  const id = botao.id;
  if (!carregadas.has(id)) {
    carregadas.add(id);
    if (id === "aba-lab") iniciarLaboratorio();
    if (id === "aba-bench") carregarBenchmark();
    if (id === "aba-dados") { carregarParticoes(); carregarLinhaDoTempo(30); carregarRelatorio(); }
  } else if (id === "aba-dados") {
    carregarLinhaDoTempo(janelaAtual);
  }
  history.replaceState(null, "", "#" + id.replace("aba-", ""));
}
$$(".aba").forEach((b) => b.addEventListener("click", () => abrirAba(b)));
$(".abas").addEventListener("keydown", (e) => {
  const abas = $$(".aba");
  const i = abas.indexOf(document.activeElement);
  if (i < 0) return;
  if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
    const n = abas[(i + (e.key === "ArrowRight" ? 1 : abas.length - 1)) % abas.length];
    n.focus(); abrirAba(n);
  }
});

setInterval(() => ($("#relogio").textContent = new Date().toLocaleTimeString("pt-BR")), 1000);

// ----------------------------------------------------------------------------- metadados
let meta = { sensores: [] };
async function carregarMeta() {
  meta = await api("/api/meta");
  const b = meta.banco;
  $("#banco-info").textContent = `${b.banco} no PostgreSQL ${b.versao.split(" ")[0]}${b.pg_cron ? ", pg_cron ativo" : ""}`;
}

// ----------------------------------------------------------------------------- eventos em tempo real
let ultimoRetrato = null;
let jobAtual = null;

function conectar() {
  const es = new EventSource("/api/eventos");
  es.onopen = () => { $("#conexao").dataset.ok = "true"; $("#conexao").textContent = "Conectado"; };
  es.onerror = () => { $("#conexao").dataset.ok = "false"; $("#conexao").textContent = "Reconectando"; };
  es.addEventListener("retrato", (e) => { ultimoRetrato = JSON.parse(e.data); desenharPlanta(ultimoRetrato); atualizarCargaGrafico(); });
  es.addEventListener("alerta", (e) => adicionarFeed(JSON.parse(e.data)));
  es.addEventListener("job", (e) => atualizarJob(JSON.parse(e.data)));
  es.addEventListener("job_log", (e) => registrarLog(JSON.parse(e.data)));
  es.addEventListener("job_fim", (e) => finalizarJob(JSON.parse(e.data)));
  es.addEventListener("erro_banco", (e) => {
    $("#conexao").dataset.ok = "false";
    $("#conexao").textContent = "Banco indisponível";
    console.warn(JSON.parse(e.data).mensagem);
  });
}

// ----------------------------------------------------------------------------- planta
const tiles = new Map();
let assinaturaAlarmes = "";

function desenharPlanta(r) {
  const ultimo = r.vazao.length ? r.vazao[r.vazao.length - 1].lps : 0;
  $("#k-lps").textContent = nf.format(ultimo);
  $("#k-total").textContent = nf.format(r.leituras_total);
  if (r.resumo && r.resumo.alertas_ativos !== undefined) {
    $("#k-alertas").textContent = nf.format(r.resumo.alertas_ativos);
    $("#k-violacoes").textContent = nf.format(r.resumo.violacoes_hoje);
    $("#k-particoes").textContent = nf.format(r.resumo.particoes);
    $("#k-tamanho").textContent = bytes(Number(r.resumo.tamanho_banco));
  }

  // Áreas e equipamentos: criados uma vez, atualizados no lugar (preserva foco)
  const areas = $("#areas");
  for (const e of r.equipamentos) {
    let t = tiles.get(e.codigo);
    if (!t) {
      let area = areas.querySelector(`[data-area="${CSS.escape(e.area)}"] .equips`);
      if (!area) {
        const div = document.createElement("div");
        div.className = "area";
        div.dataset.area = e.area;
        div.innerHTML = `<h3>${esc(e.area)}</h3><div class="equips"></div>`;
        areas.appendChild(div);
        area = div.querySelector(".equips");
      }
      t = document.createElement("button");
      t.className = "equip";
      t.type = "button";
      t.innerHTML = `<span class="equip-codigo">${esc(e.codigo)}</span><span class="equip-nome">${esc(e.nome)}</span>
        <span class="equip-status"><span class="sinal"></span><span class="txt"></span></span><span class="equip-contador"></span>`;
      t.addEventListener("click", () => abrirEquipamento(e.codigo));
      area.appendChild(t);
      tiles.set(e.codigo, t);
    }
    t.dataset.status = e.status;
    const sinal = t.querySelector(".sinal");
    sinal.className = `sinal ${SINAL_STATUS[e.status]}${Number(e.nao_reconhecidos) > 0 ? " piscando" : ""}`;
    t.querySelector(".txt").textContent = NOME_STATUS[e.status] + (Number(e.abertos) ? `, ${e.abertos} alarme${e.abertos > 1 ? "s" : ""}` : "");
    t.querySelector(".equip-contador").textContent = Number(e.ocorrencias) ? `${nf.format(e.ocorrencias)}×` : "";
    t.setAttribute("aria-label", `${e.codigo}, ${e.nome}: ${NOME_STATUS[e.status]}${Number(e.abertos) ? `, ${e.abertos} alarmes abertos` : ""}`);
  }

  // Alarmes
  const assinatura = r.alertas.map((a) => `${a.id}:${a.situacao}:${a.ocorrencias}:${a.severidade}`).join("|");
  if (assinatura !== assinaturaAlarmes) {
    assinaturaAlarmes = assinatura;
    const lista = $("#alarmes");
    if (!r.alertas.length) {
      lista.innerHTML = `<li class="vazio">Nenhum alarme ativo. Insira uma leitura fora da faixa no Laboratório para ver a trigger agir.</li>`;
    } else {
      lista.innerHTML = r.alertas.map((a) => `
        <li class="alarme" data-situacao="${a.situacao}">
          <span class="sinal ${SINAL_SEV[a.severidade]}${a.situacao === "ABERTO" ? " piscando" : ""}" role="img" aria-label="${NOME_SEV[a.severidade]}"></span>
          <span class="alarme-titulo">${esc(a.sensor)} ${NOME_SEV[a.severidade].toLowerCase()}</span>
          <span class="alarme-detalhe">Pico ${num(a.valor_pico, 2)} ${esc(a.unidade)} (limite ${num(a.limite_violado, 1)}), ${nf.format(a.ocorrencias)} ocorrência${a.ocorrencias > 1 ? "s" : ""}, última às ${hora(a.ultima_ocorrencia)}</span>
          <span class="alarme-acoes">
            ${a.situacao === "ABERTO" ? `<button class="btn" data-acao="reconhecer" data-id="${a.id}">Reconhecer</button>` : ""}
            <button class="btn" data-acao="resolver" data-id="${a.id}">Resolver</button>
          </span>
        </li>`).join("");
    }
  }

  // Tendência de vazão
  const g = graficos["g-vazao"] || grafico("g-vazao", {
    type: "line",
    data: { labels: [], datasets: [{ data: [], borderColor: COR.processo, backgroundColor: "rgba(52,83,107,0.12)", fill: true, borderWidth: 2, pointRadius: 0, tension: 0.25 }] },
    options: {
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: (c) => `${nf.format(c.parsed.y)} leituras/s` } } },
      scales: { x: { ticks: { maxTicksLimit: 6 }, grid: { display: false } }, y: { beginAtZero: true, suggestedMax: 100, ticks: { callback: (v) => nf.format(v) } } },
    },
  });
  g.data.labels = r.vazao.map((p) => hora(p.t));
  g.data.datasets[0].data = r.vazao.map((p) => p.lps);
  g.update();
}

$("#alarmes").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-acao]");
  if (!b) return;
  b.disabled = true;
  try {
    await api(`/api/alertas/${b.dataset.id}/${b.dataset.acao}`, {});
    aviso(b.dataset.acao === "reconhecer" ? `Alarme #${b.dataset.id} reconhecido` : `Alarme #${b.dataset.id} resolvido`);
  } catch (err) { aviso(err.message, "erro"); b.disabled = false; }
});
$("#resolver-todos").addEventListener("click", async () => {
  try { await api("/api/alertas/resolver-todos", {}); aviso("Todos os alarmes foram resolvidos"); }
  catch (err) { aviso(err.message, "erro"); }
});

function adicionarFeed(n) {
  const li = document.createElement("li");
  li.className = "novo";
  const status = n.novo_status ? `, equipamento em ${NOME_STATUS[n.novo_status].toLowerCase()}` : ", status mantido";
  li.innerHTML = `<time>${hora(n.lido_em)}</time><span class="sinal ${SINAL_SEV[n.severidade]}" role="img" aria-label="${NOME_SEV[n.severidade]}"></span>
    <span><strong>${esc(n.sensor)}</strong> leu ${num(n.valor, 2)} (limite ${esc(n.limite)})${status}</span>`;
  const feed = $("#feed");
  const vazio = feed.querySelector(".feed-vazio");
  if (vazio) vazio.remove();
  feed.prepend(li);
  requestAnimationFrame(() => setTimeout(() => li.classList.remove("novo"), 50));
  while (feed.children.length > 60) feed.lastChild.remove();
}

// Detalhe do equipamento
async function abrirEquipamento(codigo) {
  const e = ultimoRetrato.equipamentos.find((x) => x.codigo === codigo);
  const sensores = meta.sensores.filter((s) => s.equipamento === codigo);
  const dlg = $("#dlg-equip");
  const manual = e.status === "MANUTENCAO" || e.status === "DESLIGADO";
  $("#dlg-conteudo").innerHTML = `
    <header><div><span class="equip-codigo">${esc(codigo)}</span> <span class="equip-nome">${esc(e.nome)}, ${esc(e.area)}</span></div>
      <span class="chip"><span class="sinal ${SINAL_STATUS[e.status]}"></span>${NOME_STATUS[e.status]}</span></header>
    <table class="sensores-lista"><tbody>
      ${sensores.map((s) => `<tr><td>${esc(s.descricao)}</td><td class="ult" data-id="${s.id}">…</td>
        <td>normal ${num(s.normal_min, 1)} a ${num(s.normal_max, 1)} ${esc(s.unidade)}</td><td><canvas id="spark-${s.id}"></canvas></td></tr>`).join("")}
    </tbody></table>
    <p class="ajuda">Em manutenção ou desligado, a trigger continua registrando alertas, mas não altera o status.</p>
    <div class="linha-botoes">
      ${manual ? `<button class="btn btn-primario" value="OPERANDO" data-status>Retornar à operação</button>`
               : `<button class="btn" value="MANUTENCAO" data-status>Colocar em manutenção</button><button class="btn" value="DESLIGADO" data-status>Desligar</button>`}
      <button class="btn" value="lab" data-lab="${sensores[0] ? sensores[0].id : ""}">Testar no laboratório</button>
      <button class="btn btn-discreto" value="fechar">Fechar</button>
    </div>`;
  dlg.showModal();
  for (const s of sensores) {
    api(`/api/sensor/${s.id}/ultimas`).then((pts) => {
      const cel = dlg.querySelector(`.ult[data-id="${s.id}"]`);
      if (!cel) return;
      cel.textContent = pts.length ? `${num(pts[pts.length - 1].valor, 2)} ${s.unidade}` : "sem leituras recentes";
      const c = document.getElementById(`spark-${s.id}`);
      if (c && pts.length) new Chart(c, {
        type: "line",
        data: { labels: pts.map((p) => p.lido_em), datasets: [{ data: pts.map((p) => p.valor), borderColor: COR.processo, borderWidth: 1.5, pointRadius: 0 }] },
        options: { responsive: false, plugins: { legend: { display: false }, tooltip: { enabled: false } }, scales: { x: { display: false }, y: { display: false } } },
      });
    }).catch(() => {});
  }
}
$("#dlg-conteudo").addEventListener("click", async (ev) => {
  const b = ev.target.closest("button");
  if (!b) return;
  if (b.hasAttribute("data-status")) {
    ev.preventDefault();
    const codigo = $("#dlg-conteudo .equip-codigo").textContent;
    try { await api(`/api/equipamentos/${encodeURIComponent(codigo)}/status`, { status: b.value }); aviso(`${codigo}: ${NOME_STATUS[b.value].toLowerCase()}`); $("#dlg-equip").close(); }
    catch (err) { aviso(err.message, "erro"); }
  } else if (b.hasAttribute("data-lab")) {
    ev.preventDefault();
    $("#dlg-equip").close();
    abrirAba($("#aba-lab"));
    if (b.dataset.lab) { $("#l-sensor").value = b.dataset.lab; selecionarSensor(); }
    $("#l-sensor").focus();
  }
});

// ----------------------------------------------------------------------------- laboratório: leitura manual
let sensorSel = null;
const historicoLeituras = [];

function iniciarLaboratorio() {
  const sel = $("#l-sensor");
  if (!sel.options.length) {
    const grupos = {};
    meta.sensores.forEach((s) => (grupos[s.equipamento] = grupos[s.equipamento] || []).push(s));
    sel.innerHTML = Object.entries(grupos).map(([eq, ss]) =>
      `<optgroup label="${esc(eq)}">${ss.map((s) => `<option value="${s.id}">${esc(s.codigo)}: ${esc(s.descricao)}</option>`).join("")}</optgroup>`).join("");
    selecionarSensor();
  }
  carregarExperimentos();
}

function faixaDoSensor(s) {
  const largura = s.normal_max - s.normal_min;
  const baixo = (s.critico_min ?? s.normal_min - largura * 0.25) - largura * 0.35;
  const alto = (s.critico_max ?? s.normal_max + largura * 0.25) + largura * 0.35;
  return { min: Math.max(s.normal_min >= 0 ? 0 : -Infinity, baixo), max: alto, largura };
}

function selecionarSensor() {
  sensorSel = meta.sensores.find((s) => String(s.id) === $("#l-sensor").value);
  if (!sensorSel) return;
  const s = sensorSel;
  const f = faixaDoSensor(s);
  const pos = (v) => ((v - f.min) / (f.max - f.min)) * 100;
  const zonas = [];
  const cmin = s.critico_min ?? f.min, cmax = s.critico_max ?? f.max;
  if (s.critico_min !== null) zonas.push(["critica", f.min, s.critico_min]);
  zonas.push(["atencao", cmin, s.normal_min], ["normal", s.normal_min, s.normal_max], ["atencao", s.normal_max, cmax]);
  if (s.critico_max !== null) zonas.push(["critica", s.critico_max, f.max]);
  $("#l-faixa").innerHTML = zonas.map(([z, a, b]) => `<span class="zona zona-${z}" style="left:${pos(a)}%;width:${pos(b) - pos(a)}%"></span>`).join("") + `<span class="marcador"></span>`;
  const marcas = [s.critico_min, s.normal_min, s.normal_max, s.critico_max].filter((v) => v !== null);
  $("#l-escala").innerHTML = marcas.map((v) => `<span style="left:${pos(v)}%">${num(v, v % 1 ? 1 : 0)}</span>`).join("");
  $("#l-unidade").textContent = s.unidade;
  const slider = $("#l-slider");
  slider.min = f.min; slider.max = f.max; slider.step = (f.max - f.min) / 400;
  definirValor((s.normal_min + s.normal_max) / 2);
}

function definirValor(v) {
  v = Math.round(v * 100) / 100;
  $("#l-valor").value = v;
  $("#l-slider").value = v;
  const f = faixaDoSensor(sensorSel);
  const m = $("#l-faixa .marcador");
  const p = Math.min(100, Math.max(0, ((v - f.min) / (f.max - f.min)) * 100));
  m.style.left = p + "%";
  m.dataset.valor = num(v, 2);
  m.style.transform = p > 85 ? "scaleX(1)" : "";
}

$("#l-sensor").addEventListener("change", selecionarSensor);
$("#l-slider").addEventListener("input", (e) => definirValor(Number(e.target.value)));
$("#l-valor").addEventListener("input", (e) => { if (e.target.value !== "") definirValor(Number(e.target.value)); });
$$(".atalhos [data-preset]").forEach((b) => b.addEventListener("click", () => {
  const s = sensorSel, larg = s.normal_max - s.normal_min;
  if (b.dataset.preset === "normal") definirValor(s.normal_min + larg * (0.3 + Math.random() * 0.4));
  if (b.dataset.preset === "atencao") definirValor(s.critico_max !== null ? s.normal_max + (s.critico_max - s.normal_max) * 0.5 : s.normal_max + larg * 0.1);
  if (b.dataset.preset === "critico") definirValor(s.critico_max !== null ? s.critico_max + larg * 0.1 : s.critico_min - larg * 0.1);
}));

$("#l-inserir").addEventListener("click", async () => {
  const b = $("#l-inserir");
  b.disabled = true;
  try {
    const r = await api("/api/leitura", { sensor_id: sensorSel.id, valor: Number($("#l-valor").value) });
    mostrarResultadoLeitura(r);
  } catch (err) { aviso(err.message, "erro"); }
  finally { b.disabled = false; }
});

function mostrarResultadoLeitura(r) {
  const s = sensorSel;
  const valor = Number($("#l-valor").value);
  const efeitos = [];
  const a0 = r.antes.alerta, a1 = r.depois.alerta;
  let notificou = false;
  if (!a1 || (a0 && a0.id === a1.id && a0.ocorrencias === a1.ocorrencias)) {
    efeitos.push(["sinal-ok", "Leitura dentro da faixa normal: a trigger terminou sem registrar alerta."]);
  } else if (!a0) {
    notificou = true;
    efeitos.push([SINAL_SEV[a1.severidade], `Alerta #${a1.id} aberto com severidade ${NOME_SEV[a1.severidade].toLowerCase()} (limite ${num(a1.limite_violado, 1)} ${s.unidade}).`]);
  } else {
    efeitos.push([SINAL_SEV[a1.severidade], `Alerta #${a1.id} já estava aberto: ocorrências ${a0.ocorrencias} → ${a1.ocorrencias}. Nenhum alerta duplicado foi criado.`]);
    if (a0.severidade !== a1.severidade) efeitos.push([SINAL_SEV[a1.severidade], `Severidade escalou de ${NOME_SEV[a0.severidade].toLowerCase()} para ${NOME_SEV[a1.severidade].toLowerCase()}.`]);
  }
  if (r.antes.status !== r.depois.status) {
    notificou = true;
    efeitos.push([SINAL_STATUS[r.depois.status], `Status de ${r.equipamento}: ${NOME_STATUS[r.antes.status]} → ${NOME_STATUS[r.depois.status]}. Novo período aberto na tabela temporal.`]);
  } else if (a1 && (r.depois.status === "MANUTENCAO" || r.depois.status === "DESLIGADO")) {
    efeitos.push([SINAL_STATUS[r.depois.status], `${r.equipamento} está em ${NOME_STATUS[r.depois.status].toLowerCase()}: a trigger registrou o alerta mas não alterou o status.`]);
  } else {
    efeitos.push([SINAL_STATUS[r.depois.status], `Status de ${r.equipamento} mantido: ${NOME_STATUS[r.depois.status]}.`]);
  }
  if (notificou) efeitos.push(["sinal-ok", "Notificação publicada no canal alertas_fabrica (veja na Planta ao vivo)."]);

  historicoLeituras.unshift(`${hora(r.leitura.lido_em)}: ${s.codigo} = ${num(valor, 2)} ${s.unidade} (id ${r.leitura.id})`);
  historicoLeituras.length = Math.min(historicoLeituras.length, 5);
  $("#l-resultado").innerHTML = `
    <div class="efeito-tempo">${ms(r.ms)} <small>ms para gravar e executar a trigger</small></div>
    <ul class="efeitos">${efeitos.map(([sinal, t]) => `<li><span class="sinal ${sinal}"></span><span>${esc(t)}</span></li>`).join("")}</ul>
    <div class="historico-leituras">Últimas leituras inseridas:<br>${historicoLeituras.map(esc).join("<br>")}</div>`;
}

// ----------------------------------------------------------------------------- laboratório: carga
$("#f-simulador").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  $("#c-log").textContent = "";
  try { await api("/api/simular", { total: Number(f.get("total")), pct: Number(f.get("pct")), triggers: f.get("triggers") === "on" }); }
  catch (err) { aviso(err.message, "erro"); }
});
$("#f-carga").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  $("#c-log").textContent = "";
  try { await api("/api/carga", { clientes: Number(f.get("clientes")), segundos: Number(f.get("segundos")), pct: Number(f.get("pct")) }); }
  catch (err) { aviso(err.message, "erro"); }
});
$("#c-parar").addEventListener("click", () => api("/api/carga/parar", {}).catch(() => {}));

const NOME_JOB = { simulador: "Simulador em execução", carga: "Carga concorrente em execução", benchmark: "Benchmark em execução", arquivamento: "Arquivamento em execução" };
function atualizarJob(job) {
  jobAtual = job;
  const ind = $("#job-indicador");
  ind.hidden = !job;
  if (job) ind.textContent = NOME_JOB[job.tipo] + (job.progresso ? `, ${job.progresso.restante} s` : "");
  const ocupado = !!job;
  $$("#f-simulador button, #f-carga button[type=submit], #b-executar, #p-arquivar").forEach((b) => (b.disabled = ocupado));
  $("#c-parar").disabled = !(job && job.tipo === "carga");
  $("#c-estado").textContent = job ? NOME_JOB[job.tipo].toLowerCase() : "pronto";
  if (job && job.tipo === "carga" && job.progresso) {
    const p = job.progresso;
    $("#c-numeros").innerHTML = `
      <div><dt>Transações/s</dt><dd>${nf.format(p.tps)}</dd></div>
      <div><dt>Leituras/s</dt><dd>${nf.format(p.lps)}</dd></div>
      <div><dt>Leituras inseridas</dt><dd>${nf.format(p.linhas)}</dd></div>
      <div><dt>Falhas</dt><dd>${nf.format(p.erros)}</dd></div>`;
  }
}

function registrarLog({ tipo, texto }) {
  const alvo = tipo === "benchmark" ? $("#b-log") : tipo === "arquivamento" ? null : $("#c-log");
  if (tipo === "benchmark") $("#b-log").hidden = false;
  if (!alvo) return;
  alvo.textContent += (alvo.textContent ? "\n" : "") + texto;
  alvo.scrollTop = alvo.scrollHeight;
}

function finalizarJob(f) {
  if (f.erro) { aviso(`Falha em ${f.tipo}: ${f.erro}`, "erro"); return; }
  if (f.tipo === "carga") {
    const r = f.resultado;
    $("#c-numeros").innerHTML = `
      <div><dt>Transações/s (média)</dt><dd>${nf.format(r.tps)}</dd></div>
      <div><dt>Leituras/s (média)</dt><dd>${nf.format(r.leituras_por_segundo)}</dd></div>
      <div><dt>Latência p50 / p95</dt><dd>${num(r.latencia_p50_ms, 1)} / ${num(r.latencia_p95_ms, 1)} ms</dd></div>
      <div><dt>Falhas</dt><dd>${nf.format(r.erros)}</dd></div>`;
    registrarLog({ tipo: "carga", texto: `Carga concluída: ${nf.format(r.leituras)} leituras em ${r.transacoes} transações, ${r.clientes} conexões, ${r.segundos} s.` });
    aviso("Carga concorrente concluída");
  }
  if (f.tipo === "simulador") {
    const d = f.resultado && f.resultado.detalhes;
    if (d) $("#c-numeros").innerHTML = `
      <div><dt>Leituras/s (média)</dt><dd>${nf.format(d.leituras_por_segundo)}</dd></div>
      <div><dt>Duração</dt><dd>${num(d.segundos, 1)} s</dd></div>
      <div><dt>Violações tratadas</dt><dd>${nf.format(d.ocorrencias_registradas)}</dd></div>
      <div><dt>Alertas novos</dt><dd>${nf.format(d.alertas_novos)}</dd></div>`;
    aviso("Simulador concluído");
  }
  if (f.tipo === "benchmark") { aviso(`Benchmark concluído em ${num(f.duracao, 0)} s`); carregarBenchmark(); }
  if (f.tipo === "arquivamento") mostrarArquivamento(f.resultado);
  if (carregadas.has("aba-bench") && (f.tipo === "carga" || f.tipo === "simulador")) carregarEscrita();
}

function atualizarCargaGrafico() {
  if ($("#tela-lab").hidden || !ultimoRetrato) return;
  const v = ultimoRetrato.vazao.slice(-90);
  const g = graficos["g-carga"] || grafico("g-carga", {
    type: "line",
    data: { labels: [], datasets: [{ label: "Leituras inseridas por segundo", data: [], borderColor: COR.cenario.B, backgroundColor: "rgba(42,120,214,0.12)", fill: true, borderWidth: 2, pointRadius: 0, tension: 0.2 }] },
    options: { plugins: { legend: { display: false } }, scales: { x: { ticks: { maxTicksLimit: 6 }, grid: { display: false } }, y: { beginAtZero: true, suggestedMax: 100, ticks: { callback: (x) => nf.format(x) } } } },
  });
  g.data.labels = v.map((p) => hora(p.t));
  g.data.datasets[0].data = v.map((p) => p.lps);
  g.update();
}

// ----------------------------------------------------------------------------- laboratório: EXPLAIN
async function carregarExperimentos() {
  const lista = await api("/api/experimentos");
  $("#experimentos").innerHTML = lista.map((e) => `<button class="btn" data-exp="${e.id}">${esc(e.titulo)}</button>`).join("");
}
$("#experimentos").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-exp]");
  if (!b) return;
  $$("#experimentos .btn").forEach((x) => x.setAttribute("aria-pressed", x === b));
  $("#comparacao").innerHTML = `<p class="vazio">Executando as duas consultas no banco…</p>`;
  try { mostrarComparacao(await api("/api/explain", { experimento: b.dataset.exp })); }
  catch (err) { $("#comparacao").innerHTML = `<p class="vazio">${esc(err.message)}</p>`; }
});

function mostrarComparacao(d) {
  const [a, b] = d.variantes;
  const rapida = a.mediana_ms <= b.mediana_ms ? a : b, lenta = rapida === a ? b : a;
  const fator = lenta.mediana_ms / Math.max(rapida.mediana_ms, 0.001);
  const bloco = (v) => `
    <article class="variante">
      <h3>${esc(v.nome)}</h3>
      <div class="variante-tempo">${ms(v.mediana_ms)} <small>ms</small></div>
      <dl>
        <dt>Partições lidas</dt><dd>${v.particoes} de ${v.particoes_total}</dd>
        <dt>Blocos acessados</dt><dd>${nf.format(v.buffers)}</dd>
        <dt>Linhas retornadas</dt><dd>${nf.format(v.linhas)}</dd>
        <dt>Planejamento</dt><dd>${ms(v.planejamento_ms)} ms</dd>
      </dl>
      <div class="mapa-particoes" role="img" aria-label="${v.particoes} de ${v.particoes_total} partições lidas">
        ${Array.from({ length: v.particoes_total }, (_, i) => `<i class="${i < v.particoes ? "lida" : ""}"></i>`).join("")}
      </div>
      <details><summary>Consulta e plano de execução</summary><code class="sql">${esc(v.sql)}</code><pre>${esc(v.plano_texto)}</pre></details>
    </article>`;
  $("#comparacao").innerHTML = `
    <p class="veredito">${esc(rapida.nome)}: <strong>${num(fator, fator >= 10 ? 0 : 1)} vezes mais rápido</strong> (${ms(lenta.mediana_ms)} ms → ${ms(rapida.mediana_ms)} ms).</p>
    ${bloco(a)}${bloco(b)}`;
}

// ----------------------------------------------------------------------------- benchmark
async function carregarBenchmark(execucao) {
  const d = await api("/api/benchmark" + (execucao ? `?execucao=${execucao}` : ""));
  const sel = $("#b-execucao");
  sel.innerHTML = d.execucoes.map((e) => `<option value="${e.execucao}" ${e.execucao === d.execucao ? "selected" : ""}>#${e.execucao}, ${new Date(e.em).toLocaleString("pt-BR")}</option>`).join("");
  if (!d.resultados.length) {
    $("#b-resumo").textContent = "Nenhum benchmark executado ainda. Clique em Executar benchmark.";
    carregarEscrita();
    return;
  }
  const consultas = [...new Set(d.resultados.map((r) => r.consulta))];
  const cenarios = ["A", "B", "C", "D", "E"].filter((c) => d.resultados.some((r) => r.cenario.startsWith(c)));
  const valor = (q, c) => { const r = d.resultados.find((x) => x.consulta === q && x.cenario.startsWith(c)); return r ? Number(r.mediana_ms) : null; };
  $("#b-resumo").textContent = `Execução #${d.execucao}: mediana de ${d.resultados[0].repeticoes} execuções por consulta. Escala logarítmica: cada linha de grade vale 10 vezes a anterior, então barras mais curtas são consultas mais rápidas.`;

  grafico("g-bench", {
    type: "bar",
    data: {
      labels: consultas.map((q) => q.replace(/^(Q\d) /, "$1  ")),
      datasets: cenarios.map((c) => ({ label: NOME_CENARIO[c], data: consultas.map((q) => valor(q, c)), backgroundColor: COR.cenario[c], borderRadius: 3, barPercentage: 0.9, categoryPercentage: 0.82 })),
    },
    options: {
      indexAxis: "y",
      datasets: { bar: { skipNull: true } },
      layout: { padding: { right: 70 } },
      plugins: {
        legend: { position: "bottom" },
        tooltip: { callbacks: { label: (c) => `${c.dataset.label}: ${ms(c.parsed.x)} ms` } },
        rotulosBarras: { formatar: (v) => `${ms(v)} ms` },
      },
      scales: {
        x: { type: "logarithmic", min: 0.001, title: { display: true, text: "Mediana (ms, escala logarítmica)" },
             grid: { color: (c) => (DECADAS.includes(Number(c.tick && c.tick.value)) ? COR.grade : "transparent") },
             ticks: { autoSkip: false, maxRotation: 0, callback: (v) => (DECADAS.includes(Number(v)) ? num(v, v < 1 ? String(v).split(".")[1].length : 0) : "") } },
        y: { grid: { display: false } },
      },
    },
  });

  $("#b-tabela").innerHTML = `<thead><tr><th>Consulta</th><th>Cenário</th><th class="num">Mediana (ms)</th><th class="num">Mín.</th><th class="num">Máx.</th><th class="num">Ganho sobre A</th><th>Plano de execução</th></tr></thead><tbody>${
    consultas.map((q) => {
      const base = valor(q, "A");
      return d.resultados.filter((r) => r.consulta === q).map((r, i) => `
        <tr class="${i === 0 ? "grupo" : ""}"><td>${i === 0 ? esc(q) : ""}</td>
          <td><span class="cenario-cor" style="background:${COR.cenario[r.cenario[0]]}"></span>${esc(r.cenario)}</td>
          <td class="num">${ms(Number(r.mediana_ms))}</td><td class="num">${ms(Number(r.min_ms))}</td><td class="num">${ms(Number(r.max_ms))}</td>
          <td class="num">${base ? num(base / Number(r.mediana_ms), base / Number(r.mediana_ms) >= 10 ? 0 : 1) + "×" : ""}</td>
          <td class="plano">${esc(r.nos_plano)}</td></tr>`).join("");
    }).join("")}</tbody>`;

  const idx = d.indices.map((i) => ({ ...i, mb: Number(i.tamanho_bytes) / 1048576 }));
  grafico("g-indices", {
    type: "bar",
    data: {
      labels: idx.map((i) => `${NOME_INDICE[i.indice] || i.indice}, ${i.cenario === "D" ? "particionada" : "tabela única"}`),
      datasets: [{ data: idx.map((i) => i.mb), backgroundColor: idx.map((i) => (i.cenario === "D" ? COR.cenario.D : i.metodo === "hash" ? COR.cenario.C : COR.cenario.B)), borderRadius: 3 }],
    },
    options: {
      indexAxis: "y", layout: { padding: { right: 60 } },
      plugins: { legend: { display: false }, rotulosBarras: { formatar: (v) => (v >= 1 ? `${num(v, 1)} MB` : `${num(v * 1024, 0)} kB`) },
        tooltip: { callbacks: { label: (c) => `${num(c.parsed.x, 2)} MB` } } },
      scales: { x: { title: { display: true, text: "MB" } }, y: { grid: { display: false } } },
    },
  });
  carregarEscrita();
}
$("#b-execucao").addEventListener("change", (e) => carregarBenchmark(e.target.value));
$("#b-executar").addEventListener("click", async () => {
  $("#b-log").textContent = "";
  $("#b-log").hidden = false;
  try { await api("/api/benchmark", { repeticoes: Number($("#b-rep").value) }); }
  catch (err) { aviso(err.message, "erro"); }
});

async function carregarEscrita() {
  const runs = await api("/api/escrita");
  const tipo = (r) => (r.rotina === "CARGA_CONCORRENTE" ? "concorrente" : r.parametros && r.parametros.triggers === false ? "sem" : "com");
  const cor = { sem: COR.cenario.A, com: COR.cenario.B, concorrente: COR.cenario.D };
  const nome = { sem: "Simulador sem triggers", com: "Simulador com triggers", concorrente: "Carga concorrente" };
  grafico("g-escrita", {
    type: "bar",
    data: {
      labels: runs.map((r) => `#${r.id} ${hora(r.iniciado_em)}`),
      datasets: Object.keys(cor).map((k) => ({
        label: nome[k], backgroundColor: cor[k], borderRadius: 3,
        data: runs.map((r) => (tipo(r) === k ? Number((r.detalhes || {}).leituras_por_segundo || 0) : null)),
      })),
    },
    options: {
      datasets: { bar: { skipNull: true } }, layout: { padding: { top: 18 } },
      plugins: { legend: { position: "bottom" }, rotulosBarras: { formatar: (v) => nf.format(v) },
        tooltip: { callbacks: { label: (c) => `${c.dataset.label}: ${nf.format(c.parsed.y)} leituras/s` } } },
      scales: { y: { beginAtZero: true, title: { display: true, text: "leituras/s" }, ticks: { callback: (v) => nf.format(v) } }, x: { grid: { display: false } } },
    },
  });
}

// ----------------------------------------------------------------------------- dados: partições e arquivamento
async function carregarParticoes() {
  const d = await api("/api/particoes");
  const rot = (p) => {
    const m = p.match(/(\d{4})(\d{2})(\d{2})?$/);
    if (!m) return p.replace("fabrica.", "");
    return m[3] ? `${m[3]}/${m[2]}` : `${m[2]}/${m[1]} (hist.)`;
  };
  const totalOp = d.operacional.reduce((s, p) => s + Number(p.linhas), 0);
  const totalHist = d.historico.reduce((s, p) => s + Number(p.linhas), 0);
  $("#p-resumo").textContent = `${nf.format(totalOp)} leituras na tabela operacional (${d.operacional.length} partições diárias com dados, ${d.total_particoes} no total) e ${nf.format(totalHist)} na tabela histórica (${d.historico.length} ${d.historico.length === 1 ? "partição mensal" : "partições mensais"}).`;
  const todas = [...d.historico.map((p) => ({ ...p, hist: true })), ...d.operacional];
  grafico("g-particoes", {
    type: "bar",
    data: {
      labels: todas.map((p) => rot(p.particao)),
      datasets: [
        { label: "Histórico (mensal)", data: todas.map((p) => (p.hist ? Number(p.linhas) : null)), backgroundColor: COR.cenario.A, borderRadius: 3 },
        { label: "Operacional (diária)", data: todas.map((p) => (p.hist ? null : Number(p.linhas))), backgroundColor: COR.processo, borderRadius: 3 },
      ],
    },
    options: {
      datasets: { bar: { skipNull: true } },
      plugins: { legend: { position: "bottom" }, tooltip: { callbacks: { label: (c) => `${nf.format(c.parsed.y)} leituras` } } },
      scales: { y: { beginAtZero: true, ticks: { callback: (v) => nf.format(v) } }, x: { grid: { display: false }, ticks: { autoSkip: true, maxRotation: 0 } } },
    },
  });
}
$("#p-atualizar").addEventListener("click", carregarParticoes);
$("#p-arquivar").addEventListener("click", async () => {
  $("#p-resultado").innerHTML = `<p class="vazio">Arquivando…</p>`;
  try { await api("/api/arquivar", { dias: 30 }); }
  catch (err) { aviso(err.message, "erro"); $("#p-resultado").innerHTML = ""; }
});
function mostrarArquivamento(r) {
  if (!r) return;
  const movidas = (r.log.detalhes && r.log.detalhes.movidas) || [];
  $("#p-resultado").innerHTML = `
    <div class="tabela-rolagem"><table class="tabela"><thead><tr><th>Momento</th><th class="num">Tabela operacional</th><th class="num">Tabela histórica</th><th>Leitura mais antiga</th></tr></thead>
    <tbody><tr><td>Antes</td><td class="num">${nf.format(r.antes.operacional)}</td><td class="num">${nf.format(r.antes.historico)}</td><td>${r.antes.mais_antiga ? new Date(r.antes.mais_antiga).toLocaleString("pt-BR") : "–"}</td></tr>
    <tr><td>Depois</td><td class="num">${nf.format(r.depois.operacional)}</td><td class="num">${nf.format(r.depois.historico)}</td><td>${r.depois.mais_antiga ? new Date(r.depois.mais_antiga).toLocaleString("pt-BR") : "–"}</td></tr></tbody></table></div>
    <p class="ajuda">${movidas.length ? `${nf.format(r.log.linhas)} leituras movidas de ${movidas.length} partições em ${num(r.log.detalhes.segundos, 2)} s.` : "Nenhuma partição com mais de 30 dias: nada a arquivar."}</p>`;
  carregarParticoes();
}

// ----------------------------------------------------------------------------- dados: linha do tempo (tabela temporal)
let janelaAtual = 30;
$$(".btn-janela").forEach((b) => b.addEventListener("click", () => {
  $$(".btn-janela").forEach((x) => x.setAttribute("aria-pressed", x === b));
  carregarLinhaDoTempo(Number(b.dataset.min));
}));
async function carregarLinhaDoTempo(minutos) {
  janelaAtual = minutos;
  const d = await api(`/api/linha-do-tempo?minutos=${minutos}`);
  const agora = new Date(d.agora).getTime();
  const inicio = agora - minutos * 60000;
  const codigos = [...new Set(d.disponibilidade.map((x) => x.equipamento))];
  const cores = { OPERANDO: COR.operando, ATENCAO: COR.atencao, FALHA: COR.falha, MANUTENCAO: COR.manutencao, DESLIGADO: "#6b7a82" };
  const porStatus = {};
  for (const p of d.periodos) {
    const a = Math.max(inicio, new Date(p.inicio).getTime());
    const b = p.fim ? new Date(p.fim).getTime() : agora;
    (porStatus[p.status] = porStatus[p.status] || []).push({ x: [a, b], y: p.codigo, motivo: p.motivo });
  }
  grafico("g-linha", {
    type: "bar",
    data: {
      labels: codigos,
      datasets: Object.entries(porStatus).map(([st, dados]) => ({ label: NOME_STATUS[st], data: dados, backgroundColor: cores[st], borderSkipped: false, barPercentage: 0.75 })),
    },
    options: {
      indexAxis: "y",
      datasets: { bar: { grouped: false } },
      plugins: {
        legend: { position: "bottom" },
        tooltip: { callbacks: {
          title: (c) => c[0].raw.y,
          label: (c) => `${c.dataset.label}: ${hora(c.raw.x[0])} a ${hora(c.raw.x[1])}`,
          afterLabel: (c) => c.raw.motivo || "",
        } },
      },
      scales: {
        x: { type: "linear", min: inicio, max: agora, ticks: { callback: (v) => new Date(v).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" }), maxTicksLimit: 8 } },
        y: { grid: { display: false } },
      },
    },
  });
  const f = (iv) => (typeof iv === "string" ? iv : iv ? `${String(iv.hours || 0).padStart(2, "0")}:${String(iv.minutes || 0).padStart(2, "0")}:${String(iv.seconds || 0).padStart(2, "0")}` : "00:00:00");
  $("#t-disp").innerHTML = `<thead><tr><th>Equipamento</th><th class="num">Operando</th><th class="num">Atenção</th><th class="num">Falha</th><th class="num">Manutenção</th><th class="num">Disponibilidade</th></tr></thead><tbody>${
    d.disponibilidade.map((x) => `<tr><td>${esc(x.equipamento)}</td><td class="num">${f(x.tempo_operando)}</td><td class="num">${f(x.tempo_atencao)}</td><td class="num">${f(x.tempo_falha)}</td><td class="num">${f(x.tempo_manutencao)}</td><td class="num">${x.disponibilidade_pct === null ? "–" : num(x.disponibilidade_pct, 1) + "%"}</td></tr>`).join("")}</tbody>`;
}

// ----------------------------------------------------------------------------- dados: relatório (view materializada)
async function carregarRelatorio() {
  const d = await api("/api/relatorio");
  $("#r-info").textContent = d.atualizado_em ? `Última atualização da view materializada: ${new Date(d.atualizado_em).toLocaleString("pt-BR")}.${meta.banco && meta.banco.pg_cron ? " O pg_cron a atualiza a cada 5 minutos." : " Sem pg_cron neste banco: use o botão ou o crontab."}` : "A view ainda não foi atualizada.";
  $("#t-relatorio").innerHTML = d.linhas.length ? `<thead><tr><th>Equipamento</th><th>Grandeza</th><th class="num">Leituras</th><th class="num">Média</th><th class="num">Mínimo</th><th class="num">Máximo</th><th class="num">Fora do normal</th><th class="num">Críticas</th><th class="num">% fora do normal</th></tr></thead><tbody>${
    d.linhas.map((l) => `<tr><td>${esc(l.equipamento)}</td><td>${esc(l.grandeza)} (${esc(l.unidade)})</td><td class="num">${nf.format(l.leituras)}</td><td class="num">${num(l.media, 2)}</td><td class="num">${num(l.minimo, 2)}</td><td class="num">${num(l.maximo, 2)}</td><td class="num">${nf.format(l.leituras_fora_normal)}</td><td class="num">${nf.format(l.leituras_criticas)}</td><td class="num">${num(l.pct_fora_normal, 2)}%</td></tr>`).join("")}</tbody>`
    : `<tbody><tr><td class="vazio">Sem dados de hoje na view. Gere leituras e clique em Atualizar view materializada.</td></tr></tbody>`;
}
$("#r-atualizar").addEventListener("click", async () => {
  try { const r = await api("/api/relatorios/atualizar", {}); aviso(`View materializada atualizada em ${nf.format(r.ms)} ms`); carregarRelatorio(); }
  catch (err) { aviso(err.message, "erro"); }
});

// ----------------------------------------------------------------------------- início
(async function iniciar() {
  try { await carregarMeta(); } catch (e) { aviso("Não foi possível ler o banco: " + e.message, "erro"); }
  conectar();
  const alvo = { lab: "aba-lab", bench: "aba-bench", dados: "aba-dados" }[location.hash.slice(1)];
  if (alvo) abrirAba(document.getElementById(alvo));
})();
