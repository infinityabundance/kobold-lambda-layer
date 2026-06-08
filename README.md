# kobold-lambda-layer

<img src="assets/kobold_data_shim.png" width="200">

**Serverless packaging for the verifiable COBOL decoder.** Turns a buffer of fixed-length COBOL
records (from an S3 export) into structured JSON **plus a per-record audit** — raw bytes and any
`unsupported` fields — by decoding each record byte-exactly through the oracle-proven
[`kobold-data-shim`](https://github.com/infinityabundance/kobold-data-shim) /
[`gnucobol-rs`](https://github.com/infinityabundance/gnucobol-rs) courts. Because the decode is
proven against GnuCOBOL, a batch run emits **evidence, not assertions**.

## What's in here

- **`kobold-lambda-layer` (lib):** the pure, offline-testable batch core — `process_records(copybook,
  data, record_len, resolver)` → per-record decoded fields + a summary; `record_to_json`.
- **`kobold-batch` (bin, default):** an offline CLI that decodes a record file and prints one JSON
  object per record, exiting non-zero if any record needs reconciliation — directly usable as an
  **AWS Batch / Glue / Step Functions** container entrypoint, no AWS SDK required.
- **`kobold-lambda` (bin, `--features lambda`):** an AWS Lambda handler (`lambda_runtime`) with a
  direct-invocation JSON contract. Build with `cargo lambda build --release --features lambda`.
- **`Dockerfile`:** the container-sidecar pattern for hybrid runtimes.

The default build pulls **no AWS crates** (just the two decode crates) — fast to compile and test.
The AWS stack is gated behind the `lambda` feature.

## Offline (works today, no AWS)

```sh
# 3-byte CUST-ID + 3-byte COMP-3 balance = 6-byte records
printf '042\x01\x23\x4d100\x00\x50\x0c' > records.bin
cargo run --bin kobold-batch -- --copybook CUST.cpy --data records.bin --record-len 6
# {"record":0,"unsupported":0,"fields":[... "value":"-12.34" ... "raw_hex":"01234d" ...]}
# {"record":1, ... "value":"5.00" ... }
# summary: records=2 with_unsupported=0 bytes=12     (exit 0; exit 3 if any unsupported)
```

## AWS Lambda (direct invocation)

```jsonc
// event
{ "copybook": "01 CUST. 05 CUST-ID PIC 9(3). 05 CUST-BAL PIC S9(3)V99 COMP-3.",
  "record_len": 6,
  "records_b64": "MDQyASNNMTAwAFAM" }
// response
{ "oracle": "GnuCOBOL 3.2.0", "records": 2, "with_unsupported": 0, "results": [ /* per-record JSON */ ] }
```

```sh
cargo lambda build --release --features lambda     # builds the kobold-lambda binary
cargo lambda invoke --data-file event.json         # local test
# deploy the artifact as a Lambda (arm64 recommended for cost/cold-start)
```

For the **S3 `ObjectCreated`** trigger, either let Step Functions read the object and pass its bytes
in the event, or add `aws-sdk-s3` and fetch the object inside the handler. The decode kernel is
unchanged; only the transport differs.

## Reference architecture

```text
Mainframe VSAM/flat export ─(Transfer Family / Direct Connect)─► S3 landing
   ├─ option A: pre-convert EBCDIC→ASCII upstream
   └─ option B: keep cp500 DISPLAY bytes; decode in-shim with --encoding cp500
       (binary/packed fields remain RAW storage in either path — never text-converted)
   └─(ObjectCreated)─► Step Functions ─► Lambda(kobold-lambda) | Batch/Glue(kobold-batch container)
                                              │  decode byte-exact, emit JSON + audit (raw_hex, unsupported)
                                              ▼
            S3 Parquet → Athena/Glue   |   Aurora (txn)   |   S3 audit/parity receipts → reconciliation
```

Throughput numbers for the decode hot path live in
[`kobold-bench`](https://github.com/infinityabundance/kobold-bench) (~95 M records/sec baseline,
single-thread, byte-exact). Cost intuition: Rust's efficiency cuts Lambda/Glue duration billing vs.
Python/Java equivalents.

## Honest status

The offline core and CLI are tested here. The Lambda handler **type-checks against the real
`lambda_runtime`** but has **not been deployed/invoked on live AWS in this repo's CI** — treat the
deploy steps as a verified-to-compile starting point, not a tested deployment. See
[`docs/enterprise-readiness.md`](docs/enterprise-readiness.md) for SBOM / CVE / SLA.

**LAMBDA.LIVE.1 (staged).** [`lab/lambda-live/`](lab/lambda-live/) holds the harness to close this gap:
`baseline.sh` computes the **local** output hash for a synthetic payload from the offline core
(`kobold-batch`, identical to the handler's `process_records`), and `deploy-and-invoke.sh` is staged to
deploy once + invoke once + compare the **live** output hash — gated on AWS credentials. Until a live run
exists, [`reports/LAMBDA-LIVE-1-receipt.json`](reports/LAMBDA-LIVE-1-receipt.json) records
`status: awaiting_live_invocation` with the local baseline present and the live request id absent. The
acceptance is simply `live output_sha256 == local output_sha256`; **no production-readiness is claimed.**

## License

Apache-2.0 (`LICENSE`). Links `kobold-data-shim` (Apache-2.0) → `gnucobol-rs` (LGPL-3.0+) — any
distributed binary (Lambda zip/layer, container) is a Combined Work under LGPL-3.0 §4; see
[`NOTICE`](NOTICE).
