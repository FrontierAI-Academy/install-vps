#!/usr/bin/env bash
set -euo pipefail

# ======================
# Entradas (desde install.sh)
# ======================
DOMAIN="${DOMAIN:?DOMAIN is required}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL is required}"
MASTER_PASSWORD="${MASTER_PASSWORD:?MASTER_PASSWORD is required (32+ chars recommended)}"
REPO_URL="${REPO_URL:-https://github.com/FrontierAI-Academy/install-vps.git}"
STACK_BRANCH="${STACK_BRANCH:-main}"

log() { echo -e "\033[1;36m[BOOTSTRAP]\033[0m $*"; }
retry() { local n=0; until "$@"; do n=$((n+1)); [[ $n -ge 10 ]] && return 1; sleep 3; done; }

wait_for_container() {
  local pattern="$1"
  local cid=""
  for _ in {1..40}; do
    cid="$(docker ps --filter "name=${pattern}" --format '{{.ID}}' | head -n1 || true)"
    if [[ -n "$cid" ]]; then echo "$cid"; return 0; fi
    sleep 3
  done
  return 1
}

# ======================
# Instalar Docker si falta
# ======================
if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi

# ======================
# Swarm & Redes
# ======================
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
  log "Inicializando Docker Swarm..."
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  docker swarm init --advertise-addr="${IP_ADDR}" || true
fi

# Redes overlay attachable
for net in traefik_public agent_network general_network; do
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    docker network create -d overlay --attachable "$net" >/dev/null 2>&1 || true
  fi
done

# ======================
# Volúmenes (incluye certificados)
# ======================
for v in certificados portainer_data postgres_data redis_data rabbitmq_data minio_data evolution_v2_instances chatwoot_data; do
  docker volume create "$v" >/dev/null 2>&1 || true
done

# acme.json 600 para Traefik
docker run --rm -v certificados:/letsencrypt alpine \
  sh -c "touch /letsencrypt/acme.json && chmod 600 /letsencrypt/acme.json"

# ======================
# Descargar repo de stacks (fresco)
# ======================
log "Descargando repositorio de stacks..."
mkdir -p /opt/stacks && cd /opt/stacks
rm -rf repo || true
retry git clone --depth 1 -b "$STACK_BRANCH" "$REPO_URL" repo
cd repo

# ======================
# .env para sustitución en YAML
# ======================
cat > .env <<EOF
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
PASSWORD_32_LENGTH=${MASTER_PASSWORD}
EOF

# ======================
# Despliegue base
# ======================
log "Desplegando Traefik..."
docker stack deploy -c traefik.yaml traefik
sleep 8

log "Desplegando Portainer..."
docker stack deploy -c portainer.yaml portainer
sleep 5

log "Desplegando Postgres..."
docker stack deploy -c postgres.yaml postgres
sleep 5

log "Desplegando Redis..."
docker stack deploy -c redis.yaml redis
sleep 5

log "Desplegando RabbitMQ..."
docker stack deploy -c rabbitmq.yaml rabbitmq
sleep 5

log "Desplegando MinIO..."
docker stack deploy -c minio.yaml minio

# Esperar a que MinIO esté ready (200)
log "Esperando a que MinIO responda /minio/health/ready..."
for _ in {1..40}; do
  code="$(curl -sk -o /dev/null -w "%{http_code}" "https://miniobackapp.${DOMAIN}/minio/health/ready" || echo 000)"
  [[ "$code" == "200" ]] && break
  sleep 3
done

# ======================
# Preparar bases en Postgres (idempotente)
# ======================
log "Creando bases de datos (chatwoot, evolution2, n8n_fila)..."
PG_ID="$(docker ps --filter name=postgres_postgres --format '{{.ID}}' | head -n1 || true)"
if [[ -n "${PG_ID}" ]]; then
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE chatwoot;"  >/dev/null 2>&1 || true
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE evolution2;" >/dev/null 2>&1 || true
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE n8n_fila;"  >/dev/null 2>&1 || true
fi

# ======================
# MinIO: bucket + usuario + policy (crea credenciales S3 para Evolution)
# ======================
log "Configurando MinIO para Evolution (bucket/usuario/política)..."
MINIO_BUCKET="${MINIO_BUCKET:-evolutionapi}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-$(openssl rand -hex 12)}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-$(openssl rand -hex 24)}"

# Añadir variables S3 al .env para que evolution.yaml las use
cp .env .env.tmp
cat >> .env.tmp <<EOF
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
EOF
mv .env.tmp .env

# Helper de mc (cada llamada pasa MC_HOST_myminio y --insecure)
run_mc() {
  docker run --rm --network host \
    -e MC_HOST_myminio="https://root:${MASTER_PASSWORD}@miniobackapp.${DOMAIN}" \
    minio/mc --insecure "$@"
}

# Crear bucket y usuario (idempotente, sin 'mc ls' previo)
retry run_mc mb "myminio/${MINIO_BUCKET}" || true
retry run_mc admin user add myminio "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" || true
retry run_mc admin policy attach myminio readwrite --user "${MINIO_ACCESS_KEY}" || true

# ======================
# Aplicaciones
# ======================
log "Desplegando Chatwoot..."
docker stack deploy -c chatwoot.yaml chatwoot
sleep 8

log "Preparando base de Chatwoot..."
CW_CID="$(wait_for_container 'chatwoot_chatwoot_app' || true)"
if [[ -n "${CW_CID}" ]]; then
  retry docker exec -i "${CW_CID}" bundle exec rails db:chatwoot_prepare || true
else
  log "AVISO: No se encontró el contenedor de Chatwoot para ejecutar db:chatwoot_prepare"
fi

log "Desplegando Evolution API..."
docker stack deploy -c evolution.yaml evolution
sleep 8

log "Desplegando n8n..."
docker stack deploy -c n8n.yaml n8n

# ======================
# Resumen
# ======================
log "¡Listo!"
echo "  Portainer:   https://portainerapp.${DOMAIN}"
echo "  n8n:         https://n8napp.${DOMAIN}  (webhook: https://n8nwebhookapp.${DOMAIN})"
echo "  Chatwoot:    https://chatwootapp.${DOMAIN}"
echo "  Evolution:   https://evolutionapiapp.${DOMAIN}"
echo "  MinIO S3:    https://miniobackapp.${DOMAIN}  (Consola: https://miniofrontapp.${DOMAIN})"
echo "  RabbitMQ:    https://rabbitmqapp.${DOMAIN}"
