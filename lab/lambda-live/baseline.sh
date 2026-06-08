#!/usr/bin/env bash
# LAMBDA.LIVE.1 local baseline: run the OFFLINE core (kobold-batch == the Lambda handler's process_records /
# record_to_json) on the synthetic payload and record hashes. output_sha256 is the CANONICAL (sorted-key)
# hash of the decoded records — the exact value a live AWS invocation's response `.results` must match,
# independent of JSON serialization order. This is what deploy-and-invoke.sh compares the live run against.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
cargo build --release --bin kobold-batch >/dev/null 2>&1 || { echo "build failed"; exit 2; }
PAY="lab/lambda-live/payload.dat"; CPY="lab/lambda-live/payload.cpy"
OUT=$(./target/release/kobold-batch --copybook "$CPY" --data "$PAY" --record-len 8 2>/dev/null)
PHASH=$(sha256sum "$PAY" | cut -d' ' -f1)
OHASH=$(printf '%s\n' "$OUT" | python3 -c "import sys,json; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()], sort_keys=True, separators=(',',':')))" | sha256sum | cut -d' ' -f1)
RECS=$(printf '%s\n' "$OUT" | grep -c '^{')
echo "payload_sha256=$PHASH"
echo "output_sha256=$OHASH"
echo "records=$RECS"
