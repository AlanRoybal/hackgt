#!/usr/bin/env bash
# Stores the APNs auth key and bundle ID in SSM Parameter Store (SecureString for the key). See docs/APPLE_SETUP.md.
# Usage: ./scripts/put-apns-secrets.sh <stage> <KEY_ID> <TEAM_ID> <BUNDLE_ID> <path/to/AuthKey_XXXX.p8>
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <stage> <KEY_ID> <TEAM_ID> <BUNDLE_ID> <path/to/AuthKey.p8>" >&2
  exit 1
fi
STAGE="$1"; KEY_ID="$2"; TEAM_ID="$3"; BUNDLE_ID="$4"; P8="$5"
[ -f "$P8" ] || { echo "no such file: $P8" >&2; exit 1; }
REGION="${AWS_REGION:-us-east-1}"
BASE="/nudge/${STAGE}"

put() { aws ssm put-parameter --region "$REGION" --overwrite --name "$1" --type "$2" --value "$3" >/dev/null; echo "set $1"; }

put "$BASE/apns/keyId" String "$KEY_ID"
put "$BASE/apns/teamId" String "$TEAM_ID"
put "$BASE/apns/bundleId" String "$BUNDLE_ID"
put "$BASE/apns/p8" SecureString "$(cat "$P8")"
# Sign in with Apple: the native flow's identity token audience is the bundle ID.
put "$BASE/apple/bundleId" String "$BUNDLE_ID"

echo "Done. Running Lambdas pick these up within a minute; no redeploy needed."
