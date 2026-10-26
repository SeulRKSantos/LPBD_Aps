#!/usr/bin/env bash
# =============================================================================
# Carga massiva SIMULTÂNEA com pgbench: N clientes (gateways) inserindo
# telemetria ao mesmo tempo, com as triggers reagindo em tempo real.
# Uso: ./demo/carga_concorrente.sh [clientes=16] [segundos=60] [pct_anomalia=0.02]
# =============================================================================
set -euo pipefail

DB="${DB:-fabrica_iot}"
CLIENTES="${1:-16}"
SEGUNDOS="${2:-60}"
ANOMALIA="${3:-0.02}"
DIR="$(cd "$(dirname "$0")" && pwd)"

PGBENCH="$(command -v pgbench || ls /usr/lib/postgresql/*/bin/pgbench 2>/dev/null | sort -V | tail -1)"
if [ -z "$PGBENCH" ]; then
    echo "pgbench não encontrado (vem com o pacote postgresql)."; exit 1
fi

THREADS="$(nproc)"; [ "$THREADS" -gt "$CLIENTES" ] && THREADS="$CLIENTES"
q() { psql -X -q -t -A -d "$DB" -c "$1"; }

q "SELECT fabrica.fn_garantir_particoes(current_date, current_date + 1)" >/dev/null
N_EQUIP="$(q "SELECT max(id) FROM fabrica.equipamento")"
SEQ="$(q "SELECT pg_get_serial_sequence('fabrica.telemetria', 'id')")"
ID_ANTES="$(q "SELECT last_value FROM ${SEQ}")"
OCORR_ANTES="$(q "SELECT COALESCE(sum(ocorrencias), 0) FROM fabrica.alerta")"

echo "Carga concorrente: ${CLIENTES} clientes | ${THREADS} threads | ${SEGUNDOS} s | ${ANOMALIA}% críticas"
"$PGBENCH" -n -c "$CLIENTES" -j "$THREADS" -T "$SEGUNDOS" -P 5 -M prepared \
    -D n_equip="$N_EQUIP" -D anomalia="$ANOMALIA" \
    -f "$DIR/pgbench_gateway.sql" "$DB"

ID_DEPOIS="$(q "SELECT last_value FROM ${SEQ}")"
OCORR_DEPOIS="$(q "SELECT COALESCE(sum(ocorrencias), 0) FROM fabrica.alerta")"
LEITURAS=$((ID_DEPOIS - ID_ANTES))

echo
echo "Leituras inseridas : ${LEITURAS}  (~$((LEITURAS / SEGUNDOS)) leituras/s)"
echo "Violações tratadas pelas triggers: $((OCORR_DEPOIS - OCORR_ANTES))"
psql -X -d "$DB" -c "SELECT equipamento, status, alertas_abertos, maior_severidade, ocorrencias FROM fabrica.vw_painel_equipamentos"
