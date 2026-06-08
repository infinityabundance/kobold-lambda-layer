#!/usr/bin/env bash
# LAMBDA.LIVE.1 local baseline: run the OFFLINE core (kobold-batch == the Lambda handler's process_records)
# on the synthetic payload and record output hashes. This is the value a live AWS invocation must match.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
cargo build --release --bin kobold-batch >/dev/null 2>&1 || { echo "build failed"; exit 2; }
PAY="lab/lambda-live/payload.dat"; CPY="lab/lambda-live/payload.cpy"
OUT=$(./target/release/kobold-batch --copybook "$CPY" --data "$PAY" --record-len 8 2>/dev/null)
PHASH=$(sha256sum "$PAY" | cut -d' ' -f1)
OHASH=$(printf '%s' "$OUT" | sha256sum | cut -d' ' -f1)
RECS=$(printf '%s\n' "$OUT" | grep -c '^{')
echo "payload_sha256=$PHASH"
echo "output_sha256=$OHASH"
echo "records=$RECS"
