-- =============================================================================
-- 07_agendamentos.sql - Agendamento das rotinas com pg_cron
--   fabrica-manutencao-diaria : 03:00 todo dia -> partições futuras + arquivamento
--                               (> 30 dias) + refresh dos relatórios
--   fabrica-refresh-relatorios: a cada 5 minutos -> REFRESH da view materializada
-- Se o pg_cron não estiver instalado/carregado, o script apenas avisa; nesse
-- caso use o crontab do Linux (instruções no README).
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron')
       OR current_setting('shared_preload_libraries') NOT LIKE '%pg_cron%' THEN
        RAISE WARNING 'pg_cron indisponível: agendamentos NÃO criados. Use o crontab do Linux (ver README).';
        RETURN;
    END IF;

    CREATE EXTENSION IF NOT EXISTS pg_cron;

    -- cron.schedule com nome substitui o job se ele já existir (idempotente).
    PERFORM cron.schedule('fabrica-manutencao-diaria',  '0 3 * * *',   'CALL fabrica.sp_manutencao_diaria(30)');
    PERFORM cron.schedule('fabrica-refresh-relatorios', '*/5 * * * *', 'CALL fabrica.sp_atualizar_relatorios()');

    RAISE NOTICE 'pg_cron: jobs agendados. Consulte com: SELECT * FROM cron.job;';
END;
$$;
