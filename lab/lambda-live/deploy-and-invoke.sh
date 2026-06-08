#!/usr/bin/env bash
# LAMBDA.LIVE.1 — deploy ONCE, invoke ONCE with the synthetic payload, compare the live output hash to
# the local baseline. REQUIRES AWS credentials; staged but not run in repo CI. NOT a production-load proof.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
REGION="${AWS_REGION:-us-east-1}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "status: awaiting_live_invocation — AWS credentials absent (run with a configured AWS profile)."
  exit 5   # io_or_config: honest 'not run', never a fake green
fi

BASE=$(bash lab/lambda-live/baseline.sh)
LOCAL_OUT=$(echo "$BASE" | sed -n 's/^output_sha256=//p')
echo "local baseline output_sha256=$LOCAL_OUT"

# 1. build the Lambda artifact (feature-gated; needs cargo-lambda + zig)
cargo lambda build --release --features lambda || { echo "build failed"; exit 2; }
# 2. deploy once (creates/updates the function)
#    cargo lambda deploy kobold-lambda-layer --region "$REGION"
# 3. invoke once with the synthetic payload (base64 in the event), capture the response + metadata
#    REQ=$(aws lambda invoke --function-name kobold-lambda-layer --region "$REGION" \
#          --payload "$(base64 -w0 lab/lambda-live/payload.dat)" /tmp/resp.json --query 'ExecutedVersion')
#    LIVE_OUT=$(sha256sum < /tmp/resp.json | cut -d' ' -f1)
# 4. compare LIVE_OUT == LOCAL_OUT  -> verdict; record request id / region / runtime / memory / duration /
#    cold-start into reports/LAMBDA-LIVE-1-receipt.json; state NO production-readiness claim.
echo "deploy/invoke steps are staged above; fill reports/LAMBDA-LIVE-1-receipt.json with the captured run."
