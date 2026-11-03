use super::*;

fn strings(list: &[&str]) -> Vec<String> {
    list.iter().map(|item| (*item).to_owned()).collect()
}

fn tracking(head: &str, remote: &str, merge_ref: &str) -> AgentGitBranch {
    AgentGitBranch {
        head: Some(head.to_owned()),
        upstream: Some(format!("{remote}/{head}")),
        remote: Some(remote.to_owned()),
        merge_ref: Some(merge_ref.to_owned()),
        ahead: 1,
        behind: 0,
    }
}

#[test]
fn a_commit_stages_and_commits_the_unique_paths_after_a_double_dash() {
    let plan = commit_plan(&strings(&["a.txt", "-rf", "a.txt"]), "  Fix it \n").expect("a plan");
    assert_eq!(plan.stage, strings(&["--literal-pathspecs", "add", "--", "a.txt", "-rf"]));
    assert_eq!(plan.commit, strings(&["--literal-pathspecs", "commit", "-m", "Fix it", "--", "a.txt", "-rf"]));
}

#[test]
fn a_commit_is_refused_for_each_unsafe_input() {
    assert_eq!(commit_plan(&[], "m"), Err(GitRefusal::NoFiles));
    assert_eq!(commit_plan(&strings(&["a"]), "  "), Err(GitRefusal::EmptyMessage));
    assert_eq!(commit_plan(&strings(&["a"]), &"x".repeat(5_001)), Err(GitRefusal::MessageTooLong));
    let many: Vec<String> = (0..1_001).map(|n| n.to_string()).collect();
    assert_eq!(commit_plan(&many, "m"), Err(GitRefusal::TooManyFiles));
    for bad in ["../up", ".git/config", "sub/.GIT/hooks", "C:/x", "a\\..\\b", "/abs"] {
        assert_eq!(commit_plan(&strings(&[bad]), "m"), Err(GitRefusal::UnsafePath(bad.to_owned())), "{bad}");
    }
}

#[test]
fn the_status_header_gives_head_upstream_and_counts() {
    let status = "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +3 -1\n";
    let found = branch(status, Some("origin\n"), Some("refs/heads/main")).expect("a branch");
    assert_eq!(found, AgentGitBranch { ahead: 3, behind: 1, ..tracking("main", "origin", "refs/heads/main") });
}

#[test]
fn a_detached_head_has_no_branch_name_and_cannot_push() {
    let found = branch("# branch.oid abc\n# branch.head (detached)\n", None, None).expect("a branch");
    assert_eq!(found.head, None);
    assert_eq!(push_arguments(&found), Err(GitRefusal::DetachedHead));
    assert_eq!(branch("not a status", None, None), None);
}

#[test]
fn a_push_names_an_explicit_refspec_and_no_widening_flag() {
    let arguments = push_arguments(&tracking("feature/x", "origin", "refs/heads/main")).expect("arguments");
    assert_eq!(arguments, strings(&["push", "--no-follow-tags", "origin", "refs/heads/feature/x:refs/heads/main"]));
}

#[test]
fn a_push_is_refused_for_odd_names_and_a_missing_upstream() {
    assert_eq!(push_arguments(&tracking("+main", "origin", "refs/heads/main")), Err(GitRefusal::UnsafeBranch));
    assert_eq!(push_arguments(&tracking("main", "-f", "refs/heads/main")), Err(GitRefusal::UnsafeRemote));
    assert_eq!(push_arguments(&tracking("main", "a/b", "refs/heads/main")), Err(GitRefusal::UnsafeRemote));
    assert_eq!(push_arguments(&tracking("main", "origin", "refs/tags/v1")), Err(GitRefusal::UnsafeBranch));
    let unset = AgentGitBranch { upstream: None, ..tracking("main", "origin", "refs/heads/main") };
    assert_eq!(push_arguments(&unset), Err(GitRefusal::NoUpstream));
}
