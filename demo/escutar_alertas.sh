#!/usr/bin/env bash
# Mostra em tempo real as notificações emitidas pela trigger (canal alertas_fabrica).
# O psql só exibe notificações depois de executar um comando, por isso o laço
# envia um SELECT vazio a cada meio segundo.
DB="${DB:-fabrica_iot}"
echo "Escutando o canal 'alertas_fabrica' (Ctrl+C para sair)..."
{
    echo "LISTEN alertas_fabrica;"
    while sleep 0.5; do echo "SELECT 1 \\g /dev/null"; done
} | psql -X -q -d "$DB" 2>&1 \
  | sed -u -E 's/.*"(\{.*\})".*/\1/' \
  | while IFS= read -r linha; do printf '%s  %s\n' "$(date +%H:%M:%S)" "$linha"; done
