-- Painel em tempo real. Use com:  ./demo/painel.sh
\pset footer off
SELECT (SELECT count(*) FROM fabrica.telemetria WHERE lido_em >= now() - interval '10 seconds') / 10
           AS "leituras/s (últimos 10 s)",
       (SELECT count(*) FROM fabrica.alerta WHERE situacao <> 'RESOLVIDO')                    AS "alertas ativos",
       (SELECT count(*) FROM fabrica.equipamento WHERE status = 'FALHA')                      AS "em falha",
       (SELECT count(*) FROM fabrica.equipamento WHERE status = 'ATENCAO')                    AS "em atenção",
       to_char(clock_timestamp(), 'HH24:MI:SS')                                               AS agora;

SELECT equipamento, categoria, status, no_status_ha, alertas_abertos, maior_severidade,
       ocorrencias, leituras_ultimo_min
  FROM fabrica.vw_painel_equipamentos;

SELECT id, equipamento, sensor, severidade, situacao, ocorrencias, valor_pico, limite_violado, unidade
  FROM fabrica.vw_alertas_ativos
 LIMIT 8;
