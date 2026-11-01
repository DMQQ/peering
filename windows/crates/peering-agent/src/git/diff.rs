//! Reads the patch `git diff` prints into one entry per file, and gives an untracked file the same shape. Mirrors
//! `AgentGitDiff.swift`.

use peering_wire::agent::{AgentChangeKind, AgentChangedFile};

pub const TRUNCATION_NOTE: &str = "\u{2026} (the rest of this file's diff is not shown)";
pub const PER_FILE_LIMIT: usize = 200 * 1024;

pub fn files(patch: &str, limit: usize) -> Vec<AgentChangedFile> {
    let mut blocks: Vec<Vec<&str>> = Vec::new();
    for line in patch.split('\n') {
        if line.starts_with("diff --git ") {
            blocks.push(vec![line]);
        } else if let Some(block) = blocks.last_mut() {
            block.push(line);
        }
    }
    blocks.iter().filter_map(|block| file(block, limit)).collect()
}

/// A file git does not track yet, as an all-added diff. Binary content has no diff.
pub fn untracked(path: &str, content: Option<&str>, limit: usize) -> AgentChangedFile {
    let Some(content) = content else {
        return AgentChangedFile { path: path.to_owned(), kind: AgentChangeKind::Untracked, added: 0, removed: 0, diff: None };
    };
    let mut lines: Vec<&str> = content.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    let mut text = format!("--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{} @@\n", lines.len());
    text += &lines.iter().map(|line| format!("+{line}")).collect::<Vec<_>>().join("\n");
    AgentChangedFile {
        path: path.to_owned(),
        kind: AgentChangeKind::Untracked,
        added: lines.len() as i64,
        removed: 0,
        diff: Some(clipped(&text, limit)),
    }
}

fn file(block: &[&str], limit: usize) -> Option<AgentChangedFile> {
    let path = path(block)?;
    let is_binary = block.iter().any(|line| line.starts_with("Binary files ") || line.starts_with("GIT binary patch"));
    let kind = if block.iter().any(|line| line.starts_with("new file mode")) {
        AgentChangeKind::Added
    } else if block.iter().any(|line| line.starts_with("deleted file mode")) {
        AgentChangeKind::Deleted
    } else {
        AgentChangeKind::Modified
    };
    let first_hunk = block.iter().position(|line| line.starts_with("@@"));
    let (Some(first_hunk), false) = (first_hunk, is_binary) else {
        return Some(AgentChangedFile { path, kind, added: 0, removed: 0, diff: None });
    };
    let body = &block[first_hunk..];
    let added = body.iter().filter(|line| line.starts_with('+')).count() as i64;
    let removed = body.iter().filter(|line| line.starts_with('-')).count() as i64;
    let mut text = block.join("\n");
    if text.ends_with('\n') {
        text.pop();
    }
    Some(AgentChangedFile { path, kind, added, removed, diff: Some(clipped(&text, limit)) })
}

/// Taken from the `---`/`+++` lines where there are any, since a name with a space makes the `diff --git` line
/// ambiguous. Only the header is searched: an added line that reads `++ b/x` is content.
fn path(block: &[&str]) -> Option<String> {
    let header: Vec<&str> = block.iter().copied().take_while(|line| !line.starts_with("@@")).collect();
    for prefix in ["+++ ", "--- "] {
        let Some(line) = header.iter().find(|line| line.starts_with(prefix)) else { continue };
        let name = unquoted(line[prefix.len()..].trim_matches(['\t', '\r']));
        for side in ["b/", "a/"] {
            if let Some(rest) = name.strip_prefix(side) {
                return Some(rest.to_owned());
            }
        }
    }
    let rest = block.first()?.strip_prefix("diff --git a/")?;
    let count = rest.chars().count();
    let length = count.checked_sub(3)? / 2;
    (length > 0 && count == 2 * length + 3).then(|| rest.chars().take(length).collect())
}

/// Git quotes a name holding a quote, backslash, tab or control character, writing non-ASCII bytes as octal.
pub fn unquoted(name: &str) -> String {
    if !(name.len() >= 2 && name.starts_with('"') && name.ends_with('"')) {
        return name.to_owned();
    }
    let body = &name.as_bytes()[1..name.len() - 1];
    let mut bytes = Vec::with_capacity(body.len());
    let mut index = 0;
    while index < body.len() {
        let byte = body[index];
        index += 1;
        if byte != b'\\' || index >= body.len() {
            bytes.push(byte);
            continue;
        }
        let escaped = body[index];
        index += 1;
        match escaped {
            b't' => bytes.push(9),
            b'n' => bytes.push(10),
            b'r' => bytes.push(13),
            b'0'..=b'7' => {
                let mut value = u32::from(escaped - b'0');
                let mut digits = 1;
                while digits < 3 && index < body.len() && (b'0'..=b'7').contains(&body[index]) {
                    value = value * 8 + u32::from(body[index] - b'0');
                    index += 1;
                    digits += 1;
                }
                bytes.push(value as u8);
            }
            other => bytes.push(other),
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn clipped(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut kept = String::new();
    let mut size = 0;
    for line in text.split('\n') {
        size += line.len() + 1;
        if size > limit {
            break;
        }
        kept.push_str(line);
        kept.push('\n');
    }
    kept + TRUNCATION_NOTE
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATCH: &str = "diff --git a/src/a.rs b/src/a.rs\nindex 1..2 100644\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,2 @@\n-old\n+new\n same\ndiff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\ndiff --git a/p.png b/p.png\nnew file mode 100644\nBinary files /dev/null and b/p.png differ\n";

    #[test]
    fn a_patch_splits_into_files_with_their_kind_and_counts() {
        let found = files(PATCH, PER_FILE_LIMIT);
        let summary: Vec<_> = found.iter().map(|file| (file.path.as_str(), file.kind, file.added, file.removed)).collect();
        assert_eq!(
            summary,
            [
                ("src/a.rs", AgentChangeKind::Modified, 1, 1),
                ("gone.txt", AgentChangeKind::Deleted, 0, 1),
                ("p.png", AgentChangeKind::Added, 0, 0),
            ]
        );
        assert!(found[2].diff.is_none(), "a binary file has no diff");
        assert!(found[0].diff.as_deref().is_some_and(|diff| diff.starts_with("diff --git")));
    }

    #[test]
    fn crlf_lines_do_not_swallow_the_next_file() {
        let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\r\n+b\r\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-c\n+d\n";
        assert_eq!(files(patch, PER_FILE_LIMIT).len(), 2);
    }

    #[test]
    fn a_quoted_name_is_unescaped_from_octal_bytes() {
        assert_eq!(unquoted("\"caf\\303\\251 \\\"q\\\".txt\""), "caf\u{e9} \"q\".txt");
        assert_eq!(unquoted("plain"), "plain");
    }

    #[test]
    fn an_untracked_file_is_all_added_and_a_binary_one_has_no_diff() {
        let file = untracked("new.txt", Some("one\ntwo\n"), PER_FILE_LIMIT);
        assert_eq!(file.added, 2);
        assert_eq!(file.diff.as_deref(), Some("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+one\n+two"));
        assert_eq!(untracked("b.bin", None, PER_FILE_LIMIT).diff, None);
    }

    #[test]
    fn a_large_diff_is_cut_at_a_line_and_noted() {
        let file = untracked("big.txt", Some(&"line\n".repeat(100)), 80);
        let diff = file.diff.expect("a diff");
        assert!(diff.ends_with(TRUNCATION_NOTE));
        assert_eq!(file.added, 100, "counts cover the whole file");
    }
}
