-- =============================================================================
-- 04_procedures.sql - Stored procedures e funções de apoio
--   fn_gerar_valor / fn_leitura_simulada : geração de leituras realistas
--   sp_simular_fluxo                     : carga em massa (teste de estresse)
--   sp_arquivar_telemetria               : data lifecycle (> 30 dias -> histórico)
--   sp_reconhecer_alerta / sp_resolver_alerta / sp_definir_status_manual
--   sp_atualizar_relatorios / sp_manutencao_diaria
-- =============================================================================
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- Gera um valor simulado a partir dos limites da máquina.
--   p_pct_anomalia = % de leituras na faixa CRÍTICA; a mesma % cai na faixa de
--   ATENÇÃO; o restante fica dentro da faixa normal (distribuição triangular).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_gerar_valor(
    p_normal_min  double precision,
    p_normal_max  double precision,
    p_critico_min double precision,
    p_critico_max double precision,
    p_pct_anomalia numeric)
RETURNS double precision
LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
    SELECT CASE
        -- faixa crítica (se houver algum limite crítico)
        WHEN r.zona < p_pct_anomalia / 100 AND (p_critico_max IS NOT NULL OR p_critico_min IS NOT NULL) THEN
            CASE WHEN p_critico_max IS NOT NULL AND (p_critico_min IS NULL OR r.dir < 0.7)
                 THEN p_critico_max + (p_normal_max - p_normal_min) * (0.02 + 0.30 * r.val)
                 ELSE p_critico_min - (p_normal_max - p_normal_min) * (0.02 + 0.30 * r.val)
            END
        -- faixa de atenção (entre o normal e o crítico)
        WHEN r.zona < 2 * p_pct_anomalia / 100 THEN
            CASE WHEN p_critico_min IS NULL OR r.dir < 0.7
                 THEN p_normal_max + (COALESCE(p_critico_max, p_normal_max + (p_normal_max - p_normal_min) * 0.2)
                                      - p_normal_max) * (0.05 + 0.90 * r.val)
                 ELSE p_normal_min - (p_normal_min - p_critico_min) * (0.05 + 0.90 * r.val)
            END
        -- operação normal
        ELSE p_normal_min + (p_normal_max - p_normal_min) * (0.10 + 0.80 * (r.val + r.val2) / 2)
    END
    FROM (SELECT random() AS zona, random() AS dir, random() AS val, random() AS val2) r
$$;

-- Versão por sensor (usada pelo pgbench na carga concorrente).
CREATE OR REPLACE FUNCTION fn_leitura_simulada(p_sensor_id integer, p_pct_anomalia numeric DEFAULT 0.5)
RETURNS double precision
LANGUAGE sql VOLATILE AS $$
    SELECT fabrica.fn_gerar_valor(l.normal_min, l.normal_max, l.critico_min, l.critico_max, p_pct_anomalia)
      FROM fabrica.sensor s
      JOIN fabrica.limite_operacional l ON l.equipamento_id = s.equipamento_id
                                       AND l.tipo_sensor_id = s.tipo_sensor_id
     WHERE s.id = p_sensor_id
$$;

-- -----------------------------------------------------------------------------
-- SIMULADOR DE FLUXO
-- Insere p_total_leituras em lotes set-based (INSERT ... SELECT generate_series),
-- com COMMIT a cada lote e medição de vazão (leituras/s).
--   Tempo real : p_inicio e p_fim nulos -> lido_em = clock_timestamp()
--   Histórico  : p_inicio/p_fim -> leituras distribuídas em ordem cronológica
--   p_disparar_triggers = false -> carga de histórico sem triggers/FK
--     (session_replication_role = replica; exige superusuário). Útil para
--     importar histórico e para medir o custo das triggers na escrita.
-- Uso: CALL fabrica.sp_simular_fluxo(200000, 0.5);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_simular_fluxo(
    p_total_leituras    bigint      DEFAULT 100000,
    p_pct_anomalia      numeric     DEFAULT 0.5,
    p_inicio            timestamptz DEFAULT NULL,
    p_fim               timestamptz DEFAULT NULL,
    p_tamanho_lote      integer     DEFAULT 50000,
    p_disparar_triggers boolean     DEFAULT true)
LANGUAGE plpgsql AS $$
DECLARE
    v_sensores      integer;
    v_inseridas     bigint := 0;
    v_lote          integer;
    v_num_lote      integer := 0;
    v_t0            timestamptz := clock_timestamp();
    v_tl            timestamptz;
    v_seg           numeric;
    v_log           bigint;
    v_ocorr_antes   bigint;
    v_ocorr_depois  bigint;
    v_alertas_antes bigint;
    v_alertas_dep   bigint;
BEGIN
    IF (p_inicio IS NULL) <> (p_fim IS NULL) THEN
        RAISE EXCEPTION 'Informe p_inicio e p_fim juntos (ou nenhum dos dois para tempo real).';
    END IF;
    IF p_inicio IS NOT NULL AND p_fim <= p_inicio THEN
        RAISE EXCEPTION 'p_fim deve ser maior que p_inicio.';
    END IF;

    SELECT count(*) INTO v_sensores
      FROM fabrica.sensor s
      JOIN fabrica.limite_operacional l ON l.equipamento_id = s.equipamento_id
                                       AND l.tipo_sensor_id = s.tipo_sensor_id
     WHERE s.ativo;
    IF v_sensores = 0 THEN
        RAISE EXCEPTION 'Nenhum sensor ativo com limites configurados. Rode o 06_seed.sql.';
    END IF;

    -- Garante as partições do período (evita cair na partição DEFAULT).
    IF p_inicio IS NULL THEN
        PERFORM fabrica.fn_garantir_particoes(current_date, current_date + 1);
    ELSE
        PERFORM fabrica.fn_garantir_particoes(p_inicio::date, p_fim::date);
    END IF;

    SELECT COALESCE(sum(ocorrencias), 0), count(*) INTO v_ocorr_antes, v_alertas_antes FROM fabrica.alerta;

    INSERT INTO fabrica.log_rotina (rotina, parametros)
    VALUES ('SIMULADOR_FLUXO', jsonb_build_object(
        'total', p_total_leituras, 'pct_anomalia', p_pct_anomalia, 'inicio', p_inicio, 'fim', p_fim,
        'lote', p_tamanho_lote, 'triggers', p_disparar_triggers, 'sensores', v_sensores))
    RETURNING id INTO v_log;
    COMMIT;

    WHILE v_inseridas < p_total_leituras LOOP
        v_lote := LEAST(p_tamanho_lote, p_total_leituras - v_inseridas);
        v_tl := clock_timestamp();

        IF NOT p_disparar_triggers THEN
            PERFORM set_config('session_replication_role', 'replica', true);  -- vale só para este lote
        END IF;

        WITH params AS MATERIALIZED (
            SELECT row_number() OVER (ORDER BY s.id)::integer AS idx, s.id AS sensor_id,
                   l.normal_min, l.normal_max, l.critico_min, l.critico_max
              FROM fabrica.sensor s
              JOIN fabrica.limite_operacional l ON l.equipamento_id = s.equipamento_id
                                               AND l.tipo_sensor_id = s.tipo_sensor_id
             WHERE s.ativo
        ), gerador AS (
            SELECT 1 + floor(random() * v_sensores)::integer AS idx,
                   CASE WHEN p_inicio IS NULL THEN clock_timestamp()
                        ELSE p_inicio + (p_fim - p_inicio) * ((v_inseridas + g.n)::double precision / p_total_leituras)
                   END AS lido_em
              FROM generate_series(1, v_lote) AS g(n)
        )
        INSERT INTO fabrica.telemetria (sensor_id, lido_em, valor)
        SELECT p.sensor_id, g.lido_em,
               fabrica.fn_gerar_valor(p.normal_min, p.normal_max, p.critico_min, p.critico_max, p_pct_anomalia)
          FROM gerador g
          JOIN params p USING (idx)
         ORDER BY g.lido_em;

        v_inseridas := v_inseridas + v_lote;
        v_num_lote  := v_num_lote + 1;
        COMMIT;

        v_seg := GREATEST(extract(epoch FROM clock_timestamp() - v_tl), 0.001);
        RAISE NOTICE 'Lote % : % leituras em % s (% leituras/s) | total % / %',
            v_num_lote, v_lote, round(v_seg, 2), round(v_lote / v_seg), v_inseridas, p_total_leituras;
    END LOOP;

    v_seg := GREATEST(extract(epoch FROM clock_timestamp() - v_t0), 0.001);
    SELECT COALESCE(sum(ocorrencias), 0), count(*) INTO v_ocorr_depois, v_alertas_dep FROM fabrica.alerta;

    UPDATE fabrica.log_rotina
       SET finalizado_em = clock_timestamp(), situacao = 'OK', linhas = v_inseridas,
           detalhes = jsonb_build_object(
               'segundos', round(v_seg, 3),
               'leituras_por_segundo', round(v_inseridas / v_seg),
               'ocorrencias_registradas', v_ocorr_depois - v_ocorr_antes,
               'alertas_novos', v_alertas_dep - v_alertas_antes)
     WHERE id = v_log;
    COMMIT;

    RAISE NOTICE 'Simulação concluída: % leituras em % s (% leituras/s). Ocorrências fora do limite: % | alertas novos: %',
        v_inseridas, round(v_seg, 2), round(v_inseridas / v_seg), v_ocorr_depois - v_ocorr_antes, v_alertas_dep - v_alertas_antes;
END;
$$;

-- -----------------------------------------------------------------------------
-- DATA LIFECYCLE: arquivamento automático de telemetria com mais de N dias.
-- Estratégia por partição inteira: copia a partição diária para a tabela
-- histórica (INSERT ... SELECT em lote) e faz DROP da partição. Isso evita o
-- DELETE linha a linha, que gera bloat e exige VACUUM na tabela operacional.
-- Linhas antigas na partição DEFAULT são movidas com DELETE ... RETURNING.
-- Cada partição é processada e confirmada (COMMIT) separadamente para que o
-- bloqueio na tabela pai dure milissegundos, e não a rotina inteira.
--   p_meses_historico (opcional): EXPURGO de partições históricas antigas.
-- Uso: CALL fabrica.sp_arquivar_telemetria();      -- padrão: 30 dias
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_arquivar_telemetria(
    p_dias_retencao   integer DEFAULT 30,
    p_meses_historico integer DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_corte       date := current_date - p_dias_retencao;   -- tudo antes de 00:00 deste dia sai
    v_part        record;
    v_mes         date;
    v_linhas      bigint;
    v_total       bigint := 0;
    v_movidas     jsonb  := '[]'::jsonb;
    v_expurgadas  jsonb  := '[]'::jsonb;
    v_erro        text;
    v_log         bigint;
    v_t0          timestamptz := clock_timestamp();
BEGIN
    IF p_dias_retencao < 1 THEN
        RAISE EXCEPTION 'p_dias_retencao deve ser >= 1';
    END IF;

    INSERT INTO fabrica.log_rotina (rotina, parametros)
    VALUES ('ARQUIVAMENTO', jsonb_build_object('dias_retencao', p_dias_retencao,
                                               'meses_historico', p_meses_historico, 'corte', v_corte))
    RETURNING id INTO v_log;
    COMMIT;

    -- 1) Partições diárias inteiramente anteriores ao corte
    FOR v_part IN
        SELECT c.relname, to_date(substring(c.relname FROM '(\d{8})$'), 'YYYYMMDD') AS dia
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = 'fabrica.telemetria'::regclass
           AND c.relname ~ '^telemetria_p\d{8}$'
         ORDER BY 2
    LOOP
        EXIT WHEN v_part.dia + 1 > v_corte;   -- limite superior da partição = dia + 1

        BEGIN
            PERFORM set_config('lock_timeout', '15s', true);
            PERFORM fabrica.fn_criar_particao_historico(v_part.dia);

            EXECUTE format(
                'INSERT INTO fabrica.telemetria_historico (id, sensor_id, lido_em, valor, recebido_em)
                 SELECT id, sensor_id, lido_em, valor, recebido_em FROM fabrica.%I', v_part.relname);
            GET DIAGNOSTICS v_linhas = ROW_COUNT;

            EXECUTE format('DROP TABLE fabrica.%I', v_part.relname);

            v_total   := v_total + v_linhas;
            v_movidas := v_movidas || jsonb_build_object('particao', v_part.relname, 'linhas', v_linhas);
        EXCEPTION WHEN OTHERS THEN
            v_erro := format('%s: %s', v_part.relname, SQLERRM);
        END;

        COMMIT;   -- libera o bloqueio da tabela pai a cada partição
        EXIT WHEN v_erro IS NOT NULL;
    END LOOP;

    -- 2) Leituras antigas que caíram na partição DEFAULT
    IF v_erro IS NULL THEN
        BEGIN
            FOR v_mes IN SELECT DISTINCT date_trunc('month', lido_em)::date
                           FROM fabrica.telemetria_default WHERE lido_em < v_corte::timestamptz LOOP
                PERFORM fabrica.fn_criar_particao_historico(v_mes);
            END LOOP;

            WITH movidas AS (
                DELETE FROM fabrica.telemetria_default
                 WHERE lido_em < v_corte::timestamptz
             RETURNING id, sensor_id, lido_em, valor, recebido_em)
            INSERT INTO fabrica.telemetria_historico (id, sensor_id, lido_em, valor, recebido_em)
            SELECT * FROM movidas;
            GET DIAGNOSTICS v_linhas = ROW_COUNT;

            IF v_linhas > 0 THEN
                v_total   := v_total + v_linhas;
                v_movidas := v_movidas || jsonb_build_object('particao', 'telemetria_default', 'linhas', v_linhas);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_erro := format('telemetria_default: %s', SQLERRM);
        END;
        COMMIT;
    END IF;

    -- 3) Expurgo opcional do histórico (DROP de partições mensais antigas)
    IF v_erro IS NULL AND p_meses_historico IS NOT NULL THEN
        FOR v_part IN
            SELECT c.relname, to_date(substring(c.relname FROM '(\d{6})$') || '01', 'YYYYMMDD') AS mes
              FROM pg_inherits i
              JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = 'fabrica.telemetria_historico'::regclass
               AND c.relname ~ '^telemetria_hist_p\d{6}$'
             ORDER BY 2
        LOOP
            EXIT WHEN v_part.mes >= (date_trunc('month', current_date) - make_interval(months => p_meses_historico))::date;
            EXECUTE format('DROP TABLE fabrica.%I', v_part.relname);
            v_expurgadas := v_expurgadas || to_jsonb(v_part.relname);
            COMMIT;
        END LOOP;
    END IF;

    UPDATE fabrica.log_rotina
       SET finalizado_em = clock_timestamp(),
           situacao = CASE WHEN v_erro IS NULL THEN 'OK' ELSE 'ERRO' END,
           linhas = v_total,
           detalhes = jsonb_build_object(
               'segundos', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 3),
               'movidas', v_movidas, 'expurgadas', v_expurgadas, 'erro', v_erro)
     WHERE id = v_log;
    COMMIT;

    IF v_erro IS NOT NULL THEN
        RAISE WARNING 'Arquivamento interrompido: %', v_erro;
    ELSE
        RAISE NOTICE 'Arquivamento concluído: % leituras movidas para o histórico (% partições). Corte: %.',
            v_total, jsonb_array_length(v_movidas), v_corte;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- Gestão de alertas e status
-- -----------------------------------------------------------------------------

-- Recalcula o status de um equipamento a partir dos alertas ainda não
-- resolvidos. Não mexe em equipamentos em MANUTENCAO/DESLIGADO.
CREATE OR REPLACE FUNCTION fn_recalcular_status_equipamento(p_equipamento_id integer, p_motivo text DEFAULT NULL)
RETURNS equipamento_status
LANGUAGE plpgsql AS $$
DECLARE
    v_sev   fabrica.alerta_severidade;
    v_novo  fabrica.equipamento_status;
    v_atual fabrica.equipamento_status;
BEGIN
    SELECT status INTO v_atual FROM fabrica.equipamento WHERE id = p_equipamento_id FOR UPDATE;
    IF v_atual IN ('MANUTENCAO', 'DESLIGADO') THEN
        RETURN v_atual;
    END IF;

    SELECT max(severidade) INTO v_sev
      FROM fabrica.alerta
     WHERE equipamento_id = p_equipamento_id AND situacao <> 'RESOLVIDO';

    v_novo := CASE v_sev WHEN 'CRITICO' THEN 'FALHA' WHEN 'ATENCAO' THEN 'ATENCAO' ELSE 'OPERANDO' END;

    IF v_novo IS DISTINCT FROM v_atual THEN
        PERFORM set_config('fabrica.motivo_status', COALESCE(p_motivo, 'Recalculado após tratamento de alertas'), true);
        UPDATE fabrica.equipamento SET status = v_novo, status_desde = clock_timestamp() WHERE id = p_equipamento_id;
    END IF;
    RETURN v_novo;
END;
$$;

-- Operador reconhece o alerta (continua aberto, mas já está sendo tratado).
CREATE OR REPLACE PROCEDURE sp_reconhecer_alerta(p_alerta_id bigint, p_usuario text DEFAULT current_user)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE fabrica.alerta
       SET situacao = 'RECONHECIDO', reconhecido_por = p_usuario, reconhecido_em = clock_timestamp()
     WHERE id = p_alerta_id AND situacao = 'ABERTO';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Alerta % não existe ou não está ABERTO.', p_alerta_id;
    END IF;
END;
$$;

-- Resolve um alerta (ou TODOS os não resolvidos, se p_alerta_id for NULL) e
-- recalcula o status dos equipamentos afetados.
CREATE OR REPLACE PROCEDURE sp_resolver_alerta(
    p_alerta_id  bigint DEFAULT NULL,
    p_usuario    text   DEFAULT current_user,
    p_observacao text   DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_equip   integer;
    v_equips  integer[];
    v_qtd     integer;
BEGIN
    WITH resolvidos AS (
        UPDATE fabrica.alerta
           SET situacao = 'RESOLVIDO', resolvido_por = p_usuario, resolvido_em = clock_timestamp(),
               observacao = COALESCE(p_observacao, observacao)
         WHERE situacao <> 'RESOLVIDO'
           AND (p_alerta_id IS NULL OR id = p_alerta_id)
     RETURNING equipamento_id)
    SELECT array_agg(DISTINCT equipamento_id ORDER BY equipamento_id), count(*)
      INTO v_equips, v_qtd
      FROM resolvidos;

    IF p_alerta_id IS NOT NULL AND v_qtd = 0 THEN
        RAISE EXCEPTION 'Alerta % não existe ou já está resolvido.', p_alerta_id;
    END IF;

    FOREACH v_equip IN ARRAY COALESCE(v_equips, '{}'::integer[]) LOOP
        PERFORM fabrica.fn_recalcular_status_equipamento(v_equip,
            format('Alertas resolvidos por %s', p_usuario));
    END LOOP;

    RAISE NOTICE '% alerta(s) resolvido(s) em % equipamento(s).', v_qtd, COALESCE(cardinality(v_equips), 0);
END;
$$;

-- Status manual (MANUTENCAO, DESLIGADO) ou retorno à operação.
-- Ao sair de MANUTENCAO/DESLIGADO, o status é recalculado pelos alertas.
CREATE OR REPLACE PROCEDURE sp_definir_status_manual(
    p_equipamento_codigo text,
    p_status             equipamento_status,
    p_motivo             text DEFAULT 'Alteração manual')
LANGUAGE plpgsql AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT id INTO v_id FROM fabrica.equipamento WHERE codigo = p_equipamento_codigo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Equipamento % não encontrado.', p_equipamento_codigo;
    END IF;

    PERFORM set_config('fabrica.motivo_status', p_motivo, true);
    UPDATE fabrica.equipamento SET status = p_status, status_desde = clock_timestamp()
     WHERE id = v_id AND status IS DISTINCT FROM p_status;

    IF p_status NOT IN ('MANUTENCAO', 'DESLIGADO') THEN
        PERFORM fabrica.fn_recalcular_status_equipamento(v_id, p_motivo);
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- Atualização das views materializadas (definidas em 05_views.sql).
-- CONCURRENTLY: leitores não são bloqueados durante o refresh.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_atualizar_relatorios()
LANGUAGE plpgsql AS $$
DECLARE
    v_t0 timestamptz := clock_timestamp();
    v_populada boolean;
BEGIN
    SELECT ispopulated INTO v_populada FROM pg_matviews
     WHERE schemaname = 'fabrica' AND matviewname = 'mv_resumo_horario';

    IF v_populada THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY fabrica.mv_resumo_horario;
    ELSE
        REFRESH MATERIALIZED VIEW fabrica.mv_resumo_horario;   -- 1ª carga não aceita CONCURRENTLY
    END IF;

    INSERT INTO fabrica.log_rotina (rotina, iniciado_em, finalizado_em, situacao, linhas)
    VALUES ('REFRESH_RELATORIOS', v_t0, clock_timestamp(), 'OK',
            (SELECT count(*) FROM fabrica.mv_resumo_horario));
END;
$$;

-- -----------------------------------------------------------------------------
-- Rotina diária completa (agendada no pg_cron ou no cron do Linux):
-- cria partições futuras, arquiva > 30 dias e atualiza relatórios.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_manutencao_diaria(p_dias_retencao integer DEFAULT 30)
LANGUAGE plpgsql AS $$
DECLARE
    v_criadas integer;
BEGIN
    v_criadas := fabrica.fn_garantir_particoes(current_date, current_date + 7);
    INSERT INTO fabrica.log_rotina (rotina, finalizado_em, situacao, linhas)
    VALUES ('CRIAR_PARTICOES', clock_timestamp(), 'OK', v_criadas);
    COMMIT;

    CALL fabrica.sp_arquivar_telemetria(p_dias_retencao);
    CALL fabrica.sp_atualizar_relatorios();
END;
$$;
