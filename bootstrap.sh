#!/usr/bin/env bash
set -euo pipefail

# =======================
# Config (override via env)
# =======================
MODEL="${MODEL:-mistralai/Voxtral-Mini-3B-2507}"
PORT="${PORT:-8000}"

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

# --- Pre-clean any bad ngrok APT source so apt update won’t fail ---
if [[ -f /etc/apt/sources.list.d/ngrok.list ]]; then
  sudo rm -f /etc/apt/sources.list.d/ngrok.list
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
uv pip install --upgrade "mistral_common[audio]" soundfile


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
    if command -v snap >/dev/null 2>&1; then
      sudo snap install ngrok
    else
      echo "[!] snapd not found; installing snapd..."
      sudo apt-get install -y snapd
      sudo snap install ngrok
    fi
  fi
fi

# Resolve ngrok binary path (APT or snap)
NGROK_BIN="$(command -v ngrok || true)"
if [[ -z "$NGROK_BIN" && -x /snap/bin/ngrok ]]; then
  NGROK_BIN="/snap/bin/ngrok"
fi
# Optional convenience symlink when using snap
if [[ -x /snap/bin/ngrok && ! -x /usr/local/bin/ngrok ]]; then
  sudo ln -sf /snap/bin/ngrok /usr/local/bin/ngrok || true
fi

# =======================
# .env for services
# =======================
touch "$ENV_FILE"
grep -q '^PORT=' "$ENV_FILE"   || echo "PORT=$PORT" >> "$ENV_FILE"
grep -q '^MODEL=' "$ENV_FILE"  || echo "MODEL=$MODEL" >> "$ENV_FILE"

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
# systemd unit: ngrok (anonymous mode)
# =======================
NGROK_SERVICE_PATH="/etc/systemd/system/ngrok-http@$PORT.service"
sudo bash -c "cat > '$NGROK_SERVICE_PATH'" <<'SERVICE'
[Unit]
Description=ngrok HTTP tunnel on port %i
After=network-online.target vllm.service
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=/home/%u/voxtral/.env
ExecStart=/usr/bin/env ngrok http ${PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE

# Replace %u placeholder with actual user path to .env
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
sudo systemctl enable --now "ngrok-http@$PORT.service"

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

# =======================
# Print ngrok public URL
# =======================
echo "[*] Fetching ngrok public URL..."
bash ~/voxtral/tunnel_url.sh
