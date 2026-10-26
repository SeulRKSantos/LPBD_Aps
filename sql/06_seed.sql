-- =============================================================================
-- 06_seed.sql - Dados de cadastro da fábrica simulada
--   4 áreas, 5 grandezas, 16 equipamentos, 37 sensores e seus limites.
--   Os limites são por máquina: a CALD-02 (mais antiga) tem limites mais
--   conservadores que as demais caldeiras.
-- =============================================================================
SET search_path = fabrica, public;

INSERT INTO area (nome) VALUES
    ('Caldeiraria'), ('Usinagem'), ('Prensagem'), ('Expedição');

INSERT INTO tipo_sensor (codigo, descricao, unidade) VALUES
    ('TEMP',  'Temperatura',                 '°C'),
    ('VIB',   'Vibração (velocidade RMS)',   'mm/s'),
    ('PRESS', 'Pressão',                     'bar'),
    ('VEL',   'Velocidade da esteira',       'm/min'),
    ('CORR',  'Corrente elétrica do motor',  'A');

INSERT INTO equipamento (codigo, nome, categoria, area_id)
SELECT v.codigo, v.nome, v.categoria, a.id
  FROM (VALUES
        ('CALD-01', 'Caldeira a vapor 01',       'CALDEIRA',          'Caldeiraria'),
        ('CALD-02', 'Caldeira a vapor 02',       'CALDEIRA',          'Caldeiraria'),
        ('CALD-03', 'Caldeira a vapor 03',       'CALDEIRA',          'Caldeiraria'),
        ('MOT-01',  'Motor do torno CNC 01',     'MOTOR',             'Usinagem'),
        ('MOT-02',  'Motor do torno CNC 02',     'MOTOR',             'Usinagem'),
        ('MOT-03',  'Motor da fresadora 01',     'MOTOR',             'Usinagem'),
        ('MOT-04',  'Motor do compressor',       'MOTOR',             'Usinagem'),
        ('MOT-05',  'Motor da bomba de água',    'MOTOR',             'Caldeiraria'),
        ('PRE-01',  'Prensa hidráulica 200 t',   'PRENSA_HIDRAULICA', 'Prensagem'),
        ('PRE-02',  'Prensa hidráulica 400 t',   'PRENSA_HIDRAULICA', 'Prensagem'),
        ('PRE-03',  'Prensa hidráulica 100 t',   'PRENSA_HIDRAULICA', 'Prensagem'),
        ('EST-01',  'Esteira de alimentação',    'ESTEIRA',           'Prensagem'),
        ('EST-02',  'Esteira de transferência',  'ESTEIRA',           'Usinagem'),
        ('EST-03',  'Esteira de embalagem',      'ESTEIRA',           'Expedição'),
        ('EST-04',  'Esteira de paletização',    'ESTEIRA',           'Expedição'),
        ('EST-05',  'Esteira de inspeção',       'ESTEIRA',           'Expedição')
       ) AS v(codigo, nome, categoria, area)
  JOIN area a ON a.nome = v.area
 ORDER BY v.codigo;   -- ids previsíveis: CALD-01 = 1, CALD-02 = 2, ...

-- Modelo de sensores e limites por categoria de equipamento.
CREATE TEMP TABLE tmp_modelo (
    categoria text, grandeza text,
    normal_min double precision, normal_max double precision,
    critico_min double precision, critico_max double precision
);

INSERT INTO tmp_modelo VALUES
    -- caldeiras
    ('CALDEIRA',          'TEMP',  160,  190,  120,  210),
    ('CALDEIRA',          'PRESS',   8,   10,    6,   12),
    -- motores (vibração conforme zonas típicas da ISO 10816)
    ('MOTOR',             'VIB',   0.2,  4.5, NULL,  7.1),
    ('MOTOR',             'TEMP',   40,   80, NULL,   95),
    ('MOTOR',             'CORR',   20,   45, NULL,   55),
    -- prensas hidráulicas
    ('PRENSA_HIDRAULICA', 'PRESS', 150,  200,  100,  230),
    ('PRENSA_HIDRAULICA', 'TEMP',   35,   60, NULL,   70),
    -- esteiras
    ('ESTEIRA',           'VEL',    18,   22,   10,   28),
    ('ESTEIRA',           'VIB',   0.3,  3.0, NULL,  5.0);

INSERT INTO sensor (codigo, equipamento_id, tipo_sensor_id, instalado_em)
SELECT e.codigo || '-' || ts.codigo, e.id, ts.id, current_date - 365
  FROM equipamento e
  JOIN tmp_modelo m  ON m.categoria = e.categoria
  JOIN tipo_sensor ts ON ts.codigo = m.grandeza
 ORDER BY e.id, ts.id;

INSERT INTO limite_operacional (equipamento_id, tipo_sensor_id, normal_min, normal_max, critico_min, critico_max)
SELECT e.id, ts.id, m.normal_min, m.normal_max, m.critico_min, m.critico_max
  FROM equipamento e
  JOIN tmp_modelo m  ON m.categoria = e.categoria
  JOIN tipo_sensor ts ON ts.codigo = m.grandeza;

-- Limite específico de máquina: CALD-02 é mais antiga e opera com folga menor.
UPDATE limite_operacional l
   SET normal_max = 180, critico_max = 195, normal_min = 155, atualizado_em = now()
  FROM equipamento e, tipo_sensor ts
 WHERE l.equipamento_id = e.id AND l.tipo_sensor_id = ts.id
   AND e.codigo = 'CALD-02' AND ts.codigo = 'TEMP';

DROP TABLE tmp_modelo;
