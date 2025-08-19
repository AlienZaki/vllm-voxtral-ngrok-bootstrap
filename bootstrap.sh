#!/usr/bin/env bash
set -euo pipefail

# -------- Config you may customize --------
MODEL="mistralai/Voxtral-Mini-3B-2507"
PORT="8000"
# Provide NGROK_TOKEN via env or prompt
NGROK_TOKEN="${NGROK_TOKEN:-}"

# -------- Detect current user & OS --------
ME="$(id -un)"
HOME_DIR="$(eval echo ~"$ME")"

if [[ "$ME" == "root" ]]; then
  echo "Please run as a normal user (not root)."
  exit 1
fi

# Ensure we have sudo
if ! command -v sudo >/dev/null 2>&1; then
  echo "Installing sudo..."
  apt-get update -y && apt-get install -y sudo
fi

# -------- Base packages --------
echo "[*] Installing base packages..."
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg python3 python3-venv python3-pip jq

# -------- Ensure ~/.local/bin on PATH for this user --------
mkdir -p "$HOME_DIR/.local/bin"
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
fi
export PATH="$HOME_DIR/.local/bin:$PATH"

# -------- Install uv for this user --------
if ! command -v uv >/dev/null 2>&1; then
  echo "[*] Installing uv..."
  python3 -m pip install --user --upgrade uv
fi

# -------- App directory & venv --------
APP_DIR="$HOME_DIR/voxtral"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

if [[ ! -d ".venv" ]]; then
  echo "[*] Creating virtualenv with uv..."
  uv venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

# -------- Python deps --------
echo "[*] Installing Python deps..."
uv pip install --upgrade "vllm[audio]"
python -c "import mistral_common; print('mistral_common version:', getattr(mistral_common, '__version__', 'unknown'))"
uv pip install --upgrade "mistral_common[audio]"

python - <<'PY'
from mistral_common.protocol.instruct.messages import TextChunk, AudioChunk, UserMessage, AssistantMessage
from mistral_common.audio import Audio
print("All imports successful")
PY

# -------- Fix ~/.config ownership (occasionally needed) --------
sudo chown -R "$ME:$ME" "$HOME_DIR/.config" || true

# -------- Install ngrok (repo-based, handles Ubuntu nicely) --------
if ! command -v ngrok >/dev/null 2>&1; then
  echo "[*] Installing ngrok..."
  # Add ngrok repo
  curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
  source /etc/os-release
  # Use VERSION_CODENAME when present, otherwise fall back to 'stable'
  CODENAME="${VERSION_CODENAME:-stable}"
  echo "deb https://ngrok-agent.s3.amazonaws.com ${CODENAME} main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null || true
  sudo apt-get update -y || true
  sudo apt-get install -y ngrok || {
    echo "[!] Fallback: installing ngrok via snap..."
    sudo snap install ngrok
  }
fi

# -------- Write a .env file for the service user --------
ENV_FILE="$APP_DIR/.env"
touch "$ENV_FILE"
grep -q '^PORT=' "$ENV_FILE" || echo "PORT=$PORT" >> "$ENV_FILE"
grep -q '^MODEL=' "$ENV_FILE" || echo "MODEL=$MODEL" >> "$ENV_FILE"

# ngrok token
if [[ -z "$NGROK_TOKEN" ]]; then
  read -rp "Enter your NGROK_AUTHTOKEN: " NGROK_TOKEN
fi
grep -q '^NGROK_AUTHTOKEN=' "$ENV_FILE" && sed -i "s|^NGROK_AUTHTOKEN=.*|NGROK_AUTHTOKEN=$NGROK_TOKEN|" "$ENV_FILE" || echo "NGROK_AUTHTOKEN=$NGROK_TOKEN" >> "$ENV_FILE"

# -------- systemd units --------
# vLLM service (runs in your venv)
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

# ngrok service for http $PORT
NGROK_SERVICE_PATH="/etc/systemd/system/ngrok-http@$PORT.service"
sudo bash -c "cat > '$NGROK_SERVICE_PATH'" <<SERVICE
[Unit]
Description=ngrok HTTP tunnel on port %i
After=network-online.target vllm.service
Wants=network-online.target

[Service]
Type=simple
User=$ME
EnvironmentFile=$APP_DIR/.env
ExecStartPre=/usr/bin/ngrok config add-authtoken \${NGROK_AUTHTOKEN}
ExecStart=/usr/bin/ngrok http \${PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE

# Helper script to fetch public URL
URL_SCRIPT="$APP_DIR/tunnel_url.sh"
cat > "$URL_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Wait until ngrok API appears (default: http://127.0.0.1:4040)
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[] | select(.proto=="https") | .public_url' | head -n1
SH
chmod +x "$URL_SCRIPT"

# -------- Start & enable services --------
echo "[*] Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable --now vllm.service
sudo systemctl enable --now "ngrok-http@$PORT.service"

echo
echo "✅ All set."
echo "vLLM status:    sudo systemctl status vllm"
echo "ngrok status:   sudo systemctl status ngrok-http@$PORT"
echo "Public URL:     $URL_SCRIPT"
echo
echo "Quick test once URL shows up:"
echo '  curl -X POST "$(./tunnel_url.sh)/v1/chat/completions" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '\''{"model":"mistralai/Voxtral-Mini-3B-2507","messages":[{"role":"user","content":"Hello!"}]}'\'
