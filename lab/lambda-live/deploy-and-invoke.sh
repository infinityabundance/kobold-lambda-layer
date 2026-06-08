#!/usr/bin/env bash
# LAMBDA.LIVE.1 — deploy ONCE, invoke ONCE with the synthetic payload, compare the live response's decoded
# records to the local baseline (canonical, key-order-independent), capture the live metadata, write the
# receipt, and clean up. REQUIRES AWS credentials; not run in repo CI. Single synthetic payload only — NOT a
# production-load proof and NOT semantic authority (decode correctness is gnucobol-rs/kobold-data-shim).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
REGION="${AWS_REGION:-us-east-1}"
FUNC="${KOBOLD_LAMBDA_FUNC:-kobold-lambda-live-1}"
RECEIPT="reports/LAMBDA-LIVE-1-receipt.json"
EVENT="lab/lambda-live/event.json"

# Honest gate: no credentials -> 'awaiting_live_invocation', exit 5 (io/config). Never a fake green, and the
# committed receipt is left untouched (no placeholder values).
if ! command -v aws >/dev/null 2>&1 || ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "status: awaiting_live_invocation — AWS credentials/CLI absent. Receipt left as-is (local baseline only)."
  exit 5
fi

# 0. local baseline (the value the live run must reproduce)
BASE=$(bash lab/lambda-live/baseline.sh) || { echo "baseline failed"; exit 2; }
LOCAL_OUT=$(echo "$BASE" | sed -n 's/^output_sha256=//p')
PAYLOAD_SHA=$(echo "$BASE" | sed -n 's/^payload_sha256=//p')
RECS=$(echo "$BASE" | sed -n 's/^records=//p')
echo "local baseline records_sha256=$LOCAL_OUT"
ACCT=$(aws sts get-caller-identity --query Account --output text)

# 1. build the Lambda artifact (needs cargo-lambda + zig) and 2. deploy ONCE
cargo lambda build --release --arm64 --features lambda || { echo "lambda build failed"; exit 2; }
cargo lambda deploy "$FUNC" --region "$REGION" --enable-function-url false || { echo "deploy failed"; exit 2; }

# 3. invoke ONCE with the synthetic payload; capture the response + the tail log (RequestId + REPORT line)
aws lambda invoke --function-name "$FUNC" --region "$REGION" \
  --cli-binary-format raw-in-base64-out --payload "file://$EVENT" \
  --log-type Tail --query 'LogResult' --output text /tmp/kobold-resp.json > /tmp/kobold-log.b64 || { echo "invoke failed"; exit 2; }
LOG=$(base64 -d < /tmp/kobold-log.b64 2>/dev/null)

# 4. live decoded records, canonicalized the SAME way as the baseline (sorted keys) -> apples-to-apples
LIVE_OUT=$(python3 -c "import json; print(json.dumps(json.load(open('/tmp/kobold-resp.json')).get('results',[]), sort_keys=True, separators=(',',':')))" | sha256sum | cut -d' ' -f1)

# 5. metadata from the REPORT line + function config
REQ_ID=$(printf '%s' "$LOG"  | grep -oE 'RequestId: [0-9a-f-]+'        | head -1 | awk '{print $2}')
DUR=$(printf '%s' "$LOG"     | grep -oE 'Billed Duration: [0-9]+ ms'  | grep -oE '[0-9]+' | head -1)
MEM=$(printf '%s' "$LOG"     | grep -oE 'Memory Size: [0-9]+ MB'      | grep -oE '[0-9]+' | head -1)
INIT=$(printf '%s' "$LOG"    | grep -oE 'Init Duration: [0-9.]+ ms'   | grep -oE '[0-9.]+' | head -1)
COLD=$([ -n "$INIT" ] && echo true || echo false)
RUNTIME=$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGION" --query 'Runtime'         --output text 2>/dev/null)
ARCH=$(aws lambda get-function-configuration    --function-name "$FUNC" --region "$REGION" --query 'Architectures[0]' --output text 2>/dev/null)
VER=$(aws lambda get-function-configuration      --function-name "$FUNC" --region "$REGION" --query 'Version'         --output text 2>/dev/null)
LOGGRP="/aws/lambda/$FUNC"

# 6. verdict (canonical decode equality) — bytes are authority, never a soft pass
if [ "$LIVE_OUT" = "$LOCAL_OUT" ]; then STATUS="live_verified"; VERDICT="live_matches_local_baseline"; else STATUS="live_mismatch"; VERDICT="MISMATCH: live_records_sha256 != local_baseline"; fi

# 7. clean up (deploy once / invoke once -> delete the function), record the outcome
if aws lambda delete-function --function-name "$FUNC" --region "$REGION" 2>/dev/null; then CLEANUP="function_deleted"; else CLEANUP="cleanup_failed_manual_review"; fi

# 8. emit the receipt from the REAL captured values (no placeholders)
python3 - "$STATUS" "$VERDICT" "$PAYLOAD_SHA" "$LOCAL_OUT" "$RECS" "$REGION" "$ACCT" "$REQ_ID" "$RUNTIME" "$ARCH" "$VER" "$MEM" "$DUR" "$COLD" "$LIVE_OUT" "$LOGGRP" "$CLEANUP" > "$RECEIPT" <<'PYW'
import json, sys
a = sys.argv
def num(x):
    try: return int(x)
    except: 
        try: return float(x)
        except: return None
json.dump({
  "schema": "lambda-live-receipt-v1", "court": "LAMBDA.LIVE.1", "status": a[1],
  "local_baseline": {"payload_sha256": a[3], "output_sha256": a[4], "records": int(a[5]),
    "comparison": "canonical (sorted-key) sha256 of the decoded records; serialization-order-independent",
    "computed_by": "kobold-batch (offline core; identical process_records/record_to_json to the Lambda handler)",
    "command": "bash lab/lambda-live/baseline.sh"},
  "live_invocation": {"request_id": a[8] or None, "region": a[6], "account_id": a[7], "runtime": a[9] or None,
    "architecture": a[10] or None, "function_version": a[11] or None, "memory_mb": num(a[12]),
    "billed_duration_ms": num(a[13]), "cold_start": a[14] == "true", "output_sha256": a[15] or None,
    "cloudwatch_log_group": a[16], "cleanup_status": a[17]},
  "acceptance": "live_invocation.output_sha256 == local_baseline.output_sha256",
  "verdict": a[2], "production_readiness_claim": False,
  "how_to_run_live": "lab/lambda-live/deploy-and-invoke.sh (requires AWS credentials)",
  "non_claims": ["not a production-load proof", "single synthetic 3-record payload only",
    "one deploy + one invoke, then deleted", "no semantic authority — decode correctness is gnucobol-rs/kobold-data-shim, not this layer",
    "not a cost/SLA/throughput claim (see GLUE/LAMBDA.SCALE.1, future)"]
}, sys.stdout, indent=2)
PYW
echo "status: $STATUS  verdict: $VERDICT  request_id: ${REQ_ID:-n/a}  cleanup: $CLEANUP"
echo "receipt written: $RECEIPT"
[ "$STATUS" = "live_verified" ] && exit 0 || exit 1
