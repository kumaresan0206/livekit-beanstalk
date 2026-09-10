#!/bin/sh
set -e

CONFIG_FILE="/etc/livekit.yaml"
RUNTIME_CONFIG="/tmp/livekit-runtime.yaml"

echo "[Entrypoint] Initializing LiveKit server configuration..."

# Copy base configuration template
cp "$CONFIG_FILE" "$RUNTIME_CONFIG"

# ------------------------------------------------------------------------------
# 1. Fetch Credentials from AWS Secrets Manager (Fail-Closed)
# ------------------------------------------------------------------------------
if [ -n "$SECRET_NAME" ]; then
    echo "[Entrypoint] Fetching secrets from AWS Secrets Manager: $SECRET_NAME..."
    
    if ! command -v aws >/dev/null 2>&1; then
        echo "[Entrypoint] FATAL: AWS CLI is required but not installed."
        exit 1
    fi

    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "${AWS_DEFAULT_REGION:-${AWS_REGION:-ap-southeast-1}}" --query "SecretString" --output text) || {
        echo "[Entrypoint] FATAL: Failed to retrieve secret '$SECRET_NAME' from AWS Secrets Manager."
        exit 1
    }

    if [ -z "$SECRET_JSON" ] || [ "$SECRET_JSON" = "None" ]; then
        echo "[Entrypoint] FATAL: Secret '$SECRET_NAME' is empty or null."
        exit 1
    fi

    API_KEY=$(echo "$SECRET_JSON" | jq -r '.api_key // empty')
    API_SECRET=$(echo "$SECRET_JSON" | jq -r '.api_secret // empty')

    if [ -z "$API_KEY" ] || [ -z "$API_SECRET" ]; then
        echo "[Entrypoint] FATAL: 'api_key' or 'api_secret' key missing in secret JSON payload."
        exit 1
    fi

    LIVEKIT_API_KEY="$API_KEY"
    LIVEKIT_API_SECRET="$API_SECRET"
    echo "[Entrypoint] Successfully loaded and validated credentials from Secrets Manager."
fi

# ------------------------------------------------------------------------------
# 2. Inject API Keys into Runtime Configuration
# ------------------------------------------------------------------------------
if [ -n "$LIVEKIT_API_KEY" ] && [ -n "$LIVEKIT_API_SECRET" ]; then
    echo "[Entrypoint] Registering API Key in LiveKit configuration..."
    cat <<EOF >> "$RUNTIME_CONFIG"

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
EOF
else
    echo "[Entrypoint] FATAL: No API keys configured. LiveKit cannot start without authentication keys."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Launch LiveKit Server (Standalone Mode - No Redis)
# ------------------------------------------------------------------------------
echo "[Entrypoint] Starting LiveKit Server in standalone mode..."
exec /livekit-server --config "$RUNTIME_CONFIG" "$@"
