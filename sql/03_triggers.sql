-- =============================================================================
-- 03_triggers.sql - Triggers de segurança
--   1) tg_telemetria_verificar_limites : AFTER INSERT na telemetria
--      Compara cada leitura com os limites da máquina, registra/atualiza o
--      alerta, altera o status operacional do equipamento e emite NOTIFY.
--   2) tg_equipamento_status_temporal  : mantém a tabela temporal de status.
-- =============================================================================
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- 1) Verificação de limites a cada leitura
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tg_verificar_limites()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_cfg          record;
    v_severidade   fabrica.alerta_severidade;
    v_violacao     fabrica.alerta_violacao;
    v_limite       double precision;
    v_novo_status  fabrica.equipamento_status;
    v_alerta_id    bigint;
    v_alerta_novo  boolean;
    v_status_mudou integer := 0;
    v_centro       double precision;
BEGIN
    -- Limites da máquina à qual o sensor pertence (1 consulta indexada por PK).
    SELECT s.equipamento_id, s.codigo AS sensor_codigo, e.codigo AS equip_codigo,
           l.normal_min, l.normal_max, l.critico_min, l.critico_max
      INTO v_cfg
      FROM fabrica.sensor s
      JOIN fabrica.equipamento e        ON e.id = s.equipamento_id
      JOIN fabrica.limite_operacional l ON l.equipamento_id = s.equipamento_id
                                       AND l.tipo_sensor_id = s.tipo_sensor_id
     WHERE s.id = NEW.sensor_id;

    IF NOT FOUND THEN
        RETURN NULL;                       -- sensor sem limite configurado
    END IF;

    -- Classificação (o crítico tem precedência). Comparação com NULL = falso.
    IF NEW.valor > v_cfg.critico_max THEN
        v_severidade := 'CRITICO'; v_violacao := 'ACIMA_MAXIMO';  v_limite := v_cfg.critico_max;
    ELSIF NEW.valor < v_cfg.critico_min THEN
        v_severidade := 'CRITICO'; v_violacao := 'ABAIXO_MINIMO'; v_limite := v_cfg.critico_min;
    ELSIF NEW.valor > v_cfg.normal_max THEN
        v_severidade := 'ATENCAO'; v_violacao := 'ACIMA_MAXIMO';  v_limite := v_cfg.normal_max;
    ELSIF NEW.valor < v_cfg.normal_min THEN
        v_severidade := 'ATENCAO'; v_violacao := 'ABAIXO_MINIMO'; v_limite := v_cfg.normal_min;
    ELSE
        RETURN NULL;                       -- leitura normal: caminho rápido
    END IF;

    v_centro := (v_cfg.normal_min + v_cfg.normal_max) / 2;   -- referência para o "pior valor"

    -- Registra a ocorrência. ON CONFLICT no índice único parcial garante, de
    -- forma atômica mesmo com inserções concorrentes, um único alerta aberto
    -- por sensor; violações seguintes incrementam o contador e podem escalar
    -- a severidade de ATENCAO para CRITICO.
    INSERT INTO fabrica.alerta AS a
           (sensor_id, equipamento_id, telemetria_id, severidade, violacao,
            valor_lido, valor_pico, limite_violado,
            primeira_ocorrencia, ultima_ocorrencia, mensagem)
    VALUES (NEW.sensor_id, v_cfg.equipamento_id, NEW.id, v_severidade, v_violacao,
            NEW.valor, NEW.valor, v_limite,
            NEW.lido_em, NEW.lido_em,
            format('%s / %s: leitura %s %s do limite %s (%s)',
                   v_cfg.equip_codigo, v_cfg.sensor_codigo, round(NEW.valor::numeric, 2),
                   CASE v_violacao WHEN 'ACIMA_MAXIMO' THEN 'acima' ELSE 'abaixo' END,
                   v_limite, v_severidade))
    ON CONFLICT (sensor_id) WHERE situacao <> 'RESOLVIDO'
    DO UPDATE SET
        ocorrencias       = a.ocorrencias + 1,
        ultima_ocorrencia = GREATEST(a.ultima_ocorrencia, EXCLUDED.ultima_ocorrencia),
        -- pico = leitura mais distante do centro da faixa normal (qualquer sentido)
        valor_pico        = CASE WHEN abs(EXCLUDED.valor_pico - v_centro) > abs(a.valor_pico - v_centro)
                                 THEN EXCLUDED.valor_pico ELSE a.valor_pico END,
        severidade        = GREATEST(a.severidade, EXCLUDED.severidade),
        violacao          = CASE WHEN EXCLUDED.severidade > a.severidade
                                 THEN EXCLUDED.violacao ELSE a.violacao END,
        limite_violado    = CASE WHEN EXCLUDED.severidade > a.severidade
                                 THEN EXCLUDED.limite_violado ELSE a.limite_violado END,
        mensagem          = CASE WHEN EXCLUDED.severidade > a.severidade
                                 THEN EXCLUDED.mensagem ELSE a.mensagem END
    RETURNING a.id, (a.xmax = 0) INTO v_alerta_id, v_alerta_novo;   -- xmax = 0 -> linha nova

    -- Altera o status operacional. Só "piora" (OPERANDO < ATENCAO < FALHA) e
    -- nunca sobrescreve MANUTENCAO/DESLIGADO. Como a condição filtra antes do
    -- UPDATE, a linha do equipamento só é bloqueada quando o status muda de fato.
    v_novo_status := CASE v_severidade WHEN 'CRITICO' THEN 'FALHA' ELSE 'ATENCAO' END;

    PERFORM set_config('fabrica.motivo_status',
                       format('Alerta #%s - %s', v_alerta_id, v_severidade), true);
    PERFORM set_config('fabrica.alerta_status', v_alerta_id::text, true);

    UPDATE fabrica.equipamento
       SET status = v_novo_status,
           status_desde = clock_timestamp(),
           ultimo_alerta_id = v_alerta_id
     WHERE id = v_cfg.equipamento_id
       AND status IN ('OPERANDO', 'ATENCAO')
       AND status < v_novo_status;
    GET DIAGNOSTICS v_status_mudou = ROW_COUNT;

    IF v_status_mudou = 0 THEN   -- contexto não consumido pela trigger temporal
        PERFORM set_config('fabrica.motivo_status', '', true);
        PERFORM set_config('fabrica.alerta_status', '', true);
    END IF;

    -- Notificação em tempo real (LISTEN alertas_fabrica) apenas em eventos
    -- relevantes, para não inundar o canal durante uma rajada de anomalias.
    IF v_alerta_novo OR v_status_mudou > 0 THEN
        PERFORM pg_notify('alertas_fabrica', json_build_object(
            'alerta_id',   v_alerta_id,
            'equipamento', v_cfg.equip_codigo,
            'sensor',      v_cfg.sensor_codigo,
            'severidade',  v_severidade,
            'valor',       round(NEW.valor::numeric, 2),
            'limite',      v_limite,
            'novo_status', CASE WHEN v_status_mudou > 0 THEN v_novo_status::text END,
            'lido_em',     NEW.lido_em)::text);
    END IF;

    RETURN NULL;   -- AFTER trigger: valor de retorno ignorado
END;
$$;

-- Trigger no pai particionado: é clonada automaticamente em todas as
-- partições, inclusive nas criadas no futuro.
CREATE TRIGGER tg_telemetria_verificar_limites
AFTER INSERT ON telemetria
FOR EACH ROW
EXECUTE FUNCTION fn_tg_verificar_limites();

-- -----------------------------------------------------------------------------
-- 2) Tabela temporal: fecha o intervalo do status anterior e abre o novo.
--    Usa clock_timestamp() (e não now()) para que duas mudanças na mesma
--    transação gerem intervalos distintos e não vazios.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tg_status_temporal()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_agora     timestamptz := clock_timestamp();
    v_motivo    text   := NULLIF(current_setting('fabrica.motivo_status', true), '');
    v_alerta_id bigint := NULLIF(current_setting('fabrica.alerta_status', true), '')::bigint;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        UPDATE fabrica.equipamento_status_historico
           SET periodo = tstzrange(lower(periodo), v_agora, '[)')
         WHERE equipamento_id = NEW.id
           AND upper_inf(periodo);
    ELSE
        v_motivo := 'Cadastro do equipamento';
        v_alerta_id := NULL;
    END IF;

    INSERT INTO fabrica.equipamento_status_historico (equipamento_id, status, periodo, motivo, alerta_id)
    VALUES (NEW.id, NEW.status, tstzrange(v_agora, NULL, '[)'), COALESCE(v_motivo, 'Alteração manual'), v_alerta_id);

    -- Limpa o contexto para não contaminar mudanças seguintes na transação.
    PERFORM set_config('fabrica.motivo_status', '', true);
    PERFORM set_config('fabrica.alerta_status', '', true);
    RETURN NULL;
END;
$$;

CREATE TRIGGER tg_equipamento_status_temporal_ins
AFTER INSERT ON equipamento
FOR EACH ROW
EXECUTE FUNCTION fn_tg_status_temporal();

CREATE TRIGGER tg_equipamento_status_temporal_upd
AFTER UPDATE OF status ON equipamento
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_tg_status_temporal();
