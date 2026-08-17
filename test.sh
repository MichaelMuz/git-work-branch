#!/usr/bin/env bash

# Test plan
#
# UX:
# 1. If I pass s an arg:
# a: branch doesn't exist: don't create branch and error
# b: branch exists create worktree if not exists and echo dir where it is
# 2. If I pass no arg:
# a: options should be piped into fzf in order, existing wt by zoxide rank, then recent commit local, then recent commit remote
# b: can type something not in selection for branch creation
#
# Concrete edgecases:
# 3. Branch edgecases:
# a. branch is already worktree
# b. branch is already local but not worktree
# c. branch is remote
# d. branch doesn't exist
# 4. Worktree edgecases:
# a. We create worktrees if they don't exist
# b. We create worktrees if the dir collides with an empty non-git dir
# c. We error if that dir is a git dir but not this git repo
# d. We error if that dir is on a different branch at the moment
# e. We error if that branch is already checked out in a different worktree

set -eou pipefail

# for debugging
# set -x
# PS4='T${LINENO}: '

exit_with() {
    local msg="$1"
    echo "$msg" >&2
    exit 1
}

cd() {
    # shadows cd, a real config would have zoxide hook plugged into the shell directly

    builtin cd "$@"
    zoxide add -- "$(pwd)"
}

# we expect the script we are testing to be a sibling in the same dir as us
git_work_branch_script_dir="$(dirname "$(realpath "$0")")"
export dbgfile="$git_work_branch_script_dir/dbg.txt"
echo -n "" >"$dbgfile"

dbg() {
    echo "$1" >>"$dbgfile" 2>&1
}

git_work_branch() {
    "$git_work_branch_script_dir"/git-work-branch.sh "$@"

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
git -C "$repo1_remote" init --bare --quiet

# set up the local git
root_repo1=$(mktemp -d)/repo1
mkdir -p "$root_repo1"
cd "$root_repo1" || exit_with "could not cd into $repo1_remote"
echo "this is code" >fakecode.txt
git init --quiet
git branch -M main --quiet
git remote add origin "$repo1_remote"
git add fakecode.txt
git commit -m "first commit" --quiet
git push -u origin --quiet

create_branch() {
    local name="$1"
    dbg "create branch with $name"

    git checkout -b "$name" --quiet
    echo "$name" >"$name".txt
    git add "$name".txt
    git commit -m "adding $name" --quiet
    git push -u origin --quiet
    git checkout main --quiet
}

# create branches we will make into worktrees and manipulate their zoxide popularity to test sorting
create_branch old_but_popular_wt_branch
create_branch new_but_unpopular_wt_branch

# simulate an old remote only branch
create_branch old_remote_branch
git branch -d old_remote_branch --quiet 2>/dev/null # warns bc branch pointed to commit that was not merged to main, but -d deletes bc in origin refs

# simulate a newer remote only branch
create_branch newer_remote_branch
git branch -d newer_remote_branch --quiet 2>/dev/null # warns bc branch pointed to commit that was not merged to main, but -d deletes bc in origin refs

# older local branch
create_branch my_older_branch

# recentish local branch
create_branch my_recentish_branch

# recent local branch
create_branch my_recent_branch

expected_repo1_worktree_home="$WORKTREE_HOME"/repo1_remote

create_worktree() {
    # makes worktree by passing our tool s <branch>, assumes using repo1

    local branch_name expected_wt_dir created_wt_dir actual_branch
    branch_name="$1"
    dbg "create worktree with $branch_name"

    expected_wt_dir="$expected_repo1_worktree_home"/"$branch_name"
    created_wt_dir=$(git_work_branch s "$branch_name")
    test "$created_wt_dir" = "$expected_wt_dir" || exit_with "expected created wt at $expected_wt_dir but got $created_wt_dir"
    cd "$created_wt_dir" || exit_with "could not move to created first worktree dir" # as the tool wants us to do
    actual_branch="$(branch --show-current)"
    test "$actual_branch" = created_wt_branch || exit_with "expected branch called created_wt_branch but got $actual_branch"
    echo created_wt_dir
}

# 1a: try to create a branch new branch with arg
if output="$(create_worktree non-existant-branch 2>&1 1>/dev/null)"; then
    exit_with "We should refuse to create branch on arg"
elif [ "$output" != "explicit arg passed but branch not found - arg cannot create" ]; then
    exit_with "Unexpected error message when creating branch on arg: $output"
fi

# 1b: Creates worktree from arg using existing branch, should work
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

fzf_chooses_new_but_unpopular_wt_branch() {
    cat >"$fzf_out"
    fzf "$@" --filter new_but_unpopular_wt_branch
}

export -f fzf=fzf_chooses_new_but_unpopular_wt_branch
test "$(./git-work-branch.sh s)" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/new_but_unpopular_wt_branch
unexport -f fzf

# 2a: correct order piped into fzf
diff -q "$fzf_out" <<EOF || exit_with "diff dumped"
older_but_popular_wt_branch
newer_but_unpopular_wt_branch
my_recent_branch
my_recentish_branch
my_older_branch
newer_remote_branch
old_remote_branch
EOF

# 3a: branch is already worktree
fzf_chooses_newer_but_unpopular_wt_branch() {
    cat >"$fzf_out"
    fzf "$@" --filter fzf_chooses_newer_but_unpopular_wt_branch
}

export -f fzf=fzf_chooses_newer_but_unpopular_wt_branch
to_cd="$(./git-work-branch.sh s)"
test "$to_cd" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/fzf_chooses_newer_but_unpopular_wt_branch
test "$(git -C "$to_cd" branch --show-current)" = fzf_chooses_newer_but_unpopular_wt_branch
unexport -f fzf

# 3b: branch is local but not worktree
fzf_chooses_my_recentish() {
    cat >"$fzf_out"
    fzf "$@" --filter my_recentish_branch
}

export -f fzf=fzf_chooses_my_recentish
to_cd="$(./git-work-branch.sh s)"
test "$to_cd" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/my_recentish_branch
test "$(git -C "$to_cd" branch --show-current)" = my_recentish_branch
unexport -f fzf

# 3c: branch is remote
fzf_chooses_old_remote_branch() {
    cat >"$fzf_out"
    fzf "$@" --filter old_remote_branch
}

# 2b: can type in a branch that never existed and it gets created along with the worktree it needs
export -f fzf=fzf_chooses_old_remote_branch
to_cd="$(./git-work-branch.sh s)"
test "$to_cd" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/old_remote_branch
test "$(git -C "$to_cd" branch --show-current)" = old_remote_branch
unexport -f fzf

# 2b+3d: branch doesn't exist but we type it into fzf and it gets made along with its worktree
fzf_chooses_new() {
    cat >"$fzf_out"
    fzf "$@" --filter brand_new_branch
}

export -f fzf=fzf_chooses_new
to_cd="$(./git-work-branch.sh s)"
test "$to_cd" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/brand_new_branch
test "$(git -C "$to_cd" branch --show-current)" = brand_new_branch
unexport -f fzf

# 4a has already been demonstrated many times above bc if a branch didn't exist locallly then the worktree def didn't

# 4b: ok to make worktree on existing dir if empty
existing_but_empty="$WORKTREE_HOME"/"$expected_repo1_worktree_home"/existing_but_empty
mkdir -p "$existing_but_empty"
fzf_chooses_existing_but_empty() {
    cat >"$fzf_out"
    fzf "$@" --filter existing_but_empty
}

export -f fzf=fzf_chooses_existing_but_empty
to_cd="$(./git-work-branch.sh s)"
test "$to_cd" = "$WORKTREE_HOME"/"$expected_repo1_worktree_home"/existing_but_empty
test "$(git -C "$to_cd" branch --show-current)" = existing_but_empty
unexport -f fzf

# 4b: errors if we try to make worktree in occupied non-git dir
existing_but_occupied="$WORKTREE_HOME"/"$expected_repo1_worktree_home"/existing_but_empty
mkdir -p "$existing_but_occupied"
touch "$existing_but_occupied/some_file.txt"
fzf_chooses_existing_but_occupied() {
    cat >"$fzf_out"
    fzf "$@" --filter existing_but_occupied
}

export -f fzf=fzf_chooses_existing_but_occupied
if out="$(./git-work-branch.sh s 2>&1)"; then
    exit_with "expected to fail on attempt to create worktree in occupied dir"
elif [ "$out" == "$existing_but_occupied is not empty!" ]; then
    echo "got unexpected failure message :$out: when attempting to create in occupied dir"
fi
unexport -f fzf

# 4c: error if dir has git but from a different repo
existing_but_occupied_git_dir="$WORKTREE_HOME"/"$expected_repo1_worktree_home"/existing_but_empty
mkdir -p "$existing_but_occupied_git_dir"
touch "$existing_but_occupied_git_dir/some_file.txt"
fzf_chooses_existing_but_occupied_git_dir() {
    cat >"$fzf_out"
    fzf "$@" --filter existing_but_occupied_git_dir
}

export -f fzf=fzf_chooses_existing_but_occupied_git_dir
if out="$(./git-work-branch.sh s 2>&1)"; then
    exit_with "expected to fail on attempt to create worktree in foreign repo"
elif [ "$out" == "Foreign repo at $existing_but_occupied_git_dir" ]; then
    echo "got unexpected failure message :$out: when attempting to create in occupied dir"
fi
unexport -f fzf

# 4d: errors if we try to make worktree in a dir that has a different branch from our repo in it - like if a user manually messed with branch in a worktree
invaded_wt_dir="$WORKTREE_HOME"/"$expected_repo1_worktree_home"/branch_that_belongs
mkdir -p "$invaded_wt_dir"
git branch invader_branch
git worktree add --quiet "$invaded_wt_dir" invader_branch

fzf_chooses_branch_that_belongs() {
    cat >"$fzf_out"
    fzf "$@" --filter branch_that_belongs
}

export -f fzf=fzf_chooses_branch_that_belongs
if out="$(./git-work-branch.sh s 2>&1)"; then
    exit_with "expected to fail on attempt to create worktree in dir that has a different branch checked out already"
elif [ "$out" == "existing branch invader_branch at $invaded_wt_dir cannot place branch_that_belongs" ]; then
    echo "got unexpected failure message :$out: when attempting to create in occupied dir"
fi
unexport -f fzf

# 4e: try to check out a branch that is already checked out in a different worktree
if out="$(./git-work-branch.sh s invader_branch 2>&1)"; then
    exit_with "expected to fail on attempt to create worktree with branch checked out in another worktree"
elif [ "$out" == "fatal: 'both-zsh' is already used by worktree at \'$invaded_wt_dir\'" ]; then
    echo "got unexpected failure message :$out: when attempting to create in occupied dir"
fi
