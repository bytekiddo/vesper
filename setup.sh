#!/usr/bin/env bash
# Vesper — one-shot, idempotent setup for Ubuntu 24.04. Re-run freely.
# Installs Godot 4.7.2 (headless binary + web export templates), Python, nginx (COOP/COEP), git deploy key,
# UFW, systemd units (world server with auto-restart, overseer timer, nightly backup), log rotation. Writes .env.
set -euo pipefail

GODOT_VERSION="4.7.2"
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_ZIP="Godot_v${GODOT_TAG}_linux.x86_64.zip"
GODOT_TPZ="Godot_v${GODOT_TAG}_export_templates.tpz"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}"
INSTALL_DIR="/opt/vesper"
SVC_USER="vesper"
REPO_URL="${REPO_URL:-https://github.com/bytekiddo/vesper.git}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
need_root() { if [ "$(id -u)" -ne 0 ]; then echo "run as root: sudo ./setup.sh" >&2; exit 1; fi; }
need_root

if ! grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
  echo "warning: this script is written for Ubuntu 24.04; continuing anyway" >&2
fi

say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends python3 nginx ufw git unzip curl ca-certificates logrotate make >/dev/null

say "service user + directories"
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "/home/$SVC_USER" --shell /usr/sbin/nologin "$SVC_USER"
mkdir -p /var/log/vesper /var/backups/vesper
chown -R "$SVC_USER:$SVC_USER" /var/log/vesper /var/backups/vesper

say "repository at $INSTALL_DIR"
if [ ! -d "$INSTALL_DIR/.git" ]; then
  if [ -d "$(pwd)/.git" ] && [ "$(pwd)" != "$INSTALL_DIR" ]; then
    git clone "$(pwd)" "$INSTALL_DIR"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  else
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
fi
chown -R "$SVC_USER:$SVC_USER" "$INSTALL_DIR"
git config --system --add safe.directory "$INSTALL_DIR" || true

say "Godot $GODOT_TAG"
if ! /usr/local/bin/godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}"; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/godot.zip" "$GODOT_URL/$GODOT_ZIP"
  unzip -q -o "$tmp/godot.zip" -d "$tmp"
  install -m 755 "$tmp/Godot_v${GODOT_TAG}_linux.x86_64" /usr/local/bin/godot
  rm -rf "$tmp"
fi
/usr/local/bin/godot --version
TPL_DIR="/home/$SVC_USER/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
if [ ! -f "$TPL_DIR/web_nothreads_release.zip" ]; then
  say "web export templates (large download, once)"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/templates.tpz" "$GODOT_URL/$GODOT_TPZ"
  mkdir -p "$TPL_DIR"
  unzip -q -o "$tmp/templates.tpz" 'templates/web_*' -d "$tmp"
  cp "$tmp"/templates/web_* "$TPL_DIR/"
  rm -rf "$tmp"
  chown -R "$SVC_USER:$SVC_USER" "/home/$SVC_USER/.local"
fi

say ".env"
ENV_FILE="$INSTALL_DIR/.env"
current() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ask() { local var="$1" prompt="$2" default="$3" secret="${4:-}"; local cur; cur="$(current "$var")"; [ -n "$cur" ] && default="$cur"
  if [ -n "$secret" ] && [ -n "$cur" ]; then read -r -p "$prompt [keep current]: " val; else read -r -p "$prompt [$default]: " val; fi
  echo "${val:-$default}"; }
if [ -t 0 ]; then
  KEY=$(ask OPENROUTER_API_KEY "OpenRouter API key" "" secret)
  BUDGET=$(ask BUDGET_USD_PER_MONTH "Monthly budget in USD (50-100)" "75")
  DOMAIN=$(ask VESPER_DOMAIN "Domain or public IP for the viewer" "$(curl -fsS -4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')")
else
  KEY="$(current OPENROUTER_API_KEY)"; BUDGET="${BUDGET_USD_PER_MONTH:-$(current BUDGET_USD_PER_MONTH)}"; DOMAIN="${VESPER_DOMAIN:-$(current VESPER_DOMAIN)}"
fi
umask 077
cat > "$ENV_FILE" <<ENV
OPENROUTER_API_KEY=${KEY}
BUDGET_USD_PER_MONTH=${BUDGET:-75}
VESPER_DOMAIN=${DOMAIN}
VESPER_WS_PORT=9001
ENV
umask 022
chown "$SVC_USER:$SVC_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"

say "git deploy key (for checkpoint commits)"
SSH_DIR="/home/$SVC_USER/.ssh"
if [ ! -f "$SSH_DIR/id_ed25519" ]; then
  sudo -u "$SVC_USER" mkdir -p "$SSH_DIR"
  sudo -u "$SVC_USER" ssh-keygen -q -t ed25519 -N "" -C "vesper-deploy@$(hostname)" -f "$SSH_DIR/id_ed25519"
fi
sudo -u "$SVC_USER" bash -c "ssh-keyscan -t ed25519 github.com 2>/dev/null >> $SSH_DIR/known_hosts; sort -u -o $SSH_DIR/known_hosts $SSH_DIR/known_hosts"
sudo -u "$SVC_USER" git -C "$INSTALL_DIR" config user.name "vesper-overseers"
sudo -u "$SVC_USER" git -C "$INSTALL_DIR" config user.email "overseers@vesper.local"
if [[ "$REPO_URL" == https://github.com/* ]]; then
  sudo -u "$SVC_USER" git -C "$INSTALL_DIR" remote set-url --push origin "git@github.com:${REPO_URL#https://github.com/}"
fi
echo "Add this deploy key (with write access) to the GitHub repo:"; echo; cat "$SSH_DIR/id_ed25519.pub"; echo

say "kernel manifest + last-known-good tag"
sudo -u "$SVC_USER" bash -c "cd $INSTALL_DIR && sha256sum -c --quiet kernel/KERNEL.sha256" || { echo "kernel manifest does not match the checkout; refusing" >&2; exit 4; }
sudo -u "$SVC_USER" git -C "$INSTALL_DIR" tag -f last-known-good >/dev/null

say "web viewer export"
sudo -u "$SVC_USER" bash -c "cd $INSTALL_DIR && HOME=/home/$SVC_USER make -s import >/dev/null 2>&1 || true; HOME=/home/$SVC_USER make -s export-web"

say "nginx"
sed "s/__DOMAIN__/${DOMAIN:-_}/" "$INSTALL_DIR/ops/nginx.conf" > /etc/nginx/sites-available/vesper
ln -sf /etc/nginx/sites-available/vesper /etc/nginx/sites-enabled/vesper
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx && systemctl enable nginx >/dev/null

say "firewall"
ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null; ufw status | head -5

say "systemd"
for u in vesper.service vesper-overseer.service vesper-overseer.timer vesper-backup.service vesper-backup.timer; do
  install -m 644 "$INSTALL_DIR/ops/$u" "/etc/systemd/system/$u"
done
install -m 644 "$INSTALL_DIR/ops/logrotate" /etc/logrotate.d/vesper
systemctl daemon-reload
systemctl enable --now vesper.service vesper-overseer.timer vesper-backup.timer >/dev/null
systemctl restart vesper.service
sleep 3; systemctl --no-pager --lines=5 status vesper.service || true

say "done"
echo "Viewer:    http://${DOMAIN}/"
echo "Journal:   http://${DOMAIN}/journal/"
echo "Logs:      /var/log/vesper/server.log  /var/log/vesper/overseer.log"
echo "Overseers: systemctl list-timers vesper-overseer.timer   (run one now: sudo systemctl start vesper-overseer.service)"
echo "TLS:       optional — apt install certbot python3-certbot-nginx && certbot --nginx -d ${DOMAIN}"
