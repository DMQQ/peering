/// A list beside its detail pane: a row the list opens replaces what the pane shows rather than stacking over it.
public enum SidebarSelection {
    /// `proposed` is what the list asked for. One step pushed on top of `current` becomes the pane's only page; any other change (a pop, a pane's own edit) stands.
    public static func detailPath<Step: Equatable>(current: [Step], proposed: [Step]) -> [Step] {
        guard proposed.count == current.count + 1,
              Array(proposed.prefix(current.count)) == current,
              let selected = proposed.last
        else { return proposed }
        return [selected]
    }
}
