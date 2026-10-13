//! Order in which encoder MFTs are tried: hardware before software, and within each, the ones that take a D3D11
//! texture first (the pipeline never copies frames through system memory, so only those can be used).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CandidateInfo {
    pub hardware: bool,
    pub d3d11_aware: bool,
}

/// Indices into `candidates`, best first. The sort is stable, so enumeration order breaks ties.
pub fn rank_candidates(candidates: &[CandidateInfo]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..candidates.len()).collect();
    order.sort_by_key(|&index| (!candidates[index].hardware, !candidates[index].d3d11_aware));
    order
}
