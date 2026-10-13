//! Routes a ready session's frames: commands to the input sink or the source control, pings to pongs.
//! Mirrors `apple/PeeringHost/Network/HostSession+Commands.swift` for the commands this core supports.

use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::quality::clamped_bitrate_kbps;
use peering_wire::source::CaptureSource;

use super::actions::CloseReason;
use super::handshake::MAX_CONTROL_PAYLOAD;
use super::liveness::pong_for;
use crate::ports::input::{InputSink, TransformSnapshot};

/// The most a command put back together from chunks may be.
const MAX_ASSEMBLED_COMMAND: usize = 12 * 1024 * 1024;

/// Capture and encoder controls the host performs. `None` for a quality value means keep the current one.
pub trait SourceControl {
    fn set_source(&mut self, source: CaptureSource);
    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>);
    fn set_video_enabled(&mut self, enabled: bool);
    fn lock_screen(&mut self);
}

pub struct DispatchContext<'a> {
    pub observe_mode: bool,
    pub transform: TransformSnapshot,
    pub input: &'a mut dyn InputSink,
    pub source: &'a mut dyn SourceControl,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IgnoreReason {
    ObserveMode,
    MosaicSource,
    VirtualDisplay,
    PrivacyMode { enabled: bool },
    WindowAction,
    SpaceSwitch,
    /// `launchApplication` and `openNewWindow`.
    Launch,
    NotSupportedHere,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DispatchOutcome {
    Applied,
    Ignored(IgnoreReason),
    /// A command the host's own services carry out, such as the clipboard, which this core has no port for.
    ForHost(RemoteCommand),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReadyOutcome {
    Dispatched(DispatchOutcome),
    Reply(Frame),
    Close(CloseReason),
    /// A kind this core does not implement. The protocol says to ignore it, not to end the session.
    Unhandled(MessageKind),
}

pub fn dispatch(command: RemoteCommand, ctx: &mut DispatchContext<'_>) -> DispatchOutcome {
    if let Some(reason) = ignore_reason(&command) {
        return DispatchOutcome::Ignored(reason);
    }
    if is_for_host(&command) {
        return DispatchOutcome::ForHost(command);
    }
    if command.is_user_input() {
        if ctx.observe_mode {
            return DispatchOutcome::Ignored(IgnoreReason::ObserveMode);
        }
        ctx.input.apply(&command, &ctx.transform);
        return DispatchOutcome::Applied;
    }
    control(command, ctx)
}

pub fn on_ready_frame(frame: &Frame, ctx: &mut DispatchContext<'_>) -> ReadyOutcome {
    match frame.kind {
        MessageKind::Command => match decode_command(frame, MAX_CONTROL_PAYLOAD) {
            Ok(command) => ReadyOutcome::Dispatched(dispatch(command, ctx)),
            Err(reason) => ReadyOutcome::Close(reason),
        },
        MessageKind::Ping => ReadyOutcome::Reply(pong_for(frame)),
        other => ReadyOutcome::Unhandled(other),
    }
}

/// A command that arrived in chunks and was put back together. It is held to the reassembly limit, not the 64 KiB a single
/// frame is, because a clipboard picture is larger than that by design.
pub fn on_assembled_command(frame: &Frame, ctx: &mut DispatchContext<'_>) -> ReadyOutcome {
    if frame.kind != MessageKind::Command {
        return ReadyOutcome::Unhandled(frame.kind);
    }
    match decode_command(frame, MAX_ASSEMBLED_COMMAND) {
        Ok(command) => ReadyOutcome::Dispatched(dispatch(command, ctx)),
        Err(reason) => ReadyOutcome::Close(reason),
    }
}

fn decode_command(frame: &Frame, limit: usize) -> Result<RemoteCommand, CloseReason> {
    if frame.payload.len() > limit {
        return Err(CloseReason::MalformedPayload(MessageKind::Command));
    }
    serde_json::from_slice(&frame.payload).map_err(|_| CloseReason::MalformedPayload(MessageKind::Command))
}

/// Commands the host recognises but does not carry out here. Checked before anything else, so a space switch is
/// refused even when the session is not observing.
fn ignore_reason(command: &RemoteCommand) -> Option<IgnoreReason> {
    match command {
        RemoteCommand::SwitchSpace { .. } | RemoteCommand::SwitchToSpace { .. } => Some(IgnoreReason::SpaceSwitch),
        RemoteCommand::AddVirtualDisplay { .. }
        | RemoteCommand::RemoveVirtualDisplay { .. }
        | RemoteCommand::RenameVirtualDisplay { .. } => Some(IgnoreReason::VirtualDisplay),
        RemoteCommand::SetPrivacyMode { enabled } => Some(IgnoreReason::PrivacyMode { enabled: *enabled }),
        RemoteCommand::PerformWindowAction { .. } => Some(IgnoreReason::WindowAction),
        RemoteCommand::LaunchApplication { .. } | RemoteCommand::OpenNewWindow { .. } => Some(IgnoreReason::Launch),
        RemoteCommand::SetCaptureSource { source: CaptureSource::Mosaic { .. } } => Some(IgnoreReason::MosaicSource),
        _ => None,
    }
}

fn is_for_host(command: &RemoteCommand) -> bool {
    matches!(
        command,
        RemoteCommand::RequestClipboard {} | RemoteCommand::PushClipboard { .. } | RemoteCommand::PushClipboardImage { .. }
    )
}

fn control(command: RemoteCommand, ctx: &mut DispatchContext<'_>) -> DispatchOutcome {
    match command {
        RemoteCommand::SetCaptureSource { source } => ctx.source.set_source(source),
        RemoteCommand::SetStreamQuality { fps, bitrate_kbps } => {
            ctx.source.set_quality(requested_fps(fps), clamped_bitrate_kbps(bitrate_kbps));
        }
        RemoteCommand::SetVideoEnabled { enabled } => ctx.source.set_video_enabled(enabled),
        RemoteCommand::LockScreen {} => ctx.source.lock_screen(),
        _ => return DispatchOutcome::Ignored(IgnoreReason::NotSupportedHere),
    }
    DispatchOutcome::Applied
}

/// Zero or a negative frame rate means keep the current one, as on the wire; a larger one is capped to `u32::MAX`.
fn requested_fps(fps: i64) -> Option<u32> {
    (fps > 0).then(|| fps.min(i64::from(u32::MAX)) as u32)
}

#[cfg(test)]
#[path = "dispatch_tests.rs"]
mod tests;
