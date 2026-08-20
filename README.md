# Welcome to git work branch
The goal of this project is to provide a DWIM (Do what I mean) branch-oriented experience that abstracts away worktrees.

## Prerequisites

### Install [fzf](https://github.com/junegunn/fzf) 
Recommended config
``` sh
if command -v fzf &>/dev/null; then
    # catppuccin macchiato
    export FZF_DEFAULT_OPTS='
        --height=40%
        --layout=reverse
        --border=rounded
        --info=inline
        --color=fg:#cad3f5,bg:#24273a,hl:#ed8796,fg+:#cad3f5,bg+:#363a4f
        --color=hl+:#ed8796,info:#c6a0f6,prompt:#c6a0f6,pointer:#f4dbd6
        --color=marker:#f7e6e2,spinner:#f4dbd6,header:#ed8796,border:#5b6078
        --color=gutter:#363a4f'
fi
```
Can customize your colors using [this](https://junegunn.github.io/fzf/color-themes/) tool.
Replace all the lines that start with `--color` with the ones you prefer

### Install [zoxide](https://github.com/ajeetdsouza/zoxide)
Recommended config for zsh
``` sh
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"
```

### Install this tool
1. Clone this repo `git clone git@github.com:MichaelMuz/git-work-branch.git ~/.local/share/git-work-branch`
2. Add this to your `.zshrc`:
``` sh
gws() {
    local to_cd
    if to_cd="$("$HOME"/.local/share/git-work-branch/git-work-branch.sh s "$@")"; then
        cd "$to_cd"
    fi
}
```

### Customize worktree home
This env var decides where the worktrees should live. Each branch you create will be placed in this directory and named after the directory containing the main checkout. Ex: `~/.worktrees/my-repo/my-branch`. This defaults to `~/.worktrees`. Note that branches with `/` will get `-` instead.

To override where the worktrees live, in your shell config: `export WORKTREE_HOME="<custom-path>"`

## Usage
1. run `gws <branch-name>` to switch to an existing branch in a dedicated worktree
2. run `gws` for interactive mode where you can fuzzy find intelligently sorted git branches or type in a new one to create a new branch
3. selecting the main branch in any way will return you to the main checkout of the repo rather than a worktree
4. it will automatically try to clean up clean worktrees corresponding to branches that the remote would prune. `export GWP_DISABLED="true"` in your shell config to opt out of this behavior

## Staying up to date
When you want to update run `git -C ~/.local/share/git-work-branch pull`

## Similar projects
[worktrunk](https://github.com/max-sixty/worktrunk) - Helps with worktrees, many more features but less DWIM in nature. You still need to manage worktrees.

## Status
This project is a work in progress so you may encounter bugs. These are generally not destructive because the tool does not really delete anything, but it is something to keep in mind.

### Testing
- Test suite included
- Tested with zsh as the shell config (recommended setup instructions are generally zsh specific)
- Tested on gnu coreutils on linux (mac/bsd users may have compatibility issues with default utils)
