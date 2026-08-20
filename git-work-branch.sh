#!/usr/bin/env bash

set -eou pipefail

# for debugging
# set -x
# PS4='S${LINENO}: '

# A simpler DWIM version of https://worktrunk.dev

# Overarching rule: we only care about branches and worktrees are invisible.
#
# Non-Command choices:
# - this program will output a dir that the caller should cd into in their interactive shell on exit 0
# - worktrees live in $WORKTREE_PARKING_LOT/<parent-repo-name>/branch-name (will think about how to deal with conflicts like that already exists later, will just error for now)
#
# Commands:
# - gwa: add a git worktree branch (2nd least commonly used - primarily used by passing the branch name to create)
#   - takes branch arg, no arg prompts
#   - if branch and worktree exist and go there
#   - if branch exists but worktree doesn't, make worktree and go there
#   - if neither exist create both and go there
# - gwr: add a git worktree branch (least commonly used - the prune is more dwim and you get to not care about worktrees)
#   - takes a branch arg for which worktree to remove
#   - if in worktree, no arg removes current one and goes to main checkout
#   - if in main checkout, no arg while in main checkout opens fzf to pick which to remove
#   - will prob not delete branches at first
# - gws: switch to a git worktree branch (most commonly used - can add and switch)
#   - takes a branch arg, no arg prompts with fzf of all available branches (branches with existing worktrees prioritized (bc likely mru) or maybe just a mru behavior? Can choose remote branches)
#   - if in fzf can choose some default/new option and will create
#   - if arg option can never create, just errors. (don't do a fancy thing like fzf correction prompt for now)
#   - sorting the picker: We want to sort by worktree branches, then local branches (not showing ones already seen in worktrees), then remote branches (not showing ones already seen in worktrees or local)
#     within worktrees we want to ideally sort by last use, we could keep a list to the side of latest used ones but that is annoying.
#     can try .git/worktrees/<name>/index of the main checkout bc that file's time gets updated whenever git acts in that dir but isn't touched by just cd into it to look at it or editing files without talking to git
#     can ask zoxide to rank the worktree dirs we have, it has a nice algo that I won't reinvent here
#     I think best we get for local and remote branches is commit time unless we want to have some on the side table but that doesn't seem worth it. .git/worktrees/<name>/index is per worktree so also doesn't help
# - gwp: prune worktrees (not sure if commonly used manually but ideally commonly used on some hooks/timers to automatically clean up)
#   - cleans up branches that have already merged (remote doesn't have that branch kinda matching the git command that lets you pull in remote branch deletions) and the worktrees associated with them
#   - can act either on single repo or on all known repos
#   - known repos: the worktree parking lot acts as a list of all repos so collect each parking lot repo and act on those as a list of all known repos
#       - Can maybe collect a list of all repos our commands have ever acted on but parking lot is enough for now
#   - likely mostly useful to just do a global cleanup
#   - will prob not delete branches at first
#   - teleports to main checkout if deleted your dir
#
# Misc practicality:
# - Existing scattered worktrees annoyed me when I started using this tool so now if my branch is in some random worktree I just move it to where it should be
#
# Constraints:
# - This is a personal tool so I just don't support some things like:
#   - repo/worktree paths containing whitespace
#   - moving worktrees that have submodules

exit_with() {
    local msg="$1"
    echo "$msg" >&2
    exit 1
}

# set this in calling process to get a debug file
dbgfile=${dbgfile:-""}
dbg() {
    { test -n "$dbgfile" && echo "$1" >>"$dbgfile" 2>&1; } || true
}

WORKTREE_HOME=${WORKTREE_HOME:-"$HOME/.worktrees"}

# TODO currently we assume a remote exists but it may not
remote_default_branch() {
    # gets the default branch we should base off of

    local local_default remote_default
    local_default="$(git branch --list --format='%(refname:short)' main master | head -1)"
    remote_default="origin/${local_default}"
    {
        test -n "$local_default" && git branch --list -r "${remote_default}" | wc -l | xargs -I{} test {} -gt 0
    } || exit_with "unable to determine main branch" >&2

    echo "$remote_default"
}

ranked_branches() {
    # get the branches of this repo in the order we should display them to the user

    local highest_ranked_wts other_wts ordered_wt_branches local_branches remote_branches ordered_branches

    # get highest ranked zoxide dirs that are also this repos worktrees
    highest_ranked_wts="$(zoxide query -l | grep "$(git worktree list | awk '{print $1}')")"
    dbg "highest_ranked_wts:"
    dbg "$highest_ranked_wts"

    # get other worktree dirs
    other_wts="$(git worktree list | awk '{print $1}' | grep -Fxv "$highest_ranked_wts")"
    dbg "other_wts:"
    dbg "$other_wts"

    ordered_wt_branches=$(printf "%s\n%s\n" "${highest_ranked_wts}" "${other_wts}" | xargs -I{} git -C {} branch --show-current)
    dbg "ordered_wt_branches:"
    dbg "$ordered_wt_branches"

    # get branches from repo sorted by name and committerdate (last sort wins so date is most important)
    local_branches="$(git for-each-ref --sort='refname:short' --sort '-committerdate' --format='%(refname:short)' refs/heads)"
    dbg "local_branches:"
    dbg "$local_branches"
    # sort remote the same but dedup against local branches
    remote_branches="$(git for-each-ref --sort='refname:short' --sort '-committerdate' --format='%(refname)' refs/remotes | sed 's|refs/remotes/origin/||')"
    dbg "remote_branches:"
    dbg "$remote_branches"

    ordered_branches=""
    for v in "$ordered_wt_branches" "$local_branches" "$remote_branches"; do
        ordered_branches=$(printf "%s\n%s\n" "$ordered_branches" "$(grep -Fxv "$ordered_branches" <<<"$v")" | sed -n '/^[^[:space:]]/p')
    done

    ordered_branches=$(echo "$ordered_branches" | grep -Fxv "$(printf 'HEAD\n')")

    dbg "ordered_branches:"
    dbg "$ordered_branches"

    echo "$ordered_branches"

}

gws() {
    # takes a branch arg, no arg prompts with fzf of all available branches in a worktree

    local branch fzf_out status
    branch="${1:-}"
    dbg "will gws with $branch"

    if [ -n "$branch" ]; then
        # explicit arg cannot create so error if they passed it and we can't find it
        { git branch --list -a --format='%(refname:short)' "$branch" "origin/$branch" | wc -l | xargs -I{} test {} -gt 0; } || exit_with "explicit arg passed but branch not found - arg cannot create"
        dbg "found passed branch $branch"
    else
        # have fzf let them find or create if no arg was passed, fzf will exit 1 if typed but not chosen so we make it in that case
        # --print-query always returns the thing the user typed first line then the matches in next lines
        # we take tail line bc either 1 and they didn't match and we have the thing they typed or 0 they matched and what they typed is not relevant
        if fzf_out=$(ranked_branches | fzf --print-query | tail -1 | sed 's/^origin\///'); then
            dbg "user used fzf to choose existing branch $branch"
        else
            status=$? # our status will be that of fzf. Ctr-c makes fzf exit with 130 for example. Must be in else bc ! changes $?
            if [ "$status" -gt 128 ]; then return "$status"; fi

            git branch --quiet "$fzf_out" "$(remote_default_branch)"
            dbg "user used fzf to create new branch $branch"
        fi
        branch="$fzf_out"
    fi

    dbg "settled: branch=$branch"

    local main_repo_path main_repo_name new_worktree_path in_git_repo existing_wt
    main_repo_path="$(git worktree list | head -1 | awk '{print $1}')" # first worktree is always shared checkout
    main_repo_name="$(basename "$main_repo_path")"
    new_worktree_path="${WORKTREE_HOME}/${main_repo_name}/$(echo "$branch" | sed 's/\//-/g')"
    dbg "main_repo_name=$branch new_worktree_path=$new_worktree_path"

    if [ "origin/$branch" = "$(remote_default_branch)" ]; then
        test "$(git -C "$main_repo_path" branch --show-current)" = "$branch" || { test -z "$(git -C "$main_repo_path" status --porcelain)" && git -C "$main_repo_path" checkout "$branch" --quiet; } || exit_with "default branch chosen but default checkout is on another branch!"
        echo "$main_repo_path"
        return 0
    fi

    mkdir -p "$new_worktree_path"

    (
        if [ -n "$(ls -A "$new_worktree_path")" ]; then
            if ! in_git_repo="$(git -C "$new_worktree_path" rev-parse --is-inside-work-tree --quiet 2>/dev/null)" || [ "$in_git_repo" != "true" ]; then
                exit_with "$new_worktree_path is not empty!"
            elif ! other_main_repo_path="$(git -C "$new_worktree_path" worktree list | head -1 | awk '{print $1}')"; then
                exit_with "unexpected error getting other main repo path"
            elif [ "$main_repo_path" != "$other_main_repo_path" ]; then
                exit_with "Foreign repo at $new_worktree_path"
            elif ! other_repo_branch="$(git -C "$new_worktree_path" branch --show-current)"; then
                exit_with "Unexpected failure to get current branch at $new_worktree_path"
            elif [ "$other_repo_branch" != "$branch" ]; then
                exit_with "existing branch $(git -C "$new_worktree_path" branch --show-current) at $new_worktree_path, cannot place $branch"
            fi
        elif existing_wt="$(git for-each-ref --format '%(worktreepath)' refs/heads/"$branch")" && [ -n "$existing_wt" ]; then
            rmdir "$new_worktree_path" # rmdir fails on non-empty so safe and we know it is empty here. Needed bc below move command will keep mv semantics an nest itself if this exists
            git worktree move "$existing_wt" "$new_worktree_path"
        else
            # create worktree if not exist, let git complain if that branch is already checked out elsewhere
            git worktree add --quiet "$new_worktree_path" "$branch"
        fi
    )

    dbg "gonna echo new_worktree_path=$new_worktree_path"

    # echo where caller should cd into and return successfully
    echo "$new_worktree_path"
}

{ test "$#" -lt 1 || test "$#" -gt 2; } && exit_with "expected 1 <= args <= 2 but got $#: $*"

# this script technically takes the arg s, a, or r. Expect to be aliased as gws for convenience
first_script_arg="$1"
shift
if [ "$first_script_arg" = "s" ]; then
    gws "$@"
    exit 0
elif [ "$first_script_arg" = "a" ]; then
    exit_with "Not implemented yet"
elif [ "$first_script_arg" = "r" ]; then
    exit_with "Not implemented yet"
else
    exit_with "Unrecognized command"
fi
