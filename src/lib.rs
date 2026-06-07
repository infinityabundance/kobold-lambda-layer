//! # kobold-lambda-layer
//!
//! Serverless packaging for the verifiable COBOL decoder. The **core** here is pure and
//! offline-testable: split a buffer of fixed-length COBOL records and decode each against a copybook
//! via [`kobold_data_shim`], producing structured JSON plus a per-record audit (raw bytes + any
//! `unsupported` fields — the reconciliation signal). The AWS Lambda handler (the `lambda` feature)
//! is a thin wrapper over this core.
//!
//! The decode is byte-exact and oracle-proven (it composes the sealed `gnucobol-rs` courts), so a
//! batch job emits **evidence**, not assertions.

#![forbid(unsafe_code)]

use kobold_data_shim::{decode_with_resolver, CopyResolver, DecodedField, NoCopy};

/// The outcome of decoding one record.
#[derive(Debug, Clone)]
pub struct RecordResult {
    pub index: usize,
    pub fields: Vec<DecodedField>,
    /// Count of fields outside the sealed subset — nonzero means "route to reconciliation".
    pub unsupported: usize,
}

/// Summary across a batch.
#[derive(Debug, Clone, Default)]
pub struct BatchSummary {
    pub records: usize,
    pub records_with_unsupported: usize,
    pub bytes: usize,
}

/// Decode a buffer of fixed-length records (`record_len` bytes each) against `copybook`, resolving
/// nested `COPY` via `resolver`. A trailing partial record is reported as its own unsupported result.
pub fn process_records(
    copybook: &str,
    data: &[u8],
    record_len: usize,
    resolver: &impl CopyResolver,
) -> (Vec<RecordResult>, BatchSummary) {
    let mut out = Vec::new();
    let mut summary = BatchSummary {
        bytes: data.len(),
        ..Default::default()
    };
    if record_len == 0 {
        return (out, summary);
    }
    for (index, chunk) in data.chunks(record_len).enumerate() {
        summary.records += 1;
        let fields = match decode_with_resolver(copybook, chunk, resolver) {
            Ok(f) => f,
            Err(_) => {
                // A copybook/layout error is itself a reconciliation signal, not a panic.
                out.push(RecordResult {
                    index,
                    fields: Vec::new(),
                    unsupported: 1,
                });
                summary.records_with_unsupported += 1;
                continue;
            }
        };
        let unsupported = fields
            .iter()
            .filter(|f| f.category == "unsupported")
            .count();
        if unsupported > 0 {
            summary.records_with_unsupported += 1;
        }
        out.push(RecordResult {
            index,
            fields,
            unsupported,
        });
    }
    (out, summary)
}

/// Convenience: decode a batch with no nested `COPY`.
pub fn process_records_simple(
    copybook: &str,
    data: &[u8],
    record_len: usize,
) -> (Vec<RecordResult>, BatchSummary) {
    process_records(copybook, data, record_len, &NoCopy)
}

/// Render one record's decoded fields as a JSON object string (no external deps), with the audit
/// trail (raw_hex) and the oracle identity.
pub fn record_to_json(r: &RecordResult) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "{{\"record\":{},\"unsupported\":{},\"fields\":[",
        r.index, r.unsupported
    ));
    for (i, f) in r.fields.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!(
            "{{\"name\":{},\"category\":{},\"value\":{},\"raw_hex\":{}}}",
            jstr(&f.name),
            jstr(f.category),
            jstr(&f.value),
            jstr(&f.raw_hex)
        ));
    }
    s.push_str("]}");
    s
}

fn jstr(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn processes_a_batch() {
        let cb = "01 CUST.\n05 CUST-ID PIC 9(3).\n05 CUST-BAL PIC S9(3)V99 COMP-3.";
        // two 6-byte records: "042" + 01234d (-12.34), "100" + 00500c (5.00)
        let mut data = Vec::new();
        data.extend_from_slice(b"042");
        data.extend_from_slice(&[0x01, 0x23, 0x4d]); // -12.34
        data.extend_from_slice(b"100");
        data.extend_from_slice(&[0x00, 0x50, 0x0c]); // 005.00 -> 5.00
        let (res, sum) = process_records_simple(cb, &data, 6);
        assert_eq!(sum.records, 2);
        assert_eq!(sum.records_with_unsupported, 0);
        let bal = |r: &RecordResult| {
            r.fields
                .iter()
                .find(|f| f.name == "CUST-BAL")
                .unwrap()
                .value
                .clone()
        };
        assert_eq!(bal(&res[0]), "-12.34");
        assert_eq!(bal(&res[1]), "5.00");
        assert!(record_to_json(&res[0]).contains("\"-12.34\""));
    }
}
