#!/usr/bin/env bash
set -euo pipefail

# ======================
# Inputs (from install.sh)
# ======================
DOMAIN="${DOMAIN:?DOMAIN is required}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL is required}"
MASTER_PASSWORD="${MASTER_PASSWORD:?MASTER_PASSWORD is required (32+ chars recommended)}"
REPO_URL="${REPO_URL:-https://github.com/FrontierAI-Academy/install-vps.git}"
STACK_BRANCH="${STACK_BRANCH:-main}"

log() { echo -e "\033[1;36m[BOOTSTRAP]\033[0m $*"; }
retry() { local n=0; until "$@"; do n=$((n+1)); [[ $n -ge 10 ]] && return 1; sleep 3; done; }

# Wait for a running container by name (grep filter)
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
# Docker install
# ======================
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi

# ======================
# Swarm & Networks
# ======================
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
  log "Initializing Docker Swarm..."
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  docker swarm init --advertise-addr="${IP_ADDR}" || true
fi

# Create overlay networks as attachable (idempotent)
for net in traefik_public agent_network general_network; do
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    docker network create -d overlay --attachable "$net" >/dev/null 2>&1 || true
  fi
done

# ======================
# Volumes (incl. certificates)
# ======================
for v in certificados portainer_data postgres_data redis_data rabbitmq_data minio_data evolution_v2_instances chatwoot_data; do
  docker volume create "$v" >/dev/null 2>&1 || true
done

# Ensure acme.json exists with 600 permissions for Traefik
docker run --rm -v certificados:/letsencrypt alpine \
  sh -c "touch /letsencrypt/acme.json && chmod 600 /letsencrypt/acme.json"

# ======================
# Fetch stacks repo (fresh)
# ======================
log "Fetching stacks repo..."
mkdir -p /opt/stacks && cd /opt/stacks
rm -rf repo || true
retry git clone --depth 1 -b "$STACK_BRANCH" "$REPO_URL" repo
cd repo

# ======================
# .env for compose substitution
# ======================
cat > .env <<EOF
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
PASSWORD_32_LENGTH=${MASTER_PASSWORD}
EOF

# ======================
# Deploy base stacks
# ======================
log "Deploying Traefik..."
docker stack deploy -c traefik.yaml traefik
sleep 8

log "Deploying Portainer..."
docker stack deploy -c portainer.yaml portainer
sleep 5

log "Deploying Postgres..."
docker stack deploy -c postgres.yaml postgres
sleep 5

log "Deploying Redis..."
docker stack deploy -c redis.yaml redis
sleep 5

log "Deploying RabbitMQ..."
docker stack deploy -c rabbitmq.yaml rabbitmq
sleep 5

log "Deploying MinIO..."
docker stack deploy -c minio.yaml minio
sleep 10

# ======================
# Prepare Postgres databases (idempotent)
# ======================
log "Creating databases (chatwoot, evolution2, n8n_fila)..."
PG_ID="$(docker ps --filter name=postgres_postgres --format '{{.ID}}' | head -n1 || true)"
if [[ -n "${PG_ID}" ]]; then
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE chatwoot;"  >/dev/null 2>&1 || true
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE evolution2;" >/dev/null 2>&1 || true
  docker exec -i "$PG_ID" psql -U postgres -c "CREATE DATABASE n8n_fila;"  >/dev/null 2>&1 || true
fi

# ======================
# MinIO: bucket + user + policy (auto S3 creds for Evolution)
# ======================
log "Configuring MinIO for Evolution (bucket/user/policy)..."
MINIO_BUCKET="${MINIO_BUCKET:-evolutionapi}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-$(openssl rand -hex 12)}"   # ~24 chars
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-$(openssl rand -hex 24)}"   # ~48 chars

# Append S3 vars to .env so compose can substitute in evolution.yaml
cp .env .env.tmp
cat >> .env.tmp <<EOF
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
EOF
mv .env.tmp .env

# Configure MinIO via mc using root/${MASTER_PASSWORD}
# NOTE: minio.yaml must set MINIO_ROOT_USER=root and MINIO_ROOT_PASSWORD=${PASSWORD_32_LENGTH}
# Use --network host to avoid overlay attach restrictions
retry docker run --rm --network host \
  -e MC_HOST_myminio="https://root:${MASTER_PASSWORD}@miniobackapp.${DOMAIN}" \
  minio/mc sh -c "
    set -e
    mc alias ls >/dev/null
    mc mb myminio/${MINIO_BUCKET} || true
    cat >/tmp/evolution-s3-policy.json <<POL
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:*\"],
      \"Resource\": [
        \"arn:aws:s3:::${MINIO_BUCKET}\",
        \"arn:aws:s3:::${MINIO_BUCKET}/*\"
      ]
    }
  ]
}
POL
    mc admin policy create myminio evolution-s3-policy /tmp/evolution-s3-policy.json || true
    mc admin user add myminio ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} || true
    mc admin policy attach myminio evolution-s3-policy --user ${MINIO_ACCESS_KEY}
  "

# ======================
# Apps
# ======================
log "Deploying Chatwoot..."
docker stack deploy -c chatwoot.yaml chatwoot
sleep 8

# Prepare Chatwoot DB (idempotent)
log "Preparing Chatwoot database..."
CW_CID="$(wait_for_container 'chatwoot_chatwoot_app' || true)"
if [[ -n "${CW_CID}" ]]; then
  # Retry in case rails is still booting
  retry docker exec -i "${CW_CID}" bundle exec rails db:chatwoot_prepare || true
else
  log "WARNING: Chatwoot app container not found to run db:chatwoot_prepare"
fi

log "Deploying Evolution API..."
docker stack deploy -c evolution.yaml evolution
sleep 8

log "Deploying n8n..."
docker stack deploy -c n8n.yaml n8n

# ======================
# Summary
# ======================
log "All done!"
echo "  Portainer:   https://portainerapp.${DOMAIN}"
echo "  n8n:         https://n8napp.${DOMAIN}  (webhook: https://n8nwebhookapp.${DOMAIN})"
echo "  Chatwoot:    https://chatwootapp.${DOMAIN}"
echo "  Evolution:   https://evolutionapiapp.${DOMAIN}"
echo "  MinIO S3:    https://miniobackapp.${DOMAIN}  (Console: https://miniofrontapp.${DOMAIN})"
echo "  RabbitMQ:    https://rabbitmqapp.${DOMAIN}"
