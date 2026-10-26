#!/usr/bin/env bash
# Painel atualizado a cada segundo (Ctrl+C para sair).
DB="${DB:-fabrica_iot}"
DIR="$(cd "$(dirname "$0")" && pwd)"
exec watch -n 1 -t "psql -X -q -d '$DB' -f '$DIR/painel.sql'"
