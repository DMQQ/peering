//! Google Play purchases: which plan a Play purchase buys, and what the relay does with a verdict.
//!
//! This is the pure half of the Play path. `play_api` asks Google whether a purchase is live and
//! turns the answer into a `PlayVerdict`; this module maps product identifiers to plans and decides
//! the plan a client is metered by. It mirrors `storekit`: a verdict that says the purchase is live
//! wins, and everything else ends at the free allowance unless the operator has opened the switch
//! that believes a client's own claim.

use std::collections::HashMap;

use crate::quota::Plan;
use crate::storekit::Trust;

/// Purchases one session may have checked against Google. Matches `storekit`'s receipt budget.
const MAX_PURCHASES_PER_SESSION: usize = 8;

/// A Play product this relay sells, and the plan it buys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlayProduct {
    id: String,
    plan: Plan,
}

impl PlayProduct {
    /// The plan a product identifier buys, or `None` for a product this relay does not sell.
    ///
    /// Pro is matched on the suffixes the store uses for its three Pro products, and on any
    /// identifier that carries `.pro.` inside it. Relay is matched on `.relay.`. Nothing else is a
    /// plan, so an unknown product can never be metered as unlimited.
    pub fn from_id(id: &str) -> Option<Self> {
        let plan = if [".pro.monthly", ".pro.year", ".pro.lifetime1"].iter().any(|suffix| id.ends_with(suffix))
            || id.contains(".pro.")
        {
            Plan::Pro
        } else if id.contains(".relay.") {
            Plan::Relay
        } else {
            return None;
        };
        Some(Self { id: id.to_owned(), plan })
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn plan(&self) -> Plan {
        self.plan
    }
}

/// Why a Play purchase buys nothing. The strings are the log's vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayRejection {
    /// The product identifier is not one this relay sells.
    UnknownProduct,
    /// The subscription has run out.
    Expired,
    /// Google refunded or revoked the purchase.
    Revoked,
    /// The purchase is bound to a different device key than the one presenting it.
    WrongDevice,
    /// Google reports the purchase as not completed, or as one that is not a purchase at all.
    NotAPurchase,
    /// Google could not be asked, or did not answer in time. Fails closed like every other refusal.
    Unavailable,
}

impl PlayRejection {
    /// The word for the log. Stable, lowercase, and safe to grep for.
    pub fn reason(self) -> &'static str {
        match self {
            Self::UnknownProduct => "unknown_product",
            Self::Expired => "expired",
            Self::Revoked => "revoked",
            Self::WrongDevice => "wrong_device",
            Self::NotAPurchase => "not_a_purchase",
            Self::Unavailable => "unavailable",
        }
    }
}

/// What Google said about one purchase, once it has been read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayVerdict {
    /// The purchase is live and buys this plan.
    Active(Plan),
    Rejected(PlayRejection),
}

/// The plan to meter by, how the relay came to it, and when a purchase was refused, why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlayResolved {
    pub plan: Plan,
    pub trust: Trust,
    pub rejected: Option<PlayRejection>,
}

/// Decides the plan for one connect. A live verdict wins outright, including downwards, as it does
/// for StoreKit. Without one, the client's own claim counts only when `trust_claims` is set, which
/// is the operator's beta switch; otherwise the free allowance.
pub fn resolve(trust_claims: bool, claimed: Plan, verdict: Option<PlayVerdict>) -> PlayResolved {
    match verdict {
        Some(PlayVerdict::Active(plan)) => PlayResolved { plan, trust: Trust::Verified, rejected: None },
        Some(PlayVerdict::Rejected(reason)) => fallback(trust_claims, claimed, Some(reason)),
        None => fallback(trust_claims, claimed, None),
    }
}

fn fallback(trust_claims: bool, claimed: Plan, rejected: Option<PlayRejection>) -> PlayResolved {
    if trust_claims && claimed != Plan::Free {
        PlayResolved { plan: claimed, trust: Trust::Claimed, rejected }
    } else {
        PlayResolved { plan: Plan::Free, trust: Trust::None, rejected }
    }
}

/// One session's Play verdicts, so a client cannot make the relay ask Google once per message.
///
/// Keyed on the purchase token together with the product it was presented for. A session may check
/// `MAX_PURCHASES_PER_SESSION` distinct purchases; after that `can_check` is false and the caller
/// resolves the connect without asking, which lands on the claim or the free allowance.
#[derive(Default)]
pub struct PlayReceiptCache {
    verdicts: HashMap<(String, String), PlayVerdict>,
}

impl PlayReceiptCache {
    pub fn seen(&self, purchase_token: &str, product_id: &str) -> Option<PlayVerdict> {
        self.verdicts
            .get(&(purchase_token.to_owned(), product_id.to_owned()))
            .copied()
    }

    /// Whether this session has budget left to ask Google about another purchase.
    pub fn can_check(&self) -> bool {
        self.verdicts.len() < MAX_PURCHASES_PER_SESSION
    }

    pub fn record(&mut self, purchase_token: &str, product_id: &str, verdict: PlayVerdict) {
        if self.can_check() {
            self.verdicts
                .insert((purchase_token.to_owned(), product_id.to_owned()), verdict);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REJECTIONS: [PlayRejection; 6] = [
        PlayRejection::UnknownProduct,
        PlayRejection::Expired,
        PlayRejection::Revoked,
        PlayRejection::WrongDevice,
        PlayRejection::NotAPurchase,
        PlayRejection::Unavailable,
    ];

    #[test]
    fn the_store_suffixes_are_pro() {
        for id in [
            "pl.dmq.peering.pro.monthly",
            "pl.dmq.peering.pro.year",
            "pl.dmq.peering.pro.lifetime1",
        ] {
            assert_eq!(PlayProduct::from_id(id).map(|p| p.plan()), Some(Plan::Pro), "{id}");
        }
    }

    #[test]
    fn any_identifier_carrying_pro_is_pro_and_relay_is_relay() {
        assert_eq!(PlayProduct::from_id("app.pro.extra").map(|p| p.plan()), Some(Plan::Pro));
        assert_eq!(PlayProduct::from_id("app.relay.hour").map(|p| p.plan()), Some(Plan::Relay));
    }

    #[test]
    fn anything_else_is_not_a_product_this_relay_sells() {
        for id in ["", "pl.dmq.peering.pro", "pl.dmq.peering.plus.monthly", "pro", "relay"] {
            assert!(PlayProduct::from_id(id).is_none(), "{id}");
        }
    }

    #[test]
    fn a_live_purchase_buys_its_plan_and_is_verified() {
        let resolved = resolve(false, Plan::Free, Some(PlayVerdict::Active(Plan::Pro)));
        assert_eq!(resolved, PlayResolved { plan: Plan::Pro, trust: Trust::Verified, rejected: None });
    }

    #[test]
    fn a_live_purchase_wins_over_a_claim_in_either_direction() {
        let down = resolve(true, Plan::Pro, Some(PlayVerdict::Active(Plan::Relay)));
        assert_eq!(down.plan, Plan::Relay);
        assert_eq!(down.trust, Trust::Verified);
    }

    #[test]
    fn with_no_verdict_and_the_switch_closed_the_client_is_free() {
        let resolved = resolve(false, Plan::Pro, None);
        assert_eq!(resolved, PlayResolved { plan: Plan::Free, trust: Trust::None, rejected: None });
    }

    #[test]
    fn every_rejection_ends_at_free_while_the_switch_is_closed() {
        for reason in REJECTIONS {
            let resolved = resolve(false, Plan::Pro, Some(PlayVerdict::Rejected(reason)));
            assert_eq!(resolved.plan, Plan::Free, "{reason:?}");
            assert_eq!(resolved.trust, Trust::None, "{reason:?}");
            assert_eq!(resolved.rejected, Some(reason));
        }
    }

    #[test]
    fn with_the_switch_open_a_rejected_purchase_falls_back_to_the_claim() {
        let resolved = resolve(true, Plan::Relay, Some(PlayVerdict::Rejected(PlayRejection::Expired)));
        assert_eq!(resolved.plan, Plan::Relay);
        assert_eq!(resolved.trust, Trust::Claimed);
        assert_eq!(resolved.rejected, Some(PlayRejection::Expired));
    }

    #[test]
    fn a_free_claim_is_not_a_claim_even_with_the_switch_open() {
        let resolved = resolve(true, Plan::Free, None);
        assert_eq!(resolved.trust, Trust::None);
    }

    #[test]
    fn each_rejection_has_a_greppable_reason() {
        let reasons: Vec<&str> = REJECTIONS.iter().map(|r| r.reason()).collect();
        assert_eq!(
            reasons,
            ["unknown_product", "expired", "revoked", "wrong_device", "not_a_purchase", "unavailable"]
        );
    }

    #[test]
    fn the_same_purchase_for_the_same_product_is_remembered() {
        let mut cache = PlayReceiptCache::default();
        assert!(cache.seen("tok", "pl.dmq.peering.pro.year").is_none());
        cache.record("tok", "pl.dmq.peering.pro.year", PlayVerdict::Active(Plan::Pro));
        assert_eq!(
            cache.seen("tok", "pl.dmq.peering.pro.year"),
            Some(PlayVerdict::Active(Plan::Pro))
        );
    }

    #[test]
    fn the_same_token_for_another_product_is_a_different_question() {
        let mut cache = PlayReceiptCache::default();
        cache.record("tok", "pl.dmq.peering.pro.year", PlayVerdict::Active(Plan::Pro));
        assert!(cache.seen("tok", "pl.dmq.peering.relay.hour").is_none());
    }

    #[test]
    fn a_session_may_check_only_so_many_purchases() {
        let mut cache = PlayReceiptCache::default();
        for n in 0..MAX_PURCHASES_PER_SESSION {
            assert!(cache.can_check());
            cache.record(&format!("tok-{n}"), "pl.dmq.peering.pro.year", PlayVerdict::Rejected(PlayRejection::Expired));
        }
        assert!(!cache.can_check());
        cache.record("one-more", "pl.dmq.peering.pro.year", PlayVerdict::Active(Plan::Pro));
        assert!(cache.seen("one-more", "pl.dmq.peering.pro.year").is_none());
    }
}
