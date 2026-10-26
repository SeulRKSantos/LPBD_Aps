-- Script do pgbench: cada transação simula o gateway de UM equipamento
-- publicando a leitura de todos os seus sensores de uma só vez.
-- Variáveis recebidas via -D: n_equip (qtd. de equipamentos), anomalia (% crítica)
\set equip random(1, :n_equip)
INSERT INTO fabrica.telemetria (sensor_id, valor)
SELECT s.id, fabrica.fn_leitura_simulada(s.id, :anomalia)
  FROM fabrica.sensor s
 WHERE s.equipamento_id = :equip
   AND s.ativo;
