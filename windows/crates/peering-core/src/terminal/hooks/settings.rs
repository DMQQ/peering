//! Adds and removes Peering's entries in Claude Code's `settings.json`, leaving every other key and every other hook
//! as it was.

use serde_json::{json, Map, Value};

/// How long a held permission request waits for the phone, in seconds, before Claude Code shows its own dialog. Ten
/// minutes: a phone in a pocket is slow, and the terminal prompt is still there after.
pub const PERMISSION_TIMEOUT_SECONDS: u64 = 600;
const NOTIFICATION_TIMEOUT_SECONDS: u64 = 10;
/// Idle and question notifications only: a permission prompt already reaches the phone as a `PermissionRequest`.
const NOTIFICATION_MATCHER: &str = "idle_prompt|elicitation_dialog";
/// The name every Peering entry's command ends in, which is how an entry is recognised later.
pub const COMMAND_NAME: &str = "peering-hook";
const EVENTS: [&str; 2] = ["PermissionRequest", "Notification"];

/// A shape this does not know is refused, never replaced: the file is the user's.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unexpected \"{0}\" in the settings")]
pub struct UnexpectedShape(pub String);

pub fn installing(command: &str, settings: &Map<String, Value>) -> Result<Map<String, Value>, UnexpectedShape> {
    let mut settings = removing(settings)?;
    let mut hooks = hooks_in(&settings)?;
    append(&mut hooks, "PermissionRequest", None, command, PERMISSION_TIMEOUT_SECONDS)?;
    append(&mut hooks, "Notification", Some(NOTIFICATION_MATCHER), command, NOTIFICATION_TIMEOUT_SECONDS)?;
    settings.insert("hooks".to_owned(), Value::Object(hooks));
    Ok(settings)
}

pub fn removing(settings: &Map<String, Value>) -> Result<Map<String, Value>, UnexpectedShape> {
    let mut settings = settings.clone();
    if !settings.contains_key("hooks") {
        return Ok(settings);
    }
    let mut hooks = hooks_in(&settings)?;
    for event in hooks.keys().cloned().collect::<Vec<_>>() {
        let kept: Vec<Value> = groups_in(&hooks, &event)?.into_iter().filter_map(without_peering).collect();
        if kept.is_empty() {
            hooks.remove(&event);
        } else {
            hooks.insert(event, Value::Array(kept));
        }
    }
    if hooks.is_empty() {
        settings.remove("hooks");
    } else {
        settings.insert("hooks".to_owned(), Value::Object(hooks));
    }
    Ok(settings)
}

pub fn is_installed(settings: &Map<String, Value>) -> bool {
    let Some(hooks) = settings.get("hooks").and_then(Value::as_object) else {
        return false;
    };
    EVENTS.iter().all(|event| {
        hooks.get(*event).and_then(Value::as_array).is_some_and(|groups| {
            groups.iter().any(|group| entries_of(group).is_some_and(|entries| entries.iter().any(is_peering)))
        })
    })
}

/// A group without its Peering entries, or `None` when nothing is left of it. A group of a shape this does not know stays.
fn without_peering(group: Value) -> Option<Value> {
    let Some(entries) = entries_of(&group) else {
        return Some(group);
    };
    let remaining: Vec<Value> = entries.iter().filter(|entry| !is_peering(entry)).cloned().collect();
    if remaining.is_empty() {
        return None;
    }
    let mut kept = group;
    kept["hooks"] = Value::Array(remaining);
    Some(kept)
}

fn entries_of(group: &Value) -> Option<&Vec<Value>> {
    group.get("hooks")?.as_array().filter(|entries| entries.iter().all(Value::is_object))
}

/// The command is quoted (the folder has a space in it), so it ends in the name and a closing quote.
fn is_peering(entry: &Value) -> bool {
    entry.get("command").and_then(Value::as_str).is_some_and(|command| command.contains(&format!("/{COMMAND_NAME}")))
}

fn hooks_in(settings: &Map<String, Value>) -> Result<Map<String, Value>, UnexpectedShape> {
    match settings.get("hooks") {
        None => Ok(Map::new()),
        Some(Value::Object(hooks)) => Ok(hooks.clone()),
        Some(_) => Err(UnexpectedShape("hooks".to_owned())),
    }
}

fn groups_in(hooks: &Map<String, Value>, event: &str) -> Result<Vec<Value>, UnexpectedShape> {
    match hooks.get(event) {
        None => Ok(Vec::new()),
        Some(Value::Array(groups)) if groups.iter().all(Value::is_object) => Ok(groups.clone()),
        Some(_) => Err(UnexpectedShape(format!("hooks.{event}"))),
    }
}

fn append(
    hooks: &mut Map<String, Value>,
    event: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: u64,
) -> Result<(), UnexpectedShape> {
    let mut groups = groups_in(hooks, event)?;
    let mut group = json!({ "hooks": [{ "type": "command", "command": command, "timeout": timeout }] });
    if let Some(matcher) = matcher {
        group["matcher"] = json!(matcher);
    }
    groups.push(group);
    hooks.insert(event.to_owned(), Value::Array(groups));
    Ok(())
}

#[cfg(test)]
mod tests;
