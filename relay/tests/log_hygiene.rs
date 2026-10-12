//! The relay promises to log no client addresses. This reads the sources and fails when a tracing
//! call names an address-carrying identifier.

use std::fs;
use std::path::Path;

const MACROS: [&str; 5] = ["debug!(", "info!(", "warn!(", "error!(", "trace!("];
const ADDRESS_IDENTIFIERS: [&str; 6] = ["ip", "peer", "peer_address", "peer_ip", "client_ip", "remote"];

fn without_string_literals(text: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    let mut escaped = false;
    for character in text.chars() {
        if inside {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                inside = false;
            }
        } else if character == '"' {
            inside = true;
        } else {
            out.push(character);
        }
    }
    out
}

fn tracing_calls(source: &str) -> Vec<String> {
    let mut calls = Vec::new();
    for name in MACROS {
        let mut rest = source;
        while let Some(start) = rest.find(name) {
            let body = &rest[start + name.len()..];
            let mut depth = 1;
            let mut inside = false;
            let mut end = body.len();
            for (index, character) in body.char_indices() {
                match character {
                    '"' => inside = !inside,
                    '(' if !inside => depth += 1,
                    ')' if !inside => {
                        depth -= 1;
                        if depth == 0 {
                            end = index;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            calls.push(without_string_literals(&body[..end]));
            rest = &body[end..];
        }
    }
    calls
}

fn identifiers(text: &str) -> Vec<&str> {
    text.split(|c: char| !(c.is_alphanumeric() || c == '_')).filter(|word| !word.is_empty()).collect()
}

fn sources(directory: &Path, found: &mut Vec<std::path::PathBuf>) {
    for entry in fs::read_dir(directory).expect("src is readable") {
        let path = entry.expect("entry").path();
        if path.is_dir() {
            sources(&path, found);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
}

#[test]
fn no_tracing_call_formats_a_peer_address() {
    let mut files = Vec::new();
    sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
    let mut offenders = Vec::new();
    for path in files {
        let source = fs::read_to_string(&path).expect("source is readable");
        let production = source.split("#[cfg(test)]").next().unwrap_or_default();
        for call in tracing_calls(production) {
            if identifiers(&call).iter().any(|word| ADDRESS_IDENTIFIERS.contains(word)) {
                offenders.push(format!("{}: {}", path.display(), call.trim()));
            }
        }
    }
    assert!(offenders.is_empty(), "tracing calls that mention an address: {offenders:#?}");
}

#[test]
fn the_scan_would_catch_a_logged_address() {
    let calls = tracing_calls(r#"fn f() { debug!(peer = %peer_address.ip(), "refused"); }"#);
    assert!(identifiers(&calls[0]).contains(&"peer"));
}
