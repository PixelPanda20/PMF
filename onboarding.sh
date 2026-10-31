#!/usr/bin/env bash
# KOBY device onboarding for the on-prem Plaud Note Pro pipeline.
#
# Performs an OAuth 2.0 device authorization flow against the KOBY identity
# provider, validates the token against the BIT AI gateway and writes a
# 0600 environment file that the on-prem application can consume.
#
# The script never prints the token. It supports token refresh, a health
# check and an optional OpenAI-compatible audio transcription call.
set -euo pipefail
umask 077

readonly VERSION="1.0.0"
readonly REALM_ID="fbcfa3d6-6fad-43fb-9d37-0c76a28495f6"
readonly AUTH_BASE="https://r.auth.koby.admin.ch/realms/${REALM_ID}/protocol/openid-connect"
readonly DEVICE_ENDPOINT="${AUTH_BASE}/auth/device"
readonly TOKEN_ENDPOINT="${AUTH_BASE}/token"
readonly DEFAULT_GATEWAY="https://r.models.koby.admin.ch/ai-model"

CLIENT_ID="${KOBY_CLIENT_ID:-bit-ai-developer}"
AUDIENCE="${KOBY_AUDIENCE:-bit-ai-gateway}"
SCOPE="${KOBY_SCOPE:-openid profile email}"
GATEWAY="${KOBY_GATEWAY:-$DEFAULT_GATEWAY}"
MODEL="${KOBY_MODEL:-koby-medium}"
API_BASE="${KOBY_API_BASE:-}"
DEVICE_NAME="${KOBY_DEVICE_NAME:-Plaud Note Pro}"
DEVICE_ID="${KOBY_DEVICE_ID:-}"
OUTPUT="${KOBY_CONFIG_FILE:-}"
TRANSCRIBE_URL="${KOBY_TRANSCRIBE_URL:-}"
TRANSCRIBE_MODEL="${KOBY_TRANSCRIBE_MODEL:-}"

ACTION="onboard"
OPEN_BROWSER=1
FORCE=0
AUDIO_FILE=""
TIMEOUT=""

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
KOBY device onboarding ${VERSION}

Usage:
  $(basename "$0") --device-id <id> [options]
  $(basename "$0") --config <file> --check
  $(basename "$0") --config <file> --refresh
  $(basename "$0") --config <file> --transcribe <audio-file>

Onboarding options:
  --device <name>          Device name (default: "Plaud Note Pro")
  --device-id <id>         Serial number or asset id (used for the filename)
  --output <file>          Config file (default: /etc/koby-plaud/<slug>.env
                           for root, otherwise ~/.config/koby-plaud/<slug>.env)
  --model <id>             KOBY model (default: koby-medium)
  --api-base <url>         OpenAI-compatible base URL of the model
                           (default: <gateway>/<model>/v1)
  --gateway <url>          Gateway root (default: ${DEFAULT_GATEWAY})
  --client-id <id>         OAuth client id (default: bit-ai-developer)
  --audience <value>       OAuth audience (default: bit-ai-gateway)
  --transcribe-url <url>   OpenAI-compatible /audio/transcriptions endpoint
  --transcribe-model <id>  Speech-to-text model id
  --set-transcription <url> <model>
                           Update transcription settings in an existing config
  --no-browser             Do not open the sign-in URL automatically
  --timeout <seconds>      Override the device-code lifetime
  --force                  Overwrite an existing config file

Operations on an existing config:
  --config <file>          Config file to use
  --check                  Validate the token against the gateway
  --refresh                Renew the token with the refresh token
  --transcribe <file>      Upload an audio file to the transcription endpoint
  --set-transcription <url> <model>
                           Update transcription settings without re-authenticating
  --probe-transcription    Check whether the transcription endpoint responds

  -h, --help               Show this help
  -V, --version            Show the version

Environment:
  KOBY_CLIENT_ID, KOBY_AUDIENCE, KOBY_GATEWAY, KOBY_MODEL, KOBY_API_BASE,
  KOBY_DEVICE_NAME, KOBY_DEVICE_ID, KOBY_CONFIG_FILE,
  KOBY_TRANSCRIBE_URL, KOBY_TRANSCRIBE_MODEL

Notes:
  * The token is a user/service-account token, not a hardware credential.
    Use one config file per device for traceability.
  * The current BIT AI catalogue documents chat and embedding models only.
    Set --transcribe-url/--transcribe-model once the speech-to-text route
    and model have been confirmed by BIT AI (REF registration).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_NAME="${2:?missing value}"; shift 2 ;;
    --device-id) DEVICE_ID="${2:?missing value}"; shift 2 ;;
    --output|--config) OUTPUT="${2:?missing value}"; shift 2 ;;
    --model) MODEL="${2:?missing value}"; shift 2 ;;
    --api-base) API_BASE="${2:?missing value}"; shift 2 ;;
    --gateway) GATEWAY="${2:?missing value}"; shift 2 ;;
    --client-id) CLIENT_ID="${2:?missing value}"; shift 2 ;;
    --audience) AUDIENCE="${2:?missing value}"; shift 2 ;;
    --transcribe-url) TRANSCRIBE_URL="${2:?missing value}"; shift 2 ;;
    --transcribe-model) TRANSCRIBE_MODEL="${2:?missing value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?missing value}"; shift 2 ;;
    --no-browser) OPEN_BROWSER=0; shift ;;
    --force) FORCE=1; shift ;;
    --check) ACTION="check"; shift ;;
    --refresh) ACTION="refresh"; shift ;;
    --probe-transcription) ACTION="probe"; shift ;;
    --transcribe) ACTION="transcribe"; AUDIO_FILE="${2:?missing value}"; shift 2 ;;
    --set-transcription)
      ACTION="set-stt"
      TRANSCRIBE_URL="${2:?missing url}"
      TRANSCRIBE_MODEL="${3:?missing model}"
      shift 3
      ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) printf '%s %s\n' "$(basename "$0")" "$VERSION"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

if [[ -z "$API_BASE" ]]; then
  API_BASE="${GATEWAY}/${MODEL}/v1"
fi

if [[ -z "$OUTPUT" ]]; then
  slug="$(slugify "${DEVICE_ID:-$DEVICE_NAME}")"
  [[ -n "$slug" ]] || slug="device"
  if [[ "${EUID}" -eq 0 ]]; then
    OUTPUT="/etc/koby-plaud/${slug}.env"
  else
    OUTPUT="${XDG_CONFIG_HOME:-$HOME/.config}/koby-plaud/${slug}.env"
  fi
fi

escape_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

load_config() {
  [[ -f "$OUTPUT" ]] || die "config not found: $OUTPUT"
  # shellcheck disable=SC1090
  set -a
  . "$OUTPUT"
  set +a
}

write_config() {
  local dir tmp token refresh issued expires
  token="${ACCESS_TOKEN:-${KOBY_TOKEN:-}}"
  refresh="${REFRESH_TOKEN:-${KOBY_REFRESH_TOKEN:-}}"
  issued="${ISSUED_AT:-${KOBY_TOKEN_ISSUED_AT:-}}"
  expires="${EXPIRES_AT:-${KOBY_TOKEN_EXPIRES_AT:-}}"
  [[ -n "$token" ]] || die "no token available for ${OUTPUT}"
  dir="$(dirname "$OUTPUT")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
  fi
  tmp="$(mktemp "${dir}/.koby-device.XXXXXX")"
  {
    printf '# KOBY device onboarding – generated by %s %s\n' "$(basename "$0")" "$VERSION"
    printf '# Do not commit. Mode 0600.\n'
    printf 'KOBY_DEVICE_NAME="%s"\n' "$(escape_value "${DEVICE_NAME:-}")"
    printf 'KOBY_DEVICE_ID="%s"\n' "$(escape_value "${DEVICE_ID:-}")"
    printf 'KOBY_GATEWAY="%s"\n' "$(escape_value "$GATEWAY")"
    printf 'KOBY_API_BASE="%s"\n' "$(escape_value "$API_BASE")"
    printf 'KOBY_MODEL="%s"\n' "$(escape_value "$MODEL")"
    printf 'KOBY_CLIENT_ID="%s"\n' "$(escape_value "$CLIENT_ID")"
    printf 'KOBY_AUDIENCE="%s"\n' "$(escape_value "$AUDIENCE")"
    printf 'KOBY_TOKEN="%s"\n' "$(escape_value "$token")"
    printf 'KOBY_REFRESH_TOKEN="%s"\n' "$(escape_value "$refresh")"
    printf 'KOBY_TOKEN_ISSUED_AT="%s"\n' "$issued"
    printf 'KOBY_TOKEN_EXPIRES_AT="%s"\n' "$expires"
    printf 'KOBY_TRANSCRIBE_URL="%s"\n' "$(escape_value "${TRANSCRIBE_URL:-}")"
    printf 'KOBY_TRANSCRIBE_MODEL="%s"\n' "$(escape_value "${TRANSCRIBE_MODEL:-}")"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$OUTPUT"
  chmod 600 "$OUTPUT"
}

iso_expiry() {
  local seconds="$1"
  date -u -d "+${seconds} seconds" +"%Y-%m-%dT%H:%M:%SZ"
}

validate_token() {
  local token="$1" code body
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${API_BASE}/models" || true)"
  if [[ "$code" == "200" ]]; then
    rm -f "$body"
    return 0
  fi
  warn "gateway check returned HTTP ${code} for ${API_BASE}/models"
  if [[ -s "$body" ]]; then
    head -c 400 "$body" >&2 || true
    printf '\n' >&2
  fi
  rm -f "$body"
  return 1
}

open_url() {
  local url="$1"
  [[ "$OPEN_BROWSER" -eq 1 ]] || return 0
  if command -v xdg-open >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

onboard() {
  [[ -f "$OUTPUT" && "$FORCE" -ne 1 ]] && \
    die "config already exists: $OUTPUT (use --force to replace)"

  info "Requesting device code for ${DEVICE_NAME} (client ${CLIENT_ID}) …"
  local response device_code user_code verification_url expires_in interval
  response="$(curl -sS -f -X POST "$DEVICE_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "scope=${SCOPE}" \
    --data-urlencode "audience=${AUDIENCE}")" || die "device endpoint unreachable"

  device_code="$(jq -r '.device_code // empty' <<<"$response")"
  user_code="$(jq -r '.user_code // empty' <<<"$response")"
  verification_url="$(jq -r '.verification_uri_complete // .verification_uri // empty' <<<"$response")"
  expires_in="$(jq -r '.expires_in // 600' <<<"$response")"
  interval="$(jq -r '.interval // 5' <<<"$response")"
  [[ -n "$device_code" && -n "$user_code" && -n "$verification_url" ]] || \
    die "incomplete device authorization response"
  [[ -n "$TIMEOUT" ]] && expires_in="$TIMEOUT"

  printf '\n  Open this URL and sign in with your U80XXXXXX/X80XXXXXX account:\n\n'
  printf '  %s\n\n' "$verification_url"
  printf '  User code : %s\n' "$user_code"
  printf '  Valid for : %s seconds\n\n' "$expires_in"
  open_url "$verification_url"
  info "Waiting for browser approval …"

  local deadline=$((SECONDS + expires_in)) token_response error access refresh
  while (( SECONDS < deadline )); do
    sleep "$interval"
    (( SECONDS < deadline )) || break
    token_response="$(curl -sS -X POST "$TOKEN_ENDPOINT" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "device_code=${device_code}")"
    error="$(jq -r '.error // empty' <<<"$token_response")"
    case "$error" in
      "")
        access="$(jq -r '.access_token // empty' <<<"$token_response")"
        refresh="$(jq -r '.refresh_token // empty' <<<"$token_response")"
        [[ -n "$access" ]] || die "token response missing access_token"
        ACCESS_TOKEN="$access"
        REFRESH_TOKEN="$refresh"
        ISSUED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        EXPIRES_AT="$(iso_expiry "$(jq -r '.expires_in // 2592000' <<<"$token_response")")"
        validate_token "$access" || warn "token stored, but gateway check failed"
        write_config
        printf '\n'
        info "Onboarding complete."
        info "  Device  : ${DEVICE_NAME}${DEVICE_ID:+ (${DEVICE_ID})}"
        info "  Config  : ${OUTPUT} (mode 600)"
        info "  Model   : ${MODEL}"
        info "  API base: ${API_BASE}"
        info "  Valid   : until ${EXPIRES_AT}"
        [[ -n "${TRANSCRIBE_URL:-}" ]] && info "  STT     : ${TRANSCRIBE_URL} (${TRANSCRIBE_MODEL:-model not set})"
        printf '\n'
        info "Use it (systemd): EnvironmentFile=${OUTPUT}"
        info "Chat example:"
        printf '  curl -sS %s/chat/completions \\\n    -H "Authorization: Bearer $KOBY_TOKEN" \\\n    -H "Content-Type: application/json" \\\n    -d '\''{"model":"%s","messages":[{"role":"user","content":"Hallo"}]}'\''\n' \
          "$API_BASE" "$MODEL" >&2
        return 0
        ;;
      "authorization_pending") printf '.' >&2 ;;
      "slow_down") interval=$((interval + 5)); printf '.' >&2 ;;
      "access_denied") die "sign-in was denied" ;;
      "expired_token") die "device code expired – run the script again" ;;
      *) die "token endpoint error: ${error}" ;;
    esac
  done
  die "timed out waiting for browser sign-in"
}

refresh_token() {
  load_config
  [[ -n "${KOBY_REFRESH_TOKEN:-}" ]] || die "no refresh token in ${OUTPUT}"
  info "Refreshing token …"
  local response access expires
  response="$(curl -sS -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${KOBY_CLIENT_ID:-$CLIENT_ID}" \
    --data-urlencode "refresh_token=${KOBY_REFRESH_TOKEN}")"
  access="$(jq -r '.access_token // empty' <<<"$response")"
  [[ -n "$access" ]] || die "refresh failed: $(jq -r '.error_description // .error // "unknown error"' <<<"$response")"
  expires="$(jq -r '.expires_in // 2592000' <<<"$response")"
  CLIENT_ID="${KOBY_CLIENT_ID:-$CLIENT_ID}"
  ACCESS_TOKEN="$access"
  REFRESH_TOKEN="$(jq -r '.refresh_token // empty' <<<"$response")"
  [[ -n "$REFRESH_TOKEN" ]] || REFRESH_TOKEN="${KOBY_REFRESH_TOKEN}"
  DEVICE_NAME="${KOBY_DEVICE_NAME:-}"
  DEVICE_ID="${KOBY_DEVICE_ID:-}"
  GATEWAY="${KOBY_GATEWAY:-$GATEWAY}"
  MODEL="${KOBY_MODEL:-$MODEL}"
  API_BASE="${KOBY_API_BASE:-$API_BASE}"
  TRANSCRIBE_URL="${KOBY_TRANSCRIBE_URL:-}"
  TRANSCRIBE_MODEL="${KOBY_TRANSCRIBE_MODEL:-}"
  ISSUED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  EXPIRES_AT="$(iso_expiry "$expires")"
  validate_token "$access" || warn "token refreshed, but gateway check failed"
  write_config
  info "Token refreshed; valid until ${EXPIRES_AT}."
}

check_token() {
  load_config
  [[ -n "${KOBY_TOKEN:-}" ]] || die "no token in ${OUTPUT}"
  if validate_token "$KOBY_TOKEN"; then
    info "OK: ${API_BASE}/models reachable."
  else
    die "gateway check failed (token expired or endpoint changed)"
  fi
  info "  Device  : ${KOBY_DEVICE_NAME:-unknown}"
  info "  Model   : ${KOBY_MODEL:-unknown}"
  info "  Valid   : until ${KOBY_TOKEN_EXPIRES_AT:-unknown}"
}

probe_transcription() {
  load_config
  [[ -n "${KOBY_TRANSCRIBE_URL:-}" ]] || die "KOBY_TRANSCRIBE_URL is not configured"
  local code body
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${KOBY_TOKEN}" \
    -F "model=${KOBY_TRANSCRIBE_MODEL:-unknown}" \
    "$KOBY_TRANSCRIBE_URL" || true)"
  info "HTTP ${code} from ${KOBY_TRANSCRIBE_URL}"
  head -c 400 "$body" >&2 || true
  printf '\n' >&2
  rm -f "$body"
  [[ "$code" != "404" && "$code" != "000" ]]
}

transcribe() {
  load_config
  [[ -f "$AUDIO_FILE" ]] || die "audio file not found: $AUDIO_FILE"
  [[ -n "${KOBY_TRANSCRIBE_URL:-}" ]] || \
    die "no transcription endpoint configured (onboard with --transcribe-url/--transcribe-model)"
  [[ -n "${KOBY_TRANSCRIBE_MODEL:-}" ]] || \
    die "no transcription model configured (onboard with --transcribe-model)"
  info "Uploading $(basename "$AUDIO_FILE") to ${KOBY_TRANSCRIBE_URL} …"
  curl -sS --fail-with-body -X POST \
    -H "Authorization: Bearer ${KOBY_TOKEN}" \
    -F "file=@${AUDIO_FILE}" \
    -F "model=${KOBY_TRANSCRIBE_MODEL}" \
    "$KOBY_TRANSCRIBE_URL"
  printf '\n'
}

set_transcription() {
  local url="$TRANSCRIBE_URL" model="$TRANSCRIBE_MODEL"
  load_config
  DEVICE_NAME="${KOBY_DEVICE_NAME:-$DEVICE_NAME}"
  DEVICE_ID="${KOBY_DEVICE_ID:-$DEVICE_ID}"
  GATEWAY="${KOBY_GATEWAY:-$GATEWAY}"
  MODEL="${KOBY_MODEL:-$MODEL}"
  API_BASE="${KOBY_API_BASE:-$API_BASE}"
  CLIENT_ID="${KOBY_CLIENT_ID:-$CLIENT_ID}"
  AUDIENCE="${KOBY_AUDIENCE:-$AUDIENCE}"
  TRANSCRIBE_URL="$url"
  TRANSCRIBE_MODEL="$model"
  write_config
  info "Transcription settings updated in ${OUTPUT}."
  info "  URL  : ${TRANSCRIBE_URL}"
  info "  Model: ${TRANSCRIBE_MODEL}"
}

case "$ACTION" in
  onboard) onboard ;;
  refresh) refresh_token ;;
  check) check_token ;;
  probe) probe_transcription ;;
  transcribe) transcribe ;;
  set-stt) set_transcription ;;
  *) die "unknown action: $ACTION" ;;
esac
