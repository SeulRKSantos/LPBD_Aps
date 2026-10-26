-- =============================================================================
-- 08_benchmark.sql - Testes comparativos de tempo de resposta
-- Compara as MESMAS consultas de relatório em 5 cenários:
--   A) Tabela única (não particionada) sem índices      -> linha de base
--   B) Tabela única + B-Tree composto (sensor_id, lido_em), B-Tree (lido_em) e B-Tree (id)
--   C) Tabela única + Hash (id) no lugar do B-Tree (id)  -> igualdade vs faixa
--   D) Tabela particionada por dia (fabrica.telemetria) + índices locais + BRIN
--   E) View materializada (mv_resumo_horario)           -> só no relatório horário
-- Cada consulta roda 1x para aquecer o cache e depois N vezes com
-- EXPLAIN (ANALYZE, TIMING OFF); guarda média, mediana, mín., máx. e o plano.
-- Uso:  CALL fabrica.sp_executar_benchmark(5);
--       SELECT * FROM fabrica.vw_benchmark_comparativo;
--       SELECT * FROM fabrica.vw_benchmark_indices;
-- =============================================================================
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- Mede uma consulta e grava o resultado.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_medir_consulta(
    p_execucao   integer,
    p_cenario    text,
    p_consulta   text,
    p_sql        text,
    p_repeticoes integer DEFAULT 5)
RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_plano   json;
    v_tempos  numeric[] := '{}';
    v_nos     text;
    v_mediana numeric;
    v_parts   integer;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' || p_sql INTO v_plano;   -- aquecimento

    FOR i IN 1 .. p_repeticoes LOOP
        EXECUTE 'EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' || p_sql INTO v_plano;
        v_tempos := v_tempos || (v_plano -> 0 ->> 'Execution Time')::numeric;
    END LOOP;

    -- Resumo legível do plano: tipos de nó + índice usado + partições podadas.
    SELECT string_agg(DISTINCT rotulo, ' | ')
      INTO v_nos
      FROM (
        SELECT (n ->> 'Node Type')
               || COALESCE(' [' || regexp_replace(n ->> 'Index Name', '^telemetria_p\d{8}_', 'telemetria_pX_') || ']', '')
               || COALESCE(' (' || NULLIF(n ->> 'Subplans Removed', '0') || ' partições podadas em execução)', '') AS rotulo
          FROM jsonb_path_query(v_plano::jsonb, 'strict $.** ? (exists (@."Node Type"))') AS j(n)
      ) r;

    -- Quantas partições diárias o plano realmente leu (evidência do partition pruning).
    SELECT count(DISTINCT n ->> 'Relation Name')
      INTO v_parts
      FROM jsonb_path_query(v_plano::jsonb, 'strict $.** ? (exists (@."Relation Name"))') AS j(n)
     WHERE n ->> 'Relation Name' ~ '^telemetria_(p\d{8}|default)$';
    IF v_parts > 0 THEN
        v_nos := v_nos || format(' || partições lidas: %s de %s', v_parts,
                 (SELECT count(*) FROM pg_inherits WHERE inhparent = 'fabrica.telemetria'::regclass));
    END IF;

    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t) INTO v_mediana FROM unnest(v_tempos) AS t;

    INSERT INTO fabrica.benchmark_resultado
           (execucao, cenario, consulta, repeticoes, media_ms, mediana_ms, min_ms, max_ms, nos_plano, plano)
    SELECT p_execucao, p_cenario, p_consulta, p_repeticoes,
           avg(t), v_mediana, min(t), max(t), v_nos, v_plano::jsonb
      FROM unnest(v_tempos) AS t;

    RAISE NOTICE '% | % | mediana % ms', p_cenario, p_consulta, round(v_mediana, 3);
    RETURN v_mediana;
END;
$$;

-- -----------------------------------------------------------------------------
-- Cria um índice cronometrando e registra tamanho/tempo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_criar_indice_medido(
    p_execucao integer, p_cenario text, p_nome text, p_metodo text, p_definicao text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_t0 timestamptz := clock_timestamp();
BEGIN
    EXECUTE format('CREATE INDEX %I ON fabrica.bench_telemetria_plana USING %s %s', p_nome, p_metodo, p_definicao);
    INSERT INTO fabrica.benchmark_indice (execucao, cenario, indice, metodo, tamanho_bytes, tempo_criacao_ms)
    VALUES (p_execucao, p_cenario, p_nome, p_metodo,
            pg_relation_size(format('fabrica.%I', p_nome)::regclass),
            round(extract(epoch FROM clock_timestamp() - v_t0) * 1000, 3));
END;
$$;

-- -----------------------------------------------------------------------------
-- Executa o benchmark completo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_executar_benchmark(p_repeticoes integer DEFAULT 5)
LANGUAGE plpgsql AS $$
DECLARE
    v_exec   integer := nextval('fabrica.benchmark_execucao_seq');
    v_sensor integer;
    v_dia    timestamptz;
    v_id     bigint;
    v_linhas bigint;
    q1 text; q1_mv text; q2 text; q3 text; q4 text; q5 text;
    v_plana  constant text := 'fabrica.bench_telemetria_plana';
    v_part   constant text := 'fabrica.telemetria';
BEGIN
    -- JIT desligado para que o tempo de compilação não distorça a comparação.
    PERFORM set_config('jit', 'off', true);

    -- Parâmetros reais extraídos dos próprios dados.
    SELECT id INTO v_sensor FROM fabrica.sensor WHERE codigo = 'MOT-01-VIB';
    SELECT (max(lido_em)::date - 2)::timestamptz INTO v_dia FROM fabrica.telemetria;
    SELECT id INTO v_id FROM fabrica.telemetria
     WHERE lido_em >= v_dia AND lido_em < v_dia + interval '1 day' LIMIT 1;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Sem dados suficientes. Gere histórico com sp_simular_fluxo antes do benchmark.';
    END IF;

    -- Cópia NÃO particionada e SEM índices com os mesmos dados (linha de base).
    IF to_regclass('fabrica.bench_telemetria_plana') IS NOT NULL THEN   -- sobra de execução interrompida
        DROP TABLE fabrica.bench_telemetria_plana;
    END IF;
    CREATE TABLE fabrica.bench_telemetria_plana AS
        SELECT id, sensor_id, lido_em, valor, recebido_em FROM fabrica.telemetria;
    GET DIAGNOSTICS v_linhas = ROW_COUNT;
    ANALYZE fabrica.bench_telemetria_plana;
    ANALYZE fabrica.telemetria;

    -- Garante a view materializada atualizada para o cenário E.
    REFRESH MATERIALIZED VIEW fabrica.mv_resumo_horario;
    ANALYZE fabrica.mv_resumo_horario;

    RAISE NOTICE 'Benchmark #% | % linhas | sensor % | dia % | id % | % repetições',
        v_exec, v_linhas, v_sensor, v_dia::date, v_id, p_repeticoes;

    -- Consultas (%s = tabela alvo)
    q1 := 'SELECT date_trunc(''hour'', t.lido_em) AS hora, s.equipamento_id, s.tipo_sensor_id,
                  count(*), avg(t.valor), max(t.valor)
             FROM %s t JOIN fabrica.sensor s ON s.id = t.sensor_id
            WHERE t.lido_em >= ' || quote_literal(v_dia) || ' AND t.lido_em < ' || quote_literal(v_dia + interval '1 day') || '
            GROUP BY 1, 2, 3';
    q1_mv := 'SELECT hora, equipamento_id, tipo_sensor_id,
                     sum(leituras), sum(soma) / sum(leituras), max(maximo)
                FROM fabrica.mv_resumo_horario
               WHERE hora >= ' || quote_literal(v_dia) || ' AND hora < ' || quote_literal(v_dia + interval '1 day') || '
               GROUP BY 1, 2, 3';
    q2 := 'SELECT lido_em, valor FROM %s WHERE sensor_id = ' || v_sensor || ' ORDER BY lido_em DESC LIMIT 100';
    q3 := 'SELECT count(*), avg(valor), max(valor) FROM %s
            WHERE sensor_id = ' || v_sensor || '
              AND lido_em >= ' || quote_literal(v_dia + interval '10 hours') || '
              AND lido_em <  ' || quote_literal(v_dia + interval '11 hours');
    q4 := 'SELECT * FROM %s WHERE id = ' || v_id;
    q5 := 'SELECT count(*) FROM %s WHERE id BETWEEN ' || v_id || ' AND ' || (v_id + 1000);

    -- ---------------- A) sem índices ----------------
    PERFORM fabrica.fn_medir_consulta(v_exec, 'A) Tabela única sem índices', 'Q1 Relatório horário (1 dia)', format(q1, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'A) Tabela única sem índices', 'Q2 Últimas 100 leituras do sensor', format(q2, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'A) Tabela única sem índices', 'Q3 Sensor em janela de 1 hora', format(q3, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'A) Tabela única sem índices', 'Q4 Busca por igualdade (id = x)', format(q4, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'A) Tabela única sem índices', 'Q5 Busca por faixa (id BETWEEN)', format(q5, v_plana), p_repeticoes);

    -- ---------------- B) B-Tree ----------------
    PERFORM fabrica.fn_criar_indice_medido(v_exec, 'B', 'bx_btree_sensor_tempo', 'btree', '(sensor_id, lido_em)');
    PERFORM fabrica.fn_criar_indice_medido(v_exec, 'B', 'bx_btree_tempo',        'btree', '(lido_em)');
    PERFORM fabrica.fn_criar_indice_medido(v_exec, 'B', 'bx_btree_id',           'btree', '(id)');
    ANALYZE fabrica.bench_telemetria_plana;
    PERFORM fabrica.fn_medir_consulta(v_exec, 'B) Tabela única + B-Tree', 'Q1 Relatório horário (1 dia)', format(q1, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'B) Tabela única + B-Tree', 'Q2 Últimas 100 leituras do sensor', format(q2, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'B) Tabela única + B-Tree', 'Q3 Sensor em janela de 1 hora', format(q3, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'B) Tabela única + B-Tree', 'Q4 Busca por igualdade (id = x)', format(q4, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'B) Tabela única + B-Tree', 'Q5 Busca por faixa (id BETWEEN)', format(q5, v_plana), p_repeticoes);

    -- ---------------- C) Hash no lugar do B-Tree em id ----------------
    DROP INDEX fabrica.bx_btree_id;
    PERFORM fabrica.fn_criar_indice_medido(v_exec, 'C', 'bx_hash_id', 'hash', '(id)');
    ANALYZE fabrica.bench_telemetria_plana;
    PERFORM fabrica.fn_medir_consulta(v_exec, 'C) Tabela única + Hash (id)', 'Q4 Busca por igualdade (id = x)', format(q4, v_plana), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'C) Tabela única + Hash (id)', 'Q5 Busca por faixa (id BETWEEN)', format(q5, v_plana), p_repeticoes);

    -- ---------------- D) Particionada ----------------
    PERFORM fabrica.fn_medir_consulta(v_exec, 'D) Particionada por dia + índices', 'Q1 Relatório horário (1 dia)', format(q1, v_part), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'D) Particionada por dia + índices', 'Q2 Últimas 100 leituras do sensor', format(q2, v_part), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'D) Particionada por dia + índices', 'Q3 Sensor em janela de 1 hora', format(q3, v_part), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'D) Particionada por dia + índices', 'Q4 Busca por igualdade (id = x)', format(q4, v_part), p_repeticoes);
    PERFORM fabrica.fn_medir_consulta(v_exec, 'D) Particionada por dia + índices', 'Q5 Busca por faixa (id BETWEEN)', format(q5, v_part), p_repeticoes);

    -- ---------------- E) View materializada ----------------
    PERFORM fabrica.fn_medir_consulta(v_exec, 'E) View materializada', 'Q1 Relatório horário (1 dia)', q1_mv, p_repeticoes);

    -- Tamanhos de referência dos índices da tabela particionada (soma das partições)
    INSERT INTO fabrica.benchmark_indice (execucao, cenario, indice, metodo, tamanho_bytes, tempo_criacao_ms)
    SELECT v_exec, 'D', pi.relname, am.amname,
           sum(pg_relation_size(ci.oid)), 0
      FROM pg_class pi
      JOIN pg_am am ON am.oid = pi.relam
      JOIN pg_inherits inh ON inh.inhparent = pi.oid
      JOIN pg_class ci ON ci.oid = inh.inhrelid
     WHERE pi.relkind = 'I'
       AND pi.relname IN ('telemetria_pkey', 'ix_telemetria_sensor_tempo', 'ix_telemetria_tempo_brin')
     GROUP BY pi.relname, am.amname;

    DROP TABLE fabrica.bench_telemetria_plana;
    RAISE NOTICE 'Benchmark #% concluído. Veja: SELECT * FROM fabrica.vw_benchmark_comparativo;', v_exec;
END;
$$;

-- -----------------------------------------------------------------------------
-- Comparativo da última execução: mediana e ganho em relação ao cenário A.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_benchmark_comparativo AS
WITH ultima AS (SELECT max(execucao) AS e FROM benchmark_resultado),
r AS (SELECT b.* FROM benchmark_resultado b, ultima WHERE b.execucao = ultima.e)
SELECT r.consulta,
       r.cenario,
       r.mediana_ms,
       r.min_ms,
       r.max_ms,
       CASE WHEN r.mediana_ms > 0
            THEN round(base.mediana_ms / r.mediana_ms, 1) END AS ganho_vs_a,
       r.nos_plano
  FROM r
  LEFT JOIN r base ON base.consulta = r.consulta AND base.cenario LIKE 'A)%'
 ORDER BY r.consulta, r.cenario;

-- Tamanho e tempo de criação dos índices da última execução.
CREATE OR REPLACE VIEW vw_benchmark_indices AS
SELECT cenario, indice, metodo,
       pg_size_pretty(tamanho_bytes) AS tamanho,
       tamanho_bytes,
       tempo_criacao_ms
  FROM benchmark_indice
 WHERE execucao = (SELECT max(execucao) FROM benchmark_indice)
 ORDER BY cenario, indice;
