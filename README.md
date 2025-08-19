# vllm-voxtral-ngrok-bootstrap

Bootstrap a local vLLM server for the Voxtral Mini model and expose it securely to the internet via ngrok, all with one script: [bootstrap.sh](bootstrap.sh).

## What this does
- Installs base packages and uv.
- Creates a virtualenv at ~/voxtral and installs vllm[audio] and mistral_common[audio].
- Creates systemd services: vllm.service and ngrok-http@PORT.
- Writes ~/voxtral/.env (PORT, MODEL, NGROK_AUTHTOKEN).
- Adds ~/voxtral/tunnel_url.sh to print the public HTTPS URL.

## Requirements
- Ubuntu 24.04 (VS Code dev container OK).
- Non-root user with sudo privileges.
- ngrok auth token.

## Clone the Repository
To get started, clone this repository:

```sh
git clone https://github.com/AlienZaki/vllm-voxtral-ngrok-bootstrap.git
cd vllm-voxtral-ngrok-bootstrap
```

## Quick start
```sh
bash bootstrap.sh
```

## Usage

### Bootstrap the Environment
Run the `bootstrap.sh` script to set up the environment, install dependencies, and configure services.

```sh
bash bootstrap.sh
```

### Teardown the Environment
Run the `teardown.sh` script to clean up the setup, stop services, and optionally remove all related files.

```sh
bash teardown.sh
# Basic teardown
bash teardown.sh

# Teardown without confirmation
bash teardown.sh --yes

# Keep application data
bash teardown.sh --keep-data

# Purge ngrok installation
bash teardown.sh --purge
```

### Get the Public URL
Retrieve the public HTTPS URL for the vLLM server:

```sh
~/voxtral/tunnel_url.sh
# Or open in your host browser
$BROWSER "$(~/voxtral/tunnel_url.sh)"
```

### Test the API
Send a test request to the vLLM server:

```sh
curl -X POST "$(~/voxtral/tunnel_url.sh)/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Voxtral-Mini-3B-2507","messages":[{"role":"user","content":"Hello!"}]}'
```

## Manage services
```sh
# Status
sudo systemctl status vllm
sudo systemctl status ngrok-http@8000

# Logs (follow)
sudo journalctl -u vllm -f
sudo journalctl -u ngrok-http@8000 -f

# Stop/disable
sudo systemctl disable --now vllm
sudo systemctl disable --now ngrok-http@8000
```

## Customize
- Edit PORT and MODEL at the top of [bootstrap.sh](bootstrap.sh) before running, or update ~/voxtral/.env after.
- Defaults: MODEL=mistralai/Voxtral-Mini-3B-2507, PORT=8000.