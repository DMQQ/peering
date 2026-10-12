//! The PowerShell prompt wrapper that prints the finish marker `finish::FinishDetector` looks for. It runs after the
//! user's profile, wraps whatever `prompt` that defined, and prints only for a command that took five seconds or more.

pub const POWERSHELL_FINISH_HOOK: &str = concat!(
    "$global:__mcPrompt = $function:prompt; $global:__mcLast = -1; ",
    "function global:prompt { ",
    "$ok = $?; $code = $global:LASTEXITCODE; $h = Get-History -Count 1; $text = & $global:__mcPrompt; ",
    "if ($h -and $h.Id -ne $global:__mcLast) { ",
    "$global:__mcLast = $h.Id; ",
    "$ms = [int64](($h.EndExecutionTime - $h.StartExecutionTime).TotalMilliseconds); ",
    "if ($ms -ge 5000) { ",
    "$status = if ($ok) { 0 } elseif ($code) { $code } else { 1 }; ",
    "$b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($h.CommandLine)); ",
    "[Console]::Out.Write(\"$([char]27)]9999;$ms;$status;$b$([char]7)\") } }; ",
    "$text }",
);
