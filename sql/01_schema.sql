-- =============================================================================
-- APS LPBD - Banco de Dados de Alta Performance para Telemetria IoT
-- 01_schema.sql - Extensões, tipos, tabelas e índices base
-- SGBD: PostgreSQL 14+ (testado no 16) | Linguagem procedural: PL/pgSQL
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- restrição de exclusão temporal (id = AND período &&)

CREATE SCHEMA IF NOT EXISTS fabrica;
SET search_path = fabrica, public;

-- -----------------------------------------------------------------------------
-- Tipos enumerados (a ordem de declaração define a ordem de comparação)
-- -----------------------------------------------------------------------------
-- OPERANDO < ATENCAO < FALHA : usado pela trigger para "só piorar" o status.
-- MANUTENCAO e DESLIGADO são estados manuais que a trigger nunca sobrescreve.
CREATE TYPE equipamento_status AS ENUM ('OPERANDO', 'ATENCAO', 'FALHA', 'MANUTENCAO', 'DESLIGADO');
CREATE TYPE alerta_severidade  AS ENUM ('ATENCAO', 'CRITICO');
CREATE TYPE alerta_situacao    AS ENUM ('ABERTO', 'RECONHECIDO', 'RESOLVIDO');
CREATE TYPE alerta_violacao    AS ENUM ('ACIMA_MAXIMO', 'ABAIXO_MINIMO');

-- -----------------------------------------------------------------------------
-- Cadastros de controle
-- -----------------------------------------------------------------------------
CREATE TABLE area (
    id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome    text NOT NULL UNIQUE
);

CREATE TABLE tipo_sensor (
    id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo    text NOT NULL UNIQUE,          -- TEMP, VIB, PRESS, VEL, CORR
    descricao text NOT NULL,
    unidade   text NOT NULL
);

CREATE TABLE equipamento (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo           text NOT NULL UNIQUE,
    nome             text NOT NULL,
    categoria        text NOT NULL CHECK (categoria IN ('CALDEIRA', 'MOTOR', 'PRENSA_HIDRAULICA', 'ESTEIRA')),
    area_id          smallint NOT NULL REFERENCES area (id),
    status           equipamento_status NOT NULL DEFAULT 'OPERANDO',
    status_desde     timestamptz NOT NULL DEFAULT clock_timestamp(),
    ultimo_alerta_id bigint,
    criado_em        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sensor (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo         text NOT NULL UNIQUE,
    equipamento_id integer  NOT NULL REFERENCES equipamento (id),
    tipo_sensor_id smallint NOT NULL REFERENCES tipo_sensor (id),
    ativo          boolean  NOT NULL DEFAULT true,
    instalado_em   date     NOT NULL DEFAULT current_date,
    UNIQUE (equipamento_id, tipo_sensor_id)
);
CREATE INDEX ix_sensor_equipamento ON sensor (equipamento_id);

-- Limites de segurança configurados POR MÁQUINA e por grandeza medida.
-- Fora de [normal_min, normal_max]   -> alerta de ATENÇÃO
-- Fora de [critico_min, critico_max] -> alerta CRÍTICO (equipamento entra em FALHA)
-- Limites críticos podem ser nulos (ex.: temperatura sem limite inferior crítico).
CREATE TABLE limite_operacional (
    equipamento_id integer  NOT NULL REFERENCES equipamento (id),
    tipo_sensor_id smallint NOT NULL REFERENCES tipo_sensor (id),
    normal_min     double precision NOT NULL,
    normal_max     double precision NOT NULL,
    critico_min    double precision,
    critico_max    double precision,
    atualizado_em  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (equipamento_id, tipo_sensor_id),
    CHECK (normal_min < normal_max),
    CHECK (critico_min IS NULL OR critico_min <= normal_min),
    CHECK (critico_max IS NULL OR critico_max >= normal_max)
);

-- -----------------------------------------------------------------------------
-- Telemetria operacional: PARTICIONADA POR DIA (RANGE em lido_em)
-- Mantém apenas os últimos 30 dias; o restante vai para telemetria_historico.
-- A chave primária precisa conter a chave de particionamento.
-- -----------------------------------------------------------------------------
CREATE TABLE telemetria (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    sensor_id   integer NOT NULL REFERENCES sensor (id),
    lido_em     timestamptz NOT NULL DEFAULT now(),
    valor       double precision NOT NULL,
    recebido_em timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, lido_em)
) PARTITION BY RANGE (lido_em);

-- Partição DEFAULT: rede de segurança para leituras fora das partições criadas.
CREATE TABLE telemetria_default PARTITION OF telemetria DEFAULT;

-- Índices declarados no pai são criados automaticamente em todas as partições.
-- Composto B-Tree: "leituras do sensor X no intervalo Y" e "últimas N leituras".
CREATE INDEX ix_telemetria_sensor_tempo ON telemetria (sensor_id, lido_em DESC);
-- BRIN: índice minúsculo, ideal para dados inseridos em ordem temporal.
CREATE INDEX ix_telemetria_tempo_brin ON telemetria USING brin (lido_em) WITH (pages_per_range = 32);

-- -----------------------------------------------------------------------------
-- Telemetria histórica (> 30 dias): PARTICIONADA POR MÊS.
-- Sem FK para não impedir a remoção futura de sensores desativados.
-- -----------------------------------------------------------------------------
CREATE TABLE telemetria_historico (
    id           bigint NOT NULL,
    sensor_id    integer NOT NULL,
    lido_em      timestamptz NOT NULL,
    valor        double precision NOT NULL,
    recebido_em  timestamptz NOT NULL,
    arquivado_em timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, lido_em)
) PARTITION BY RANGE (lido_em);

CREATE INDEX ix_hist_sensor_tempo ON telemetria_historico (sensor_id, lido_em);
CREATE INDEX ix_hist_tempo_brin   ON telemetria_historico USING brin (lido_em);

-- -----------------------------------------------------------------------------
-- Alertas
-- Um alerta "aberto" por sensor: novas violações do mesmo sensor incrementam
-- o contador de ocorrências em vez de gerar milhares de linhas repetidas
-- (controlado pelo índice único parcial + INSERT ... ON CONFLICT na trigger).
-- -----------------------------------------------------------------------------
CREATE TABLE alerta (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sensor_id           integer NOT NULL REFERENCES sensor (id),
    equipamento_id      integer NOT NULL REFERENCES equipamento (id),
    telemetria_id       bigint  NOT NULL,          -- leitura que abriu o alerta
    severidade          alerta_severidade NOT NULL,
    violacao            alerta_violacao   NOT NULL,
    valor_lido          double precision NOT NULL,  -- valor da 1ª leitura
    valor_pico          double precision NOT NULL,  -- pior valor observado
    limite_violado      double precision NOT NULL,
    ocorrencias         integer NOT NULL DEFAULT 1,
    primeira_ocorrencia timestamptz NOT NULL,
    ultima_ocorrencia   timestamptz NOT NULL,
    situacao            alerta_situacao NOT NULL DEFAULT 'ABERTO',
    registrado_em       timestamptz NOT NULL DEFAULT clock_timestamp(),
    reconhecido_por     text,
    reconhecido_em      timestamptz,
    resolvido_por       text,
    resolvido_em        timestamptz,
    observacao          text,
    mensagem            text NOT NULL
);

CREATE UNIQUE INDEX ux_alerta_aberto_por_sensor ON alerta (sensor_id) WHERE situacao <> 'RESOLVIDO';
CREATE INDEX ix_alerta_equipamento ON alerta (equipamento_id, situacao);
CREATE INDEX ix_alerta_registro    ON alerta (registrado_em DESC);

ALTER TABLE equipamento
    ADD CONSTRAINT fk_equipamento_ultimo_alerta FOREIGN KEY (ultimo_alerta_id) REFERENCES alerta (id);

-- -----------------------------------------------------------------------------
-- TABELA TEMPORAL: histórico de status de cada equipamento (tempo de validade).
-- Cada linha é válida no intervalo "periodo" [início, fim). O intervalo atual
-- tem fim aberto (infinito). A restrição de exclusão GiST garante que um
-- equipamento nunca tenha dois status ao mesmo tempo.
-- -----------------------------------------------------------------------------
CREATE TABLE equipamento_status_historico (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipamento_id integer NOT NULL REFERENCES equipamento (id),
    status         equipamento_status NOT NULL,
    periodo        tstzrange NOT NULL,
    motivo         text,
    alerta_id      bigint REFERENCES alerta (id),
    CONSTRAINT ex_status_sem_sobreposicao
        EXCLUDE USING gist (equipamento_id WITH =, periodo WITH &&)
);
CREATE INDEX ix_status_hist_atual ON equipamento_status_historico (equipamento_id) WHERE upper_inf(periodo);

-- -----------------------------------------------------------------------------
-- Logs de rotinas (simulação, arquivamento, criação de partições, refresh)
-- -----------------------------------------------------------------------------
CREATE TABLE log_rotina (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rotina         text NOT NULL,
    iniciado_em    timestamptz NOT NULL DEFAULT clock_timestamp(),
    finalizado_em  timestamptz,
    situacao       text NOT NULL DEFAULT 'EXECUTANDO' CHECK (situacao IN ('EXECUTANDO', 'OK', 'ERRO')),
    linhas         bigint,
    parametros     jsonb,
    detalhes       jsonb
);
CREATE INDEX ix_log_rotina ON log_rotina (rotina, iniciado_em DESC);

-- -----------------------------------------------------------------------------
-- Resultados do benchmark de consultas (preenchidos por 08_benchmark.sql)
-- -----------------------------------------------------------------------------
CREATE TABLE benchmark_resultado (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    execucao      integer NOT NULL,
    cenario       text NOT NULL,
    consulta      text NOT NULL,
    repeticoes    integer NOT NULL,
    media_ms      numeric(12,3) NOT NULL,
    mediana_ms    numeric(12,3) NOT NULL,
    min_ms        numeric(12,3) NOT NULL,
    max_ms        numeric(12,3) NOT NULL,
    nos_plano     text,
    plano         jsonb,
    executado_em  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE benchmark_indice (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    execucao         integer NOT NULL,
    cenario          text NOT NULL,
    indice           text NOT NULL,
    metodo           text NOT NULL,
    tamanho_bytes    bigint NOT NULL,
    tempo_criacao_ms numeric(12,3) NOT NULL
);

CREATE SEQUENCE benchmark_execucao_seq;
