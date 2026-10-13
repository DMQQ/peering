//! Where the runtime writes what went wrong. A release build has no console, so anything a person must see also goes to
//! the snapshot's problems; this is for a run started from a terminal, and the log file for everything else.

use std::io::Write;

pub fn log(message: &str) {
    // A closed stderr is the normal case for a windowed process, and there is nowhere else to say so.
    let _ignored = writeln!(std::io::stderr(), "peering-host: {message}");
    crate::logfile::record(message);
}
