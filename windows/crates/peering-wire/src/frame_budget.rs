//! The documented 64 KiB control payload rule, as a budget a sender can fit a list into.

use serde::Serialize;

/// Encoded bytes a list may take inside one control frame, leaving room for the fields around it.
pub const CONTROL_LIST_BUDGET: usize = 56 * 1024;

/// The longest prefix of `items` whose JSON array fits in `budget` bytes, and whether anything was left out.
pub fn longest_prefix<T: Serialize>(mut items: Vec<T>, budget: usize) -> (Vec<T>, bool) {
    let mut used = 2;
    let mut keep = 0;
    for item in &items {
        let size = serde_json::to_vec(item).map_or(0, |encoded| encoded.len()) + 1;
        if used + size > budget {
            break;
        }
        used += size;
        keep += 1;
    }
    let cut = keep < items.len();
    items.truncate(keep);
    (items, cut)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn everything_that_fits_is_kept_and_nothing_is_reported_cut() {
        let (kept, cut) = longest_prefix(vec!["a", "b"], 100);
        assert_eq!(kept, ["a", "b"]);
        assert!(!cut);
    }

    #[test]
    fn the_prefix_ends_before_the_item_that_would_pass_the_budget() {
        let items: Vec<String> = (0..100).map(|_| "x".repeat(98)).collect();
        let (kept, cut) = longest_prefix(items, 1_000);
        assert!(cut);
        assert!(serde_json::to_vec(&kept).expect("a list serialises").len() <= 1_000);
        assert_eq!(kept.len(), 9);
    }
}
