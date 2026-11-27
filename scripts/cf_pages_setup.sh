#!/usr/bin/env bash
# Creates/updates the Cloudflare Pages project and attaches the subdomain.
# Uses the CLOUDFLARE_API_TOKEN from your shell (it is never printed).
#   scripts/cf_pages_setup.sh [project] [domain]
set -euo pipefail
PROJECT="${1:-trapgunner}"
DOMAIN="${2:-trapgunner.thomasdev.xyz}"
ZONE_NAME="${DOMAIN#*.}"
cd "$(dirname "$0")/.."
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
api() { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" "$@"; }

ACCOUNT_ID=$(api https://api.cloudflare.com/client/v4/accounts | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
echo "account: $ACCOUNT_ID"; export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"

echo "== build wasm"; (cd web && zig build wasm)

echo "== project"
npx --yes wrangler@4 pages project create "$PROJECT" --production-branch main 2>&1 | tail -2 || true

echo "== deploy"
npx --yes wrangler@4 pages deploy web/www --project-name "$PROJECT" --branch main --commit-dirty=true 2>&1 | tail -4

echo "== domain $DOMAIN"
api -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains" \
  -d "{\"name\":\"$DOMAIN\"}" >/dev/null 2>&1 && echo "domain attached" || echo "domain: already attached or not allowed"

ZONE_ID=$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r[0]["id"] if r else "")')
if [ -n "$ZONE_ID" ]; then
  SUB="${DOMAIN%%.*}"
  EXISTS=$(api "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]))')
  if [ "$EXISTS" = "0" ]; then
    api -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"$SUB\",\"content\":\"$PROJECT.pages.dev\",\"proxied\":true}" >/dev/null && echo "CNAME $DOMAIN -> $PROJECT.pages.dev created"
  else echo "DNS for $DOMAIN already exists"; fi
else
  echo "WARNING: zone $ZONE_NAME is not in this account; create CNAME $DOMAIN -> $PROJECT.pages.dev manually"
fi
echo "== domain status"
api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains" | python3 -c 'import sys,json;[print(d["name"],d["status"]) for d in json.load(sys.stdin)["result"]]'
echo "OK: https://$DOMAIN"
