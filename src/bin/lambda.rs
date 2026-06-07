//! `kobold-lambda` — AWS Lambda handler (built only with `--features lambda`).
//!
//! Direct-invocation contract (JSON event):
//! ```json
//! { "copybook": "01 CUST. 05 CUST-ID PIC 9(3). ...",
//!   "record_len": 6,
//!   "records_b64": "<base64 of the raw fixed-length record buffer>" }
//! ```
//! Response: `{ "records": N, "with_unsupported": M, "results": [ {record JSON}, ... ] }`.
//!
//! This keeps the handler dependency-light and fully deployable/testable with `cargo lambda invoke`.
//! For the **S3 ObjectCreated** trigger, front this with Step Functions (pass the object bytes), or
//! add `aws-sdk-s3` to fetch the object inside the handler — see README. The decode itself is the
//! oracle-proven kernel; the handler is a thin transport shim.

use lambda_runtime::{service_fn, Error, LambdaEvent};
use serde_json::{json, Value};

fn b64_decode(s: &str) -> Option<Vec<u8>> {
    // Minimal standard-alphabet base64 decoder (no padding-strictness), avoids an extra dep.
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0u32;
    for &c in s.as_bytes() {
        if c == b'=' || c == b'\n' || c == b'\r' {
            continue;
        }
        let v = val(c)? as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

async fn handler(event: LambdaEvent<Value>) -> Result<Value, Error> {
    let p = event.payload;
    let copybook = p.get("copybook").and_then(|v| v.as_str()).unwrap_or("");
    let record_len = p.get("record_len").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    let data = p
        .get("records_b64")
        .and_then(|v| v.as_str())
        .and_then(b64_decode)
        .unwrap_or_default();

    let (records, summary) =
        kobold_lambda_layer::process_records_simple(copybook, &data, record_len);
    let results: Vec<Value> = records
        .iter()
        .map(|r| {
            serde_json::from_str(&kobold_lambda_layer::record_to_json(r)).unwrap_or(Value::Null)
        })
        .collect();

    Ok(json!({
        "oracle": "GnuCOBOL 3.2.0",
        "records": summary.records,
        "with_unsupported": summary.records_with_unsupported,
        "bytes": summary.bytes,
        "results": results,
    }))
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    lambda_runtime::run(service_fn(handler)).await
}
