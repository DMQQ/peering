//! How a found binary is started. User text never goes through cmd.exe: an npm shim is replaced by `node <script>`,
//! and the cmd.exe fallback refuses any argument cmd would read as syntax.

use super::{find_binary, Exists, Resolved, SearchEnv};

/// cmd.exe parses these even inside an argument Rust has quoted, so `" & calc & "` or `%PATH%` would run or expand.
const CMD_METACHARACTERS: [char; 12] = ['&', '|', '<', '>', '^', '%', '!', '(', ')', '"', '\r', '\n'];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("an argument cannot be passed through cmd.exe safely")]
pub struct UnsafeArgument;

/// The program and arguments that start a found binary with `args`.
pub fn launch_command(
    resolved: &Resolved,
    args: &[String],
    search: &SearchEnv,
    fs: &dyn Exists,
) -> Result<(String, Vec<String>), UnsafeArgument> {
    if !resolved.needs_cmd_wrapper {
        return Ok((resolved.path.clone(), args.to_vec()));
    }
    if let Some((node, script)) = node_entry(resolved, search, fs) {
        let mut full = vec![script];
        full.extend_from_slice(args);
        return Ok((node, full));
    }
    let unsafe_for_cmd = |value: &String| value.chars().any(|character| CMD_METACHARACTERS.contains(&character));
    if unsafe_for_cmd(&resolved.path) || args.iter().any(unsafe_for_cmd) {
        return Err(UnsafeArgument);
    }
    let mut full = vec!["/c".to_owned(), resolved.path.clone()];
    full.extend_from_slice(args);
    Ok(("cmd.exe".to_owned(), full))
}

/// The node and script an npm shim would run: the `node.exe` beside the shim, else the first `node.exe` on the search.
fn node_entry(resolved: &Resolved, search: &SearchEnv, fs: &dyn Exists) -> Option<(String, String)> {
    let (folder, _) = resolved.path.rsplit_once('\\')?;
    let script = npm_shim_script(&fs.read_text(&resolved.path)?, folder)?;
    if !fs.exists(&script) {
        return None;
    }
    let bundled = format!("{folder}\\node.exe");
    if fs.exists(&bundled) {
        return Some((bundled, script));
    }
    let node = find_binary("node", search, fs).filter(|node| !node.needs_cmd_wrapper)?;
    Some((node.path, script))
}

/// The script an npm `cmd-shim` hands to node: the quoted `%dp0%\...` path after `"%_prog%"`, under `folder`.
pub fn npm_shim_script(shim: &str, folder: &str) -> Option<String> {
    let after_program = shim.split_once("\"%_prog%\"")?.1.trim_start();
    let (path, _) = after_program.strip_prefix('"')?.split_once('"')?;
    let relative = path.strip_prefix("%dp0%\\")?;
    if relative.is_empty() || relative.contains('%') {
        return None;
    }
    Some(format!("{folder}\\{relative}"))
}
