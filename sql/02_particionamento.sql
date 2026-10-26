-- =============================================================================
-- 02_particionamento.sql - Criação automática de partições
--   telemetria           -> 1 partição por DIA   (telemetria_pAAAAMMDD)
--   telemetria_historico -> 1 partição por MÊS   (telemetria_hist_pAAAAMM)
-- Os limites usam o fuso do banco (America/Sao_Paulo, definido no setup).
-- =============================================================================
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- Cria a partição diária de um dia específico. Retorna true se criou.
-- Se a partição DEFAULT tiver linhas daquele dia (leituras que chegaram antes
-- da partição existir), elas são movidas para a nova partição: o PostgreSQL
-- não permite anexar uma partição cujo intervalo tem linhas no DEFAULT.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_criar_particao_dia(p_dia date)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_nome text        := format('telemetria_p%s', to_char(p_dia, 'YYYYMMDD'));
    v_ini  timestamptz := p_dia::timestamptz;
    v_fim  timestamptz := (p_dia + 1)::timestamptz;
BEGIN
    IF to_regclass(format('fabrica.%I', v_nome)) IS NOT NULL THEN
        RETURN false;
    END IF;

    IF EXISTS (SELECT 1 FROM fabrica.telemetria_default WHERE lido_em >= v_ini AND lido_em < v_fim) THEN
        -- Cria como tabela comum, move as linhas do DEFAULT e só então anexa.
        EXECUTE format('CREATE TABLE fabrica.%I (LIKE fabrica.telemetria INCLUDING DEFAULTS)', v_nome);
        EXECUTE format(
            'WITH movidas AS (DELETE FROM fabrica.telemetria_default
                               WHERE lido_em >= %L AND lido_em < %L RETURNING *)
             INSERT INTO fabrica.%I SELECT * FROM movidas', v_ini, v_fim, v_nome);
        EXECUTE format('ALTER TABLE fabrica.telemetria ATTACH PARTITION fabrica.%I FOR VALUES FROM (%L) TO (%L)',
                       v_nome, v_ini, v_fim);
    ELSE
        EXECUTE format('CREATE TABLE fabrica.%I PARTITION OF fabrica.telemetria FOR VALUES FROM (%L) TO (%L)',
                       v_nome, v_ini, v_fim);
    END IF;

    RETURN true;
END;
$$;

-- -----------------------------------------------------------------------------
-- Garante as partições diárias de um intervalo de datas (inclusive).
-- Usada pelo setup, pelo simulador e pelo agendamento diário.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_garantir_particoes(p_inicio date, p_fim date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_dia     date;
    v_criadas integer := 0;
BEGIN
    FOR v_dia IN SELECT generate_series(p_inicio, p_fim, interval '1 day')::date LOOP
        IF fabrica.fn_criar_particao_dia(v_dia) THEN
            v_criadas := v_criadas + 1;
        END IF;
    END LOOP;
    RETURN v_criadas;
END;
$$;

-- -----------------------------------------------------------------------------
-- Cria a partição mensal da tabela histórica que contém a data informada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_criar_particao_historico(p_data date)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_mes  date := date_trunc('month', p_data)::date;
    v_nome text := format('telemetria_hist_p%s', to_char(v_mes, 'YYYYMM'));
BEGIN
    IF to_regclass(format('fabrica.%I', v_nome)) IS NOT NULL THEN
        RETURN false;
    END IF;
    EXECUTE format('CREATE TABLE fabrica.%I PARTITION OF fabrica.telemetria_historico FOR VALUES FROM (%L) TO (%L)',
                   v_nome, v_mes::timestamptz, (v_mes + interval '1 month')::timestamptz);
    RETURN true;
END;
$$;

-- -----------------------------------------------------------------------------
-- View de inspeção: partições, limites, linhas e tamanho em disco.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_particoes AS
SELECT p.relname                                   AS tabela_pai,
       c.relname                                   AS particao,
       pg_get_expr(c.relpartbound, c.oid)          AS limites,
       c.reltuples::bigint                         AS linhas_estimadas,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamanho_total,
       pg_total_relation_size(c.oid)               AS tamanho_bytes
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_class p ON p.oid = i.inhparent
JOIN pg_namespace n ON n.oid = p.relnamespace
WHERE n.nspname = 'fabrica'
  AND p.relname IN ('telemetria', 'telemetria_historico')
ORDER BY p.relname, c.relname;
