
# Auto-start tmux (skip with NO_TMUX=1 zsh)
if [[ -z "$TMUX" && -z "$NO_TMUX" && -t 0 ]]; then
  exec tmux new-session -A -s loops
fi

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

eval "$(starship init zsh)"

alias kcup="kubectl config use-context production"
alias kcus="kubectl config use-context staging"
alias zconfig="nvim ~/.zshrc"
alias zsource='(cd ~/.dotfiles && git add -A && git commit -m "Update dotfiles"; git push); source ~/.zshrc'
alias check="aws-vault exec prod -- ./scripts/check-suppression-list.sh"
alias db="task db:port_forward"
alias db:rw="task db:port_forward:rw"
alias refresh="rm -fr .next node_modules && task dev"
alias docs="cd ~/coding/docs && mintlify dev"

ppl() {
    local current_branch=$(git branch --show-current)
    
    echo "Pushing branch '$current_branch' to phil-loops GitHub..."
    
    # Add phil-loops GitHub remote if it doesn't exist
    if ! git remote | grep -q "^phil-loops$"; then
        echo "Adding phil-loops remote..."
        git remote add phil-loops git@github.com:phil-loops/loops.git
    fi
    
    # Push directly to phil-loops GitHub remote
    git push phil-loops HEAD:$current_branch
    
    echo "Done! Branch '$current_branch' pushed to phil-loops"
}

opl() {
    local current_branch=$(git branch --show-current)
    
    echo "Opening phil-loops branch '$current_branch' on GitHub..."
    open "https://github.com/phil-loops/loops/tree/$current_branch"
}

oplpr() {
    local current_branch=$(git branch --show-current)
    local base_branch=${1:-main}

    echo "Opening PR comparison for '$current_branch' against '$base_branch' on phil-loops..."
    open "https://github.com/phil-loops/loops/compare/${base_branch}...phil-loops:loops:${current_branch}"
}

loops() {
    local cmd=$1
    shift

    case "$cmd" in
        stack)
            node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts "$@"
            ;;
        pr-review)
            _loops_pr_review "$@"
            ;;
        clean-migrations)
            _loops_clean_migrations "$@"
            ;;
        *)
            echo "Usage: loops <command>"
            echo ""
            echo "Commands:"
            echo "  stack             Manage git branch stacks"
            echo "  pr-review         Review PRs assigned to you"
            echo "  clean-migrations  Remove empty migration folders"
            ;;
    esac
}

_loops_clean_migrations() {
    local migrations_dir="prisma/migrations"

    if [[ ! -d "$migrations_dir" ]]; then
        echo "No prisma/migrations directory found"
        return 1
    fi

    local removed=0
    for dir in "$migrations_dir"/*/; do
        [[ ! -d "$dir" ]] && continue
        # Check if directory is empty (no files, only maybe subdirs)
        if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
            echo "Removing empty: $dir"
            rmdir "$dir"
            ((removed++))
        fi
    done

    if [[ $removed -eq 0 ]]; then
        echo "No empty migration folders found"
    else
        echo "Removed $removed empty folder(s)"
    fi
}

_loops_pr_review() {
    local cache_dir=$(mktemp -d)
    trap "rm -rf $cache_dir" EXIT

    local pr=$(gh pr list --repo loops-so/loops --search "review-requested:@me" \
        --json number,title,headRefName,author,updatedAt \
        --template '{{range .}}{{.number}}	{{.author.login}}	{{timeago .updatedAt}}	{{.title}}	{{.headRefName}}{{"\n"}}{{end}}' \
        | fzf --delimiter='\t' --with-nth=1,2,3,4 \
            --preview "f=$cache_dir/{1}.txt; [[ -s \$f ]] && cat \$f || { out=\$(gh pr view --repo loops-so/loops {1} && echo '' && echo '───── Files Changed ─────' && gh pr diff --repo loops-so/loops {1} --stat); [[ -n \"\$out\" ]] && echo \"\$out\" | tee \$f || echo 'Loading...'; }")

    [[ -z "$pr" ]] && return

    local pr_num=$(echo "$pr" | cut -f1)

    gh pr checkout --repo loops-so/loops "$pr_num"
    nvim -c "DiffviewOpen main"
}

export GPG_TTY=$(tty)
export PATH="$HOME/.local/bin:$PATH"

# Dev session: Claude Code + nvim side by side
dev() {
    if [[ -n "$TMUX" ]]; then
        echo "Already in tmux. Use Ctrl-a c for Claude split."
        return
    fi

    # Start tmux with two panes: nvim left, claude right
    tmux new-session -d -s dev -c "$(pwd)"
    tmux send-keys -t dev "nvim" Enter
    tmux split-window -h -t dev -c "$(pwd)"
    tmux send-keys -t dev "claude" Enter
    tmux select-pane -t dev:0.0  # focus nvim
    tmux attach -t dev
}

# Review session: stack review in nvim + claude
review() {
    if [[ -n "$TMUX" ]]; then
        echo "Already in tmux. Use Ctrl-a c for Claude split."
        return
    fi

    tmux new-session -d -s review -c "$(pwd)"
    tmux send-keys -t review "loops stack review --all --nvim" Enter
    tmux split-window -h -t review -c "$(pwd)"
    tmux send-keys -t review "claude" Enter
    tmux select-pane -t review:0.0  # focus review
    tmux attach -t review
}
