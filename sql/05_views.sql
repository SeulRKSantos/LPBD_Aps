-- =============================================================================
-- 05_views.sql - Views de monitoramento, relatórios e consultas temporais
--   mv_resumo_horario            : VIEW MATERIALIZADA (agregados por hora/sensor)
--   vw_relatorio_producao_diario : relatório diário de produção (sobre a MV)
--   vw_painel_equipamentos       : painel em tempo real (status + alertas + fluxo)
--   vw_alertas_ativos            : alertas não resolvidos
--   fn_disponibilidade / vw_disponibilidade_24h / fn_status_em : tabela temporal
-- =============================================================================
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- VIEW MATERIALIZADA: pré-agrega a telemetria operacional por hora e sensor.
-- Guarda soma e contagem (e não a média) para que médias de períodos maiores
-- possam ser recalculadas corretamente: média = sum(soma) / sum(leituras).
-- Contagens fora do limite usam os limites vigentes no momento do refresh.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_resumo_horario AS
SELECT date_trunc('hour', t.lido_em)                                     AS hora,
       t.sensor_id,
       s.equipamento_id,
       s.tipo_sensor_id,
       count(*)                                                          AS leituras,
       sum(t.valor)                                                      AS soma,
       min(t.valor)                                                      AS minimo,
       max(t.valor)                                                      AS maximo,
       count(*) FILTER (WHERE t.valor > l.normal_max  OR t.valor < l.normal_min)  AS fora_normal,
       count(*) FILTER (WHERE t.valor > l.critico_max OR t.valor < l.critico_min) AS criticas
  FROM telemetria t
  JOIN sensor s ON s.id = t.sensor_id
  LEFT JOIN limite_operacional l ON l.equipamento_id = s.equipamento_id
                                AND l.tipo_sensor_id = s.tipo_sensor_id
 GROUP BY 1, 2, 3, 4
WITH NO DATA;

-- Índice único: obrigatório para REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX ux_mv_resumo_horario ON mv_resumo_horario (hora, sensor_id);
CREATE INDEX ix_mv_resumo_equip_hora     ON mv_resumo_horario (equipamento_id, hora);

-- -----------------------------------------------------------------------------
-- Relatório diário de produção por equipamento e grandeza medida.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_relatorio_producao_diario AS
SELECT m.hora::date                                      AS dia,
       e.codigo                                          AS equipamento,
       e.categoria,
       ts.codigo                                         AS grandeza,
       ts.unidade,
       sum(m.leituras)                                   AS leituras,
       round((sum(m.soma) / sum(m.leituras))::numeric, 2) AS media,
       round(min(m.minimo)::numeric, 2)                  AS minimo,
       round(max(m.maximo)::numeric, 2)                  AS maximo,
       sum(m.fora_normal)                                AS leituras_fora_normal,
       sum(m.criticas)                                   AS leituras_criticas,
       round(100.0 * sum(m.fora_normal) / sum(m.leituras), 3) AS pct_fora_normal
  FROM mv_resumo_horario m
  JOIN equipamento e  ON e.id  = m.equipamento_id
  JOIN tipo_sensor ts ON ts.id = m.tipo_sensor_id
 GROUP BY 1, 2, 3, 4, 5;

-- -----------------------------------------------------------------------------
-- Painel em tempo real (ideal para \watch 1 no psql durante a apresentação).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_painel_equipamentos AS
SELECT e.codigo                                         AS equipamento,
       e.categoria,
       a.nome                                           AS area,
       e.status,
       date_trunc('second', clock_timestamp() - e.status_desde) AS no_status_ha,
       COALESCE(al.abertos, 0)                          AS alertas_abertos,
       al.maior_severidade,
       COALESCE(al.ocorrencias, 0)                      AS ocorrencias,
       COALESCE(fl.leituras_ultimo_min, 0)              AS leituras_ultimo_min
  FROM equipamento e
  JOIN area a ON a.id = e.area_id
  LEFT JOIN LATERAL (
        SELECT count(*) AS abertos, max(x.severidade) AS maior_severidade, sum(x.ocorrencias) AS ocorrencias
          FROM alerta x
         WHERE x.equipamento_id = e.id AND x.situacao <> 'RESOLVIDO') al ON true
  LEFT JOIN LATERAL (
        SELECT count(*) AS leituras_ultimo_min
          FROM telemetria t
          JOIN sensor s ON s.id = t.sensor_id
         WHERE s.equipamento_id = e.id
           AND t.lido_em >= now() - interval '1 minute') fl ON true
 ORDER BY CASE e.status WHEN 'FALHA' THEN 0 WHEN 'ATENCAO' THEN 1 WHEN 'MANUTENCAO' THEN 2
                        WHEN 'DESLIGADO' THEN 3 ELSE 4 END,
          e.codigo;

-- -----------------------------------------------------------------------------
-- Alertas não resolvidos (mais graves e mais recentes primeiro).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_alertas_ativos AS
SELECT x.id,
       e.codigo                                  AS equipamento,
       s.codigo                                  AS sensor,
       ts.codigo                                 AS grandeza,
       x.severidade,
       x.situacao,
       x.ocorrencias,
       round(x.valor_lido::numeric, 2)           AS valor_lido,
       round(x.valor_pico::numeric, 2)           AS valor_pico,
       x.limite_violado,
       ts.unidade,
       x.primeira_ocorrencia,
       x.ultima_ocorrencia,
       x.mensagem
  FROM alerta x
  JOIN equipamento e  ON e.id  = x.equipamento_id
  JOIN sensor s       ON s.id  = x.sensor_id
  JOIN tipo_sensor ts ON ts.id = s.tipo_sensor_id
 WHERE x.situacao <> 'RESOLVIDO'
 ORDER BY x.severidade DESC, x.ultima_ocorrencia DESC;

-- -----------------------------------------------------------------------------
-- CONSULTAS TEMPORAIS sobre equipamento_status_historico
-- -----------------------------------------------------------------------------

-- Tempo em cada status e disponibilidade em uma janela qualquer.
-- Interseção de intervalos: periodo * janela.
CREATE OR REPLACE FUNCTION fn_disponibilidade(p_inicio timestamptz, p_fim timestamptz DEFAULT now())
RETURNS TABLE (
    equipamento        text,
    tempo_operando     interval,
    tempo_atencao      interval,
    tempo_falha        interval,
    tempo_manutencao   interval,
    tempo_observado    interval,
    disponibilidade_pct numeric)
LANGUAGE sql STABLE AS $$
    WITH janela AS (SELECT tstzrange(p_inicio, p_fim, '[)') AS j),
    recortes AS (
        SELECT h.equipamento_id, h.status,
               upper(h.periodo * janela.j) - lower(h.periodo * janela.j) AS dur
          FROM fabrica.equipamento_status_historico h, janela
         WHERE h.periodo && janela.j
    )
    SELECT e.codigo,
           date_trunc('second', COALESCE(sum(r.dur) FILTER (WHERE r.status = 'OPERANDO'),   '0')),
           date_trunc('second', COALESCE(sum(r.dur) FILTER (WHERE r.status = 'ATENCAO'),    '0')),
           date_trunc('second', COALESCE(sum(r.dur) FILTER (WHERE r.status = 'FALHA'),      '0')),
           date_trunc('second', COALESCE(sum(r.dur) FILTER (WHERE r.status = 'MANUTENCAO'), '0')),
           date_trunc('second', COALESCE(sum(r.dur), '0')),
           round(100 * extract(epoch FROM COALESCE(sum(r.dur) FILTER (WHERE r.status IN ('OPERANDO', 'ATENCAO')), '0'))
                 / NULLIF(extract(epoch FROM sum(r.dur)), 0), 2)
      FROM fabrica.equipamento e
      LEFT JOIN recortes r ON r.equipamento_id = e.id
     GROUP BY e.codigo
     ORDER BY e.codigo
$$;

CREATE OR REPLACE VIEW vw_disponibilidade_24h AS
SELECT * FROM fn_disponibilidade(now() - interval '24 hours', now());

-- "Viagem no tempo": qual era o status de cada equipamento em um instante.
CREATE OR REPLACE FUNCTION fn_status_em(p_instante timestamptz)
RETURNS TABLE (equipamento text, status equipamento_status, desde timestamptz, ate timestamptz, motivo text)
LANGUAGE sql STABLE AS $$
    SELECT e.codigo, h.status, lower(h.periodo), upper(h.periodo), h.motivo
      FROM fabrica.equipamento e
      LEFT JOIN fabrica.equipamento_status_historico h
             ON h.equipamento_id = e.id AND h.periodo @> p_instante
     ORDER BY e.codigo
$$;
