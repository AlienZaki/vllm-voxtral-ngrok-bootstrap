#!/usr/bin/env bash
set -euo pipefail

# =======================
# Config (override via env)
# =======================
PORT="${PORT:-8000}"
APP_DIR="${APP_DIR:-$HOME/voxtral}"
VLLM_UNIT="/etc/systemd/system/vllm.service"
NGROK_UNIT_TEMPLATE="/etc/systemd/system/ngrok-http@${PORT}.service"
BASHRC_LINE='export PATH="$HOME/.local/bin:$PATH"'
ASK_CONFIRM="true"
PURGE_NGROK="false"
KEEP_DATA="false"

# =======================
# Parse args
# =======================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASK_CONFIRM="false"; shift ;;
    --purge) PURGE_NGROK="true"; shift ;;
    --keep-data) KEEP_DATA="true"; shift ;;
    -p|--port) PORT="$2"; NGROK_UNIT_TEMPLATE="/etc/systemd/system/ngrok-http@${PORT}.service"; shift 2 ;;
    -h|--help)
      cat <<USAGE
Teardown vLLM + ngrok deployment created by bootstrap.sh

Usage: $(basename "$0") [options]
  -y, --yes           Do not prompt for confirmation (non-interactive)
  --purge             Also remove ngrok (snap or apt) and its APT repo
  --keep-data         Keep $APP_DIR content (env, logs, venv), only remove services
  -p, --port <PORT>   Port used by ngrok unit (default: 8000)
  -h, --help          Show this help
Environment overrides:
  PORT, APP_DIR
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

confirm() {
  if [[ "$ASK_CONFIRM" == "false" ]]; then return 0; fi
  read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

echo "This will teardown services and clean files for:"
echo "  - vLLM unit:     $VLLM_UNIT"
echo "  - ngrok unit:    $NGROK_UNIT_TEMPLATE"
echo "  - app dir:       $APP_DIR (keep: $KEEP_DATA)"
echo "  - purge ngrok:   $PURGE_NGROK"
echo

if ! confirm "Proceed?"; then
  echo "Aborted."
  exit 0
fi

# =======================
# Stop & disable services
# =======================
stop_disable() {
  local unit="$1"
  if systemctl list-unit-files | grep -q "^$(basename "$unit")"; then
    if systemctl is-active --quiet "$(basename "$unit")"; then
      echo "[*] Stopping $(basename "$unit")..."
      sudo systemctl stop "$(basename "$unit")" || true
    fi
    echo "[*] Disabling $(basename "$unit")..."
    sudo systemctl disable "$(basename "$unit")" || true
  fi
}

stop_disable "$VLLM_UNIT"
stop_disable "$NGROK_UNIT_TEMPLATE"

# =======================
# Remove unit files
# =======================
remove_unit() {
  local unit="$1"
  if [[ -f "$unit" ]]; then
    echo "[*] Removing unit $unit"
    sudo rm -f "$unit"
  fi
}
remove_unit "$VLLM_UNIT"
remove_unit "$NGROK_UNIT_TEMPLATE"

echo "[*] Reloading systemd daemon..."
sudo systemctl daemon-reload

# =======================
# Kill leftover processes on the port (best-effort)
# =======================
if command -v lsof >/dev/null 2>&1; then
  if lsof -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[*] Terminating processes listening on :$PORT"
    lsof -iTCP:"$PORT" -sTCP:LISTEN -t | xargs -r kill -9 || true
  fi
fi

# =======================
# Remove app directory
# =======================
if [[ "$KEEP_DATA" == "false" ]]; then
  if [[ -d "$APP_DIR" ]]; then
    echo "[*] Removing $APP_DIR ..."
    rm -rf "$APP_DIR"
  fi
else
  echo "[i] Keeping $APP_DIR as requested."
fi

# =======================
# Clean PATH line from .bashrc (exact match only)
# =======================
if [[ -f "$HOME/.bashrc" ]]; then
  if grep -qxF "$BASHRC_LINE" "$HOME/.bashrc"; then
    echo "[*] Removing PATH line from ~/.bashrc"
    # Use sed -i safely by creating a backup
    cp "$HOME/.bashrc" "$HOME/.bashrc.bak.teardown.$(date +%s)"
    sed -i "\|^$BASHRC_LINE$|d" "$HOME/.bashrc"
  fi
fi

# =======================
# Remove symlink if we created it
# =======================
if [[ -L /usr/local/bin/ngrok ]]; then
  # Only remove if it points to /snap/bin/ngrok (what bootstrap created)
  if [[ "$(readlink -f /usr/local/bin/ngrok)" == "/snap/bin/ngrok" ]]; then
    echo "[*] Removing /usr/local/bin/ngrok symlink"
    sudo rm -f /usr/local/bin/ngrok
  fi
fi

# =======================
# Optional: purge ngrok
# =======================
if [[ "$PURGE_NGROK" == "true" ]]; then
  echo "[*] Purging ngrok..."

  # Stop any lingering snap service
  if command -v snap >/dev/null 2>&1; then
    if snap list 2>/dev/null | grep -q "^ngrok "; then
      sudo snap remove ngrok || true
    fi
  fi

  # Remove APT package if installed
  if dpkg -l | grep -q "^ii  ngrok "; then
    sudo apt-get remove -y ngrok || true
  fi

  # Remove ngrok APT repo & key (added by bootstrap)
  if [[ -f /etc/apt/sources.list.d/ngrok.list ]]; then
    echo "[*] Removing /etc/apt/sources.list.d/ngrok.list"
    sudo rm -f /etc/apt/sources.list.d/ngrok.list
    sudo apt-get update -y || true
  fi
  if [[ -f /etc/apt/trusted.gpg.d/ngrok.asc ]]; then
    echo "[*] Removing /etc/apt/trusted.gpg.d/ngrok.asc"
    sudo rm -f /etc/apt/trusted.gpg.d/ngrok.asc
  fi

  # Remove user ngrok config (optional & safe)
  if [[ -d "$HOME/.config/ngrok" ]]; then
    echo "[*] Removing $HOME/.config/ngrok"
    rm -rf "$HOME/.config/ngrok"
  fi
fi

echo
echo "✅ Teardown complete."
echo "Tips:"
echo "  - If you kept data, you can re-enable with: sudo systemctl enable --now vllm ngrok-http@${PORT}"
echo "  - If shell PATH changed, reopen your SSH session to refresh environment."
