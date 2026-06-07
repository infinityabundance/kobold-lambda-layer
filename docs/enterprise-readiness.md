# Enterprise readiness — packaging, SBOM, CVE, SLA

## Packaging options

| Pattern | When | Notes |
|---------|------|-------|
| **AWS Lambda (Rust runtime)** | event-driven / incremental ingestion | `cargo lambda build --release --features lambda` → tiny arm64/x86-64 binary, fast cold starts. Direct-invocation contract (copybook + base64 records). For S3 `ObjectCreated`, front with Step Functions or add `aws-sdk-s3` to fetch the object in-handler. |
| **Lambda layer** | a shared decoder across many functions in an account | Layers are less idiomatic for Rust (single-binary), but useful org-wide. Ship the built artifact + NOTICE. |
| **Container sidecar (ECS/EKS)** | hybrid runtimes alongside rehosted COBOL | `Dockerfile` builds `kobold-batch`; the sidecar decodes records off a shared volume and emits JSON + a reconciliation exit code. Wrap behind HTTP for request/response. |
| **AWS Batch / Glue** | large nightly files | run `kobold-batch` as the container entrypoint; non-zero exit signals records needing reconciliation. |

## SBOM

- Default runtime closure is **two crates**: `kobold-data-shim` (Apache-2.0) → `gnucobol-rs`
  (LGPL-3.0+), which has **zero further runtime deps**. The `lambda` feature adds
  `lambda_runtime`/`tokio`/`serde_json` (build-time-selected).
- A minimal CycloneDX SBOM is committed at `reports/sbom.json`; regenerate the full graph with
  `cargo cyclonedx --format json --all-features`. The SBOM records the pinned `gnucobol-rs` version
  and its admitted GnuCOBOL 3.2 oracle provenance.

## CVE / vulnerability scanning

- CI runs `cargo audit` (RustSec). The default build's tiny dependency surface keeps this near-empty.
- The `lambda` feature's async stack (`tokio` et al.) is the main surface to track; it is only pulled
  when explicitly building the handler.

## Support / SLA posture

- **SemVer**; host assumption little-endian ASCII (the `gnucobol-rs` sealed claim); EBCDIC translated
  upstream until an EBCDIC court lands; MSRV 1.74.
- Decode **semantics** track the `gnucobol-rs` sealed courts — proven byte-identical to GnuCOBOL
  under differential sweeps, with Kani + fuzzing. That oracle-backed evidence, not a marketing claim,
  is the procurement story.
- An SLA-backed offering is a commercial-track question; the permissive clean-room kernel (future)
  is its natural basis (it removes the LGPL relink obligation for proprietary distribution).
