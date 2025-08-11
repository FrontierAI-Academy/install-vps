#!/usr/bin/env bash
set -euo pipefail

# ----------------------
# Inputs / defaults
# ----------------------
DOMAIN=""
ADMIN_EMAIL=""
MASTER_PASSWORD=""
STACK_BRANCH="${STACK_BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/FrontierAI-Academy/install-vps.git}"

# ----------------------
# Args
# ----------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --email) ADMIN_EMAIL="$2"; shift 2;;
    --password) MASTER_PASSWORD="$2"; shift 2;;
    --branch) STACK_BRANCH="$2"; shift 2;;
    --repo) REPO_URL="$2"; shift 2;;
    *) echo "[WARN] Argumento desconocido: $1"; shift;;
  esac
done

# ----------------------
# Helpers (logs en español)
# ----------------------
log()   { echo -e "\033[1;36m[INSTALADOR]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[ADVERTENCIA]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

# ----------------------
# Basic validation
# ----------------------
if [[ -z "$DOMAIN" || -z "$ADMIN_EMAIL" || -z "$MASTER_PASSWORD" ]]; then
  error "Uso: install.sh --domain <dominio> --email <correo_admin> --password <32+ caracteres>"
  exit 1
fi

# (1) Validar longitud de contraseña (≥ 32)
if [[ ${#MASTER_PASSWORD} -lt 32 ]]; then
  error "MASTER_PASSWORD debe tener 32 o más caracteres (usa una cadena aleatoria fuerte)."
  exit 1
fi
log "Parámetros validados correctamente."

# ----------------------
# Ensure tools
# ----------------------
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v ca-certificates >/dev/null 2>&1; then
  log "Instalando dependencias del sistema (git, curl, ca-certificates)..."
  apt-get update -y && apt-get install -y git curl ca-certificates
fi

# ----------------------
# (2) Preflight DNS (solo avisos, NO detiene la instalación)
# ----------------------
log "Verificando DNS (esto no detiene la instalación si falta algo)..."
NEED_HOSTS=( \
  "portainerapp" \
  "miniobackapp" \
  "miniofrontapp" \
  "chatwootapp" \
  "evolutionapiapp" \
  "n8napp" \
  "n8nwebhookapp" \
  "rabbitmqapp" \
)
DNS_MISSING=0
for h in "${NEED_HOSTS[@]}"; do
  if getent hosts "${h}.${DOMAIN}" >/dev/null 2>&1; then
    log "DNS OK: ${h}.${DOMAIN}"
  else
    warn "DNS no resuelve aún: ${h}.${DOMAIN}  (crea el registro A apuntando a la IP del VPS)"
    DNS_MISSING=1
  fi
done
if [[ "$DNS_MISSING" -eq 1 ]]; then
  warn "Algunos registros DNS no resuelven. Puedes continuar, pero Traefik/Let's Encrypt tardarán o fallarán hasta que estén creados."
fi

# ----------------------
# (5) Firewall: abrir 80/443 (y SSH)
# ----------------------
if ! command -v ufw >/dev/null 2>&1; then
  log "Instalando UFW (firewall)..."
  apt-get update -y && apt-get install -y ufw
fi

log "Configurando firewall (UFW): permitirá SSH y HTTP/HTTPS..."
# reglas idempotentes
ufw --force allow OpenSSH >/dev/null 2>&1 || true
ufw --force allow 80/tcp    >/dev/null 2>&1 || true
ufw --force allow 443/tcp   >/dev/null 2>&1 || true

# políticas por defecto seguras si UFW no estaba activo
if ! ufw status | grep -q "Status: active"; then
  ufw --force default deny incoming
  ufw --force default allow outgoing
  echo "y" | ufw enable >/dev/null 2>&1 || true
  log "Firewall habilitado: puertos 22/80/443 permitidos."
else
  log "Firewall ya estaba habilitado. Reglas 80/443 aplicadas."
fi

# ----------------------
# Fetch bootstrap and run
# ----------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Descargando bootstrap_core.sh desde el repo (${STACK_BRANCH})..."
curl -fsSL "https://raw.githubusercontent.com/FrontierAI-Academy/install-vps/${STACK_BRANCH}/scripts/bootstrap_core.sh" -o "${TMP_DIR}/bootstrap_core.sh"
chmod +x "${TMP_DIR}/bootstrap_core.sh"

log "Ejecutando bootstrap..."
DOMAIN="$DOMAIN" ADMIN_EMAIL="$ADMIN_EMAIL" MASTER_PASSWORD="$MASTER_PASSWORD" REPO_URL="$REPO_URL" STACK_BRANCH="$STACK_BRANCH" \
  "${TMP_DIR}/bootstrap_core.sh"

log "Instalación lanzada. Revisa los logs del bootstrap para el despliegue de stacks."
