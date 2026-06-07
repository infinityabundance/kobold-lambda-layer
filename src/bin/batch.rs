//! `kobold-batch` — offline batch decoder (no AWS). Reads a copybook and a file of fixed-length
//! COBOL records, decodes each via the oracle-proven kernel, and emits one JSON object per record
//! plus a summary on stderr. This is the same core the Lambda handler runs — testable without AWS.
//!
//! Usage: kobold-batch --copybook CUST.cpy --data records.bin --record-len 6 [--copydir DIR]

use std::process::ExitCode;

struct DirResolver(Option<String>);
impl kobold_data_shim::CopyResolver for DirResolver {
    fn resolve(&self, name: &str) -> Option<String> {
        let dir = self.0.as_ref()?;
        for base in [name.to_string(), name.to_ascii_lowercase()] {
            for ext in ["", ".cpy", ".CPY", ".cbl", ".cob"] {
                if let Ok(s) = std::fs::read_to_string(format!("{dir}/{base}{ext}")) {
                    return Some(s);
                }
            }
        }
        None
    }
}

fn main() -> ExitCode {
    let mut copybook = None;
    let mut data = None;
    let mut record_len = None;
    let mut copydir = None;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--copybook" => copybook = it.next().cloned(),
            "--data" => data = it.next().cloned(),
            "--record-len" => record_len = it.next().and_then(|s| s.parse::<usize>().ok()),
            "--copydir" => copydir = it.next().cloned(),
            _ => {
                eprintln!("usage: kobold-batch --copybook <f> --data <f> --record-len <n> [--copydir <d>]");
                return ExitCode::from(2);
            }
        }
    }
    let (Some(cb), Some(df), Some(rlen)) = (copybook, data, record_len) else {
        eprintln!("usage: kobold-batch --copybook <f> --data <f> --record-len <n> [--copydir <d>]");
        return ExitCode::from(2);
    };
    let cb = match std::fs::read_to_string(&cb) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("copybook: {e}");
            return ExitCode::from(1);
        }
    };
    let bytes = match std::fs::read(&df) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("data: {e}");
            return ExitCode::from(1);
        }
    };

    let resolver = DirResolver(copydir);
    let (records, summary) = kobold_lambda_layer::process_records(&cb, &bytes, rlen, &resolver);
    for r in &records {
        println!("{}", kobold_lambda_layer::record_to_json(r));
    }
    eprintln!(
        "summary: records={} with_unsupported={} bytes={}",
        summary.records, summary.records_with_unsupported, summary.bytes
    );
    // Nonzero exit if anything needs reconciliation — useful as a Step Functions / Batch signal.
    if summary.records_with_unsupported > 0 {
        return ExitCode::from(3);
    }
    ExitCode::SUCCESS
}
