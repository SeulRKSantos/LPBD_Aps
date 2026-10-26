#!/usr/bin/env bash
# =============================================================================
# APS LPBD - Setup completo no Ubuntu
#   1) Instala PostgreSQL (+ pg_cron, se disponível no repositório)
#   2) Configura fuso horário, WAL e pg_cron
#   3) Cria um usuário do banco com o seu usuário Linux (acesso via peer auth)
#   4) Cria o banco fabrica_iot, roda os scripts SQL e gera o histórico simulado
#
# Uso:
#   ./setup.sh                       instala tudo e cria o banco
#   ./setup.sh --recriar             apaga e recria o banco (mantém a instalação)
#   ./setup.sh --sem-instalar        pula apt/configuração do servidor (só o banco)
#   ./setup.sh --leituras 5000000    tamanho do histórico simulado (padrão 2.000.000)
#   ./setup.sh --dias 60             dias de histórico (padrão 45; > 30 para testar o arquivamento)
# =============================================================================
set -euo pipefail

DB="${DB:-fabrica_iot}"
LEITURAS=2000000
DIAS=45
INSTALAR=1
RECRIAR=0
DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --sem-instalar) INSTALAR=0 ;;
        --recriar)      RECRIAR=1 ;;
        --leituras)     LEITURAS="$2"; shift ;;
        --dias)         DIAS="$2"; shift ;;
        -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Opção desconhecida: $1"; exit 1 ;;
    esac
    shift
done

passo() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
aviso() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*"; }
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

# -----------------------------------------------------------------------------
# 1-3) Instalação e configuração do servidor (requer sudo)
# -----------------------------------------------------------------------------
if [ "$INSTALAR" -eq 1 ]; then
    passo "Instalando PostgreSQL"
    sudo apt-get update -q || aviso "apt-get update terminou com erros em outros repositórios; seguindo com a instalação."
    sudo apt-get install -y -q postgresql postgresql-contrib

    PGVER="$(ls /usr/lib/postgresql | sort -V | tail -1)"
    CONF_DIR="/etc/postgresql/${PGVER}/main"
    echo "PostgreSQL ${PGVER} | configuração em ${CONF_DIR}"

    passo "Instalando pg_cron (agendamento dentro do banco)"
    if ! sudo apt-get install -y -q "postgresql-${PGVER}-cron"; then
        aviso "pg_cron não encontrado no repositório. Os agendamentos ficarão no crontab (ver README)."
    fi

    passo "Configurando o servidor"
    sudo mkdir -p "${CONF_DIR}/conf.d"
    if ! sudo grep -Eq "^\s*include_dir\s*=\s*'conf.d'" "${CONF_DIR}/postgresql.conf"; then
        echo "include_dir = 'conf.d'" | sudo tee -a "${CONF_DIR}/postgresql.conf" >/dev/null
    fi

    CONF_TMP="$(mktemp)"
    cat > "$CONF_TMP" <<EOF
# APS LPBD - Telemetria IoT
timezone = 'America/Sao_Paulo'
log_timezone = 'America/Sao_Paulo'
max_wal_size = '2GB'                  # menos checkpoints durante a carga massiva
checkpoint_completion_target = 0.9
EOF
    if [ -f "/usr/lib/postgresql/${PGVER}/lib/pg_cron.so" ]; then
        cat >> "$CONF_TMP" <<EOF
shared_preload_libraries = 'pg_cron'
cron.database_name = '${DB}'
cron.use_background_workers = on      # jobs rodam sem precisar de senha/conexão TCP
cron.timezone = 'America/Sao_Paulo'
max_worker_processes = 16
EOF
    fi
    sudo install -m 644 -o postgres -g postgres "$CONF_TMP" "${CONF_DIR}/conf.d/90-aps-lpbd.conf"
    rm -f "$CONF_TMP"

    sudo systemctl enable postgresql >/dev/null 2>&1 || true
    sudo systemctl restart postgresql
    until pg_isready -q; do sleep 1; done

    passo "Criando o usuário do banco '${USER}' (superusuário local de desenvolvimento)"
    if ! sudo -u postgres psql -XtAc "SELECT 1 FROM pg_roles WHERE rolname = '${USER}'" | grep -q 1; then
        sudo -u postgres createuser --superuser "${USER}"
    else
        echo "Usuário já existe."
    fi
fi

# -----------------------------------------------------------------------------
# 4) Banco de dados
# -----------------------------------------------------------------------------
passo "Criando o banco ${DB}"
EXISTE="$(psql -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB}'")"
if [ "$EXISTE" = "1" ]; then
    if [ "$RECRIAR" -eq 1 ]; then
        # pg_cron mantém uma conexão no banco; ela é encerrada antes do DROP.
        "${PSQL[@]}" -d postgres -c "DROP DATABASE ${DB} WITH (FORCE)"
    else
        echo "O banco ${DB} já existe. Use --recriar para apagá-lo e criar de novo."
        exit 1
    fi
fi
"${PSQL[@]}" -d postgres <<EOF
CREATE DATABASE ${DB};
ALTER DATABASE ${DB} SET timezone = 'America/Sao_Paulo';
ALTER DATABASE ${DB} SET search_path = fabrica, public;
EOF

passo "Executando os scripts SQL"
for f in "$DIR"/sql/0[1-8]_*.sql; do
    echo "  - $(basename "$f")"
    "${PSQL[@]}" -1 -d "$DB" -f "$f"
done

passo "Criando partições diárias (${DIAS} dias atrás até 7 dias à frente)"
"${PSQL[@]}" -d "$DB" -tAc "SELECT fabrica.fn_garantir_particoes(current_date - ${DIAS}, current_date + 7) || ' partições criadas'"

passo "Gerando histórico simulado: ${LEITURAS} leituras em ${DIAS} dias (sem triggers, como importação)"
"${PSQL[@]}" -d "$DB" -c "CALL fabrica.sp_simular_fluxo(${LEITURAS}, 0.2, (current_date - ${DIAS})::timestamptz, now() - interval '1 minute', 100000, false)"

passo "Atualizando relatórios e estatísticas"
"${PSQL[@]}" -d "$DB" -c "CALL fabrica.sp_atualizar_relatorios()" -c "ANALYZE"

passo "Resumo"
psql -X -d "$DB" <<'EOF'
SELECT (SELECT count(*) FROM fabrica.equipamento) AS equipamentos,
       (SELECT count(*) FROM fabrica.sensor)      AS sensores,
       (SELECT count(*) FROM fabrica.telemetria)  AS leituras_operacionais,
       (SELECT count(*) FROM fabrica.vw_particoes WHERE tabela_pai = 'telemetria') AS particoes,
       pg_size_pretty(pg_database_size(current_database())) AS tamanho_banco;
SELECT detalhes->>'leituras_por_segundo' AS "vazão da carga (leituras/s)"
  FROM fabrica.log_rotina WHERE rotina = 'SIMULADOR_FLUXO' ORDER BY id DESC LIMIT 1;
EOF

if psql -X -d "$DB" -tAc "SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'" | grep -q 1; then
    echo "Agendamentos ativos no pg_cron:"
    psql -X -d "$DB" -c "SELECT jobname, schedule, command FROM cron.job ORDER BY jobid"
else
    aviso "Sem pg_cron: configure o crontab conforme a seção 'Agendamento' do README."
fi

printf '\n\033[1;32mPronto!\033[0m Conecte com:  psql %s\n' "$DB"
