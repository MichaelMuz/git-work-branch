#!/usr/bin/env bash

# Test plan
#
# Choosing a branch:
# 1. If I pass s an arg:
# - branch doesn't exist: don't create branch and error
# - branch exists create worktree if not exists and echo dir where it is
# 2. If I pass no arg:
# - options should be piped into fzf in order, existing wt by zoxide rank, then recent commit local, then recent commit remote
# - can type something not in selection for branch creation
#
# Creation Mechanics:
# 1. We can create branches if they don't exist
# 2. We create worktrees if they don't exist
# - We error if that dir exists and not git dir
# - We error if that dir is a git dir but not this git repo
# - We error if that dir is on a different branch at the moment
# - We error if that branch is already checked out in a different worktree

set -eou pipefail

exit_with() {
    local msg="$1"
    echo "$msg" >&2
    exit 1
}

# set fake env vars for a clean slate
export WORKTREE_HOME _ZO_DATA_DIR # child process will need to see this
WORKTREE_HOME=$(mktemp -d)
_ZO_DATA_DIR=$(mktemp -d)
# consider overriding git config global, though this tool is for me so will test with mine
# can use containers to test later for maximum isolation

# make a fake upstream
repo1_remote=$(mktemp -d)/repo1_remote
mkdir -p "$repo1_remote"
cd "$repo1_remote" || exit_with "could not cd into $repo1_remote"
git init --bare

# set up the local git
root_repo1=$(mktemp -d)/repo1
mkdir -p "$root_repo1"
cd "$root_repo1" || exit_with "could not cd into $repo1_remote"
echo "this is code" >fakecode.txt
git init
git branch -M main
git add remote add origin "$(repo1_remote)"
git add fakecode.txt
git commit -m "first commit"
git push -u origin/main

create_branch() {
    local name="$1"
    git checkout -b "$name"
    echo "$name" >"$name".txt
    git add "$name".txt
    git commit -m "adding $name"
    git push -u origin/"$name"
}

# simulate an old remote only branch
create_branch old_remote_branch
git branch -d old_remote_branch

# simulate a newer remote only branch
create_branch newer_remote_branch
git branch -d newer_remote_branch

# older local branch
create_branch my_older_branch

# recentish local branch
create_branch my_recentish_branch

# recent local branch
create_branch my_recentish_branch

expected_repo1_worktree_home="$WORKTREE_HOME"/repo1_remote
git checkout main

create_worktree() {
    # makes worktree by passing our tool s <branch>, assumes using repo1

    local branch_name expected_wt_dir created_wt_dir actual_branch
    branch_name="$1"
    expected_wt_dir="$expected_repo1_worktree_home"/"$branch_name"
    created_wt_dir=$(./git-work-branch.sh s "$branch_name")
    test "$created_wt_dir" = "$expected_wt_dir" || exit_with "expected created wt at $expected_wt_dir but got $created_wt_dir"
    cd "$created_wt_dir" || exit_with "could not move to created first worktree dir" # as the tool wants us to do
    actual_branch="$(branch --show-current)"
    test "$actual_branch" = created_wt_branch || exit_with "expected branch called created_wt_branch but got $actual_branch"
    echo created_wt_dir
}

older_but_popular_wt="$(create_worktree old_but_popular_wt_branch)"
create_worktree new_but_unpopular_wt_branch >/dev/null

# make zoxide see that the new worktree dir is popular
for _ in {1..5}; do
    cd "$root_repo1" || exit_with "could not cd into $root_repo1"
    cd "$older_but_popular_wt" || exit_with "could not cd $created_wt_dir"
done

cd "$root_repo1" || exit_with "could not cd into $root_repo1"

fzf_out=$(mktmp)/fzf_out.txt
touch "$fzf_out"

fzf() {
    # output whatever they passed to fzf into our file, ignore any args, and exit their program
    cat >"$fzf_out"
    exit
}

export -f fzf
./git-work-branch.sh s
unexport -f fzf

diff -q "$fzf_out" <<EOF || exit_with "diff dumped"
older_but_popular_wt_branch
newer_but_unpopular_wt_branch
my_recent_branch
my_recentish_branch
my_older_branch
newer_remote_branch
old_remote_branch
EOF
