#!/usr/bin/env bash
set -e

DOMAIN="anchit-tandon.com"
SUB="migration"
FQDN="${SUB}.${DOMAIN}"

echo "=== 1. Checking Authoritative Nameservers for ${DOMAIN} ==="
NS=$(dig +short "${DOMAIN}" NS | head -n 1)
echo "Authoritative NS: ${NS:-Unknown}"

echo ""
echo "=== 2. Checking Existing CNAME on Authoritative NS ==="
EXISTING=$(dig @"${NS}" +short "${FQDN}" CNAME)
if [ -n "$EXISTING" ]; then
  echo "✅ CNAME already exists on authoritative NS: ${FQDN} -> ${EXISTING}"
  echo "Flushing local macOS DNS cache..."
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
  echo "Done. Re-testing local resolution:"
  dig +short "${FQDN}" CNAME
  exit 0
else
  echo "❌ No CNAME record found on ${NS} for ${FQDN}."
fi

echo ""
echo "=== 3. Detecting Deployment Target (Vercel / Cloudflare) ==="
TARGET=""
if command -v vercel >/dev/null 2>&1; then
  TARGET=$(vercel domains inspect "${FQDN}" 2>/dev/null | grep -Eo '[a-zA-Z0-9.-]+\.vercel-dns[a-zA-Z0-9.-]*\.com' | head -n 1 || true)
fi

if [ -z "$TARGET" ]; then
  echo "Could not auto-detect target from Vercel CLI."
  read -p "Enter CNAME target (e.g. cname.vercel-dns.com or migration-dashboard.pages.dev): " TARGET
fi
echo "Using Target: ${TARGET}"

echo ""
echo "=== 4. Attempting Automated DNS Record Creation ==="
if [[ "$NS" == *"cloudflare.com"* ]]; then
  if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')")
    if [ -n "$ZONE_ID" ]; then
      echo "Creating CNAME via Cloudflare API..."
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TARGET}\",\"ttl\":1,\"proxied\":false}" | python3 -m json.tool
      exit 0
    fi
  fi
  echo "No CLOUDFLARE_API_TOKEN found in shell environment. Opening Cloudflare DNS dashboard..."
  open "https://dash.cloudflare.com/?to=/:account/${DOMAIN}/dns/records"

elif [[ "$NS" == *"domaincontrol.com"* ]]; then
  if [ -n "$GODADDY_API_KEY" ] && [ -n "$GODADDY_API_SECRET" ]; then
    echo "Creating CNAME via GoDaddy API..."
    curl -s -X PUT "https://api.godaddy.com/v1/domains/${DOMAIN}/records/CNAME/${SUB}" \
      -H "Authorization: sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}" \
      -H "Content-Type: application/json" \
      --data "[{\"data\":\"${TARGET}\",\"ttl\":600}]"
    echo "✅ CNAME pushed to GoDaddy."
    exit 0
  fi
  echo "No GODADDY_API_KEY found in shell environment. Opening GoDaddy DNS dashboard..."
  open "https://dcc.godaddy.com/control/portfolio/${DOMAIN}/settings?tab=dns"

else
  echo "DNS is hosted at ${NS}. Add this record manually in your DNS panel:"
  echo "  Type:  CNAME"
  echo "  Name:  ${SUB}"
  echo "  Value: ${TARGET}"
fi
