#!/usr/bin/env bash
set -euo pipefail

# =======================
# Config (override via env)
# =======================
MODEL="${MODEL:-mistralai/Voxtral-Mini-3B-2507}"
PORT="${PORT:-8000}"
NGROK_TOKEN="${NGROK_TOKEN:-}"

# =======================
# Detect user / env
# =======================
ME="$(id -un)"
HOME_DIR="$(eval echo ~"$ME")"
APP_DIR="$HOME_DIR/voxtral"
ENV_FILE="$APP_DIR/.env"

if [[ "$ME" == "root" ]]; then
  echo "Please run this script as a normal user (not root)."
  exit 1
fi

# Ensure sudo available
if ! command -v sudo >/dev/null 2>&1; then
  echo "[*] Installing sudo..."
  apt-get update -y && apt-get install -y sudo
fi

echo "[*] Installing base packages..."
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg python3 python3-venv python3-pip jq

# Ensure ~/.local/bin is on PATH
mkdir -p "$HOME_DIR/.local/bin"
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
fi
export PATH="$HOME_DIR/.local/bin:$PATH"

# =======================
# Install uv (per-user)
# =======================
if ! command -v uv >/dev/null 2>&1; then
  echo "[*] Installing uv..."
  python3 -m pip install --user --upgrade uv
fi

# =======================
# Create app dir & venv
# =======================
mkdir -p "$APP_DIR"
cd "$APP_DIR"

if [[ ! -d ".venv" ]]; then
  echo "[*] Creating virtualenv with uv..."
  uv venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

# =======================
# Python deps
# =======================
echo "[*] Installing Python deps..."
uv pip install --upgrade "vllm[audio]"
python -c "import mistral_common; print('mistral_common version:', getattr(mistral_common, '__version__', 'unknown'))"
uv pip install --upgrade "mistral_common[audio]"

python - <<'PY'
from mistral_common.protocol.instruct.messages import TextChunk, AudioChunk, UserMessage, AssistantMessage
from mistral_common.audio import Audio
print("All imports successful")
PY

# Sometimes ~/.config ends up root-owned (fix quietly)
sudo chown -R "$ME:$ME" "$HOME_DIR/.config" || true

# =======================
# Install ngrok (APT stable → snap fallback)
# =======================
echo "[*] Installing ngrok..."
if ! command -v ngrok >/dev/null 2>&1; then
  set +e
  curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
  echo "deb https://ngrok-agent.s3.amazonaws.com stable main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y ngrok
  APT_RC=$?
  set -e
  if [[ $APT_RC -ne 0 ]]; then
    echo "[!] APT install failed, falling back to snap..."
    sudo snap install ngrok
  fi
fi

# If ngrok came from snap, make sure /snap/bin is reachable by services
NGROK_BIN="$(command -v ngrok || true)"
if [[ -z "$NGROK_BIN" ]] && [[ -x /snap/bin/ngrok ]]; then
  NGROK_BIN="/snap/bin/ngrok"
fi

# Optionally symlink for convenience (doesn't hurt if APT was used)
if [[ -x /snap/bin/ngrok && ! -x /usr/local/bin/ngrok ]]; then
  sudo ln -sf /snap/bin/ngrok /usr/local/bin/ngrok || true
fi

# =======================
# .env for services
# =======================
touch "$ENV_FILE"
grep -q '^PORT=' "$ENV_FILE"   || echo "PORT=$PORT" >> "$ENV_FILE"
grep -q '^MODEL=' "$ENV_FILE"  || echo "MODEL=$MODEL" >> "$ENV_FILE"

if [[ -z "$NGROK_TOKEN" ]]; then
  read -rp "Enter your NGROK_AUTHTOKEN: " NGROK_TOKEN
fi
if grep -q '^NGROK_AUTHTOKEN=' "$ENV_FILE"; then
  sed -i "s|^NGROK_AUTHTOKEN=.*|NGROK_AUTHTOKEN=$NGROK_TOKEN|" "$ENV_FILE"
else
  echo "NGROK_AUTHTOKEN=$NGROK_TOKEN" >> "$ENV_FILE"
fi

# Also write a local ngrok config in the user profile (idempotent)
"$NGROK_BIN" config add-authtoken "$NGROK_TOKEN" || ngrok config add-authtoken "$NGROK_TOKEN" || true

# =======================
# systemd unit: vLLM
# =======================
VLLM_SERVICE_PATH="/etc/systemd/system/vllm.service"
VLLM_CMD="$APP_DIR/.venv/bin/vllm serve $MODEL --port $PORT --tokenizer_mode mistral --config_format mistral --load_format mistral"

sudo bash -c "cat > '$VLLM_SERVICE_PATH'" <<SERVICE
[Unit]
Description=vLLM OpenAI-compatible server
After=network.target

[Service]
Type=simple
User=$ME
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$VLLM_CMD
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

# =======================
# systemd unit: ngrok (path-agnostic, snap-friendly)
# =======================
NGROK_SERVICE_PATH="/etc/systemd/system/ngrok-http@$PORT.service"
sudo bash -c "cat > '$NGROK_SERVICE_PATH'" <<'SERVICE'
[Unit]
Description=ngrok HTTP tunnel on port %i
After=network-online.target vllm.service
Wants=network-online.target

[Service]
Type=simple
# Ensure snap binaries and common paths are visible to systemd service
Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Load PORT and NGROK_AUTHTOKEN from app .env
EnvironmentFile=/home/%u/voxtral/.env
# Use /usr/bin/env to resolve ngrok (APT or snap) at runtime
ExecStartPre=/usr/bin/env ngrok config add-authtoken ${NGROK_AUTHTOKEN}
ExecStart=/usr/bin/env ngrok http ${PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE

# We need to replace %u in EnvironmentFile path with actual user, since we used a literal file above.
# (Some systems support %u, but we ensure correctness by rewriting here.)
sudo sed -i "s|/home/%u/voxtral/.env|$APP_DIR/.env|" "$NGROK_SERVICE_PATH"

# =======================
# Helper: print tunnel URL
# =======================
URL_SCRIPT="$APP_DIR/tunnel_url.sh"
cat > "$URL_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Wait up to ~30s for ngrok API
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[] | select(.proto=="https") | .public_url' | head -n1
SH
chmod +x "$URL_SCRIPT"

# =======================
# Enable & start services
# =======================
echo "[*] Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable --now vllm.service
sudo systemctl enable --now "ngrok-http@$PORT.service" || {
  echo "[!] ngrok service failed to start, attempting a manual token setup + restart..."
  /usr/bin/env ngrok config add-authtoken "$NGROK_TOKEN" || true
  sudo systemctl restart "ngrok-http@$PORT.service"
}

echo
echo "✅ All set."
echo "vLLM status:     sudo systemctl status vllm --no-pager"
echo "ngrok status:    sudo systemctl status ngrok-http@$PORT --no-pager"
echo "Public URL:      $URL_SCRIPT"
echo
echo "Quick test after URL appears:"
echo '  curl -X POST "$(./tunnel_url.sh)/v1/chat/completions" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '\''{"model":"mistralai/Voxtral-Mini-3B-2507","messages":[{"role":"user","content":"Hello!"}]}'\'
