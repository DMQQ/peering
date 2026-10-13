//! Where the keyboard focus is on the PC, as UI Automation reports it.

/// The element that has the keyboard focus, and what it holds if it takes typing.
#[derive(Debug, Clone, PartialEq)]
pub struct FocusSnapshot {
    /// The same number for as long as the focus stays on the same element.
    pub element: u64,
    pub editable: bool,
    pub secure: bool,
    /// The focus is in a terminal, whose one text area is its whole screen and not something to mirror.
    pub terminal: bool,
    pub text: Option<String>,
    /// Start and length of the selection, in UTF-16 units. `None` when the element cannot say.
    pub selection: Option<(u32, u32)>,
    /// The middle of the line the insertion point is on, in desktop pixels.
    pub caret: Option<(f64, f64)>,
}

/// What a look at the focus found, or what a tap on the screen landed on.
#[derive(Debug, Clone, PartialEq)]
pub enum FocusReport {
    /// The element with the focus now, or `None` when nothing has it.
    Focus(Option<FocusSnapshot>),
    /// A tap landed on an element that takes typing, or on one that does not.
    Tapped { editable: bool },
}

pub trait FocusProbe {
    /// Starts or stops watching. Idempotent. Watching is not free, so it runs only while a phone wants to know.
    fn set_active(&mut self, active: bool);

    /// Asks what is at a desktop pixel, a moment from now. The answer comes back through `drain` as `Tapped`.
    fn tapped_at(&mut self, x: i32, y: i32);

    /// What was found since the last call, oldest first. Never blocks, and repeats nothing: a focus that did not change is
    /// not reported again.
    fn drain(&mut self) -> Vec<FocusReport>;
}
