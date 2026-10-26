-- =============================================================================
-- Roteiro da demonstração (interativo, pausa entre as etapas)
-- Execute com:  psql fabrica_iot -f demo/roteiro_demo.sql
-- Em paralelo, deixe abertos:  ./demo/painel.sh   e   ./demo/escutar_alertas.sh
-- Atenção: a etapa 9 arquiva os dados > 30 dias. Para repetir a demonstração
-- do zero, rode ./setup.sh --sem-instalar --recriar
-- =============================================================================
\set ON_ERROR_STOP 1
\pset footer off
SET search_path = fabrica, public;

\echo '\n================ 0. Estado inicial (todos os alertas resolvidos) ================'
CALL sp_resolver_alerta(NULL, 'demo', 'Reinício da demonstração');
UPDATE equipamento SET status = 'OPERANDO', status_desde = clock_timestamp() WHERE status <> 'OPERANDO';
SELECT equipamento, status, alertas_abertos FROM vw_painel_equipamentos;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 1. Esquema: telemetria particionada por dia ================'
SELECT tabela_pai, count(*) AS particoes, sum(linhas_estimadas) AS linhas, pg_size_pretty(sum(tamanho_bytes)) AS tamanho
  FROM vw_particoes GROUP BY tabela_pai;
SELECT particao, limites, linhas_estimadas, tamanho_total
  FROM vw_particoes WHERE tabela_pai = 'telemetria' ORDER BY particao DESC LIMIT 5;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 2. Limites de segurança são POR MÁQUINA ================'
SELECT e.codigo AS equipamento, ts.codigo AS grandeza, l.normal_min, l.normal_max, l.critico_min, l.critico_max
  FROM limite_operacional l
  JOIN equipamento e  ON e.id = l.equipamento_id
  JOIN tipo_sensor ts ON ts.id = l.tipo_sensor_id
 WHERE e.codigo IN ('CALD-01', 'CALD-02') AND ts.codigo = 'TEMP';
\echo 'A mesma leitura de 200 °C é ATENÇÃO na CALD-01 e CRÍTICA na CALD-02.'
\prompt '\nENTER para inserir as duas leituras...' pausa

\echo '\n================ 3. Trigger disparando em tempo real ================'
INSERT INTO telemetria (sensor_id, valor)
SELECT id, 200 FROM sensor WHERE codigo IN ('CALD-01-TEMP', 'CALD-02-TEMP');
SELECT id, equipamento, sensor, severidade, ocorrencias, valor_lido, limite_violado, mensagem
  FROM vw_alertas_ativos WHERE equipamento IN ('CALD-01', 'CALD-02');
SELECT codigo, status, status_desde FROM equipamento WHERE codigo IN ('CALD-01', 'CALD-02');
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 4. Violações repetidas: contador + escalada de severidade ================'
INSERT INTO telemetria (sensor_id, valor)
SELECT id, v FROM sensor, (VALUES (203.0), (205.5), (214.9)) AS x(v) WHERE codigo = 'CALD-01-TEMP';
SELECT id, sensor, severidade, ocorrencias, valor_lido, valor_pico, limite_violado
  FROM vw_alertas_ativos WHERE sensor = 'CALD-01-TEMP';
SELECT codigo, status FROM equipamento WHERE codigo = 'CALD-01';
\echo 'Um único alerta por sensor (índice único parcial + ON CONFLICT): 4 ocorrências, escalou para CRÍTICO.'
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 5. Tabela temporal: histórico de status ================'
SELECT e.codigo, h.status, lower(h.periodo) AS inicio, upper(h.periodo) AS fim, h.motivo
  FROM equipamento_status_historico h JOIN equipamento e ON e.id = h.equipamento_id
 WHERE e.codigo = 'CALD-01'
 ORDER BY lower(h.periodo) DESC LIMIT 4;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 6. Equipamento em MANUTENÇÃO: a trigger registra, mas não altera o status ================'
CALL sp_definir_status_manual('PRE-02', 'MANUTENCAO', 'Troca da vedação do cilindro');
INSERT INTO telemetria (sensor_id, valor) SELECT id, 250 FROM sensor WHERE codigo = 'PRE-02-PRESS';
SELECT equipamento, status, alertas_abertos, maior_severidade FROM vw_painel_equipamentos WHERE equipamento = 'PRE-02';
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 7. Simulador de fluxo: 300 mil leituras COM triggers ================'
CALL sp_simular_fluxo(300000, 0.01);
SELECT id, parametros->>'triggers' AS triggers, linhas,
       detalhes->>'segundos' AS segundos, detalhes->>'leituras_por_segundo' AS leituras_por_s,
       detalhes->>'ocorrencias_registradas' AS violacoes
  FROM log_rotina WHERE rotina = 'SIMULADOR_FLUXO' ORDER BY id;
\echo 'Compare a vazão com e sem triggers: este é o custo da regra de segurança por linha.'
\echo '\nAgora rode em outro terminal:  ./demo/carga_concorrente.sh 16 60'
\prompt 'ENTER quando a carga concorrente terminar...' pausa

\echo '\n================ 8. Operador trata os alertas ================'
SELECT id, equipamento, sensor, severidade, ocorrencias FROM vw_alertas_ativos LIMIT 5;
CALL sp_resolver_alerta(NULL, 'operador.demo', 'Inspeção realizada');
CALL sp_definir_status_manual('PRE-02', 'OPERANDO', 'Manutenção concluída');
SELECT status, count(*) FROM equipamento GROUP BY status;
SELECT * FROM vw_disponibilidade_24h LIMIT 6;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 9. Data lifecycle: arquivamento de telemetria > 30 dias ================'
SELECT 'antes' AS momento,
       (SELECT count(*) FROM telemetria) AS operacional,
       (SELECT count(*) FROM telemetria_historico) AS historico,
       (SELECT min(lido_em)::date FROM telemetria) AS leitura_mais_antiga;
CALL sp_arquivar_telemetria(30);
SELECT 'depois' AS momento,
       (SELECT count(*) FROM telemetria) AS operacional,
       (SELECT count(*) FROM telemetria_historico) AS historico,
       (SELECT min(lido_em)::date FROM telemetria) AS leitura_mais_antiga;
SELECT tabela_pai, count(*) AS particoes, pg_size_pretty(sum(tamanho_bytes)) AS tamanho FROM vw_particoes GROUP BY 1;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 10. Relatório de produção (view materializada) ================'
CALL sp_atualizar_relatorios();
SELECT * FROM vw_relatorio_producao_diario WHERE dia = current_date ORDER BY pct_fora_normal DESC LIMIT 8;
\prompt '\nENTER para rodar o benchmark...' pausa

\echo '\n================ 11. Benchmark comparativo de consultas ================'
CALL sp_executar_benchmark(5);
SELECT consulta, cenario, mediana_ms, ganho_vs_a FROM vw_benchmark_comparativo;
SELECT * FROM vw_benchmark_indices;
\prompt '\nENTER para continuar...' pausa

\echo '\n================ 12. Rotinas agendadas e log ================'
SELECT rotina, situacao, linhas, iniciado_em::time(0) AS inicio, detalhes->>'segundos' AS segundos
  FROM log_rotina ORDER BY id DESC LIMIT 8;
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AS pg_cron_ativo \gset
\if :pg_cron_ativo
    SELECT jobname, schedule, command FROM cron.job ORDER BY jobid;
\else
    \echo 'pg_cron não instalado: agendamento via crontab (ver README).'
\endif
\echo '\nFim da demonstração.'
