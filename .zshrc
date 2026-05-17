
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
            local subcmd=$1
            shift 2>/dev/null
            case "$subcmd" in
                review)
                    ~/.dotfiles/scripts/stack-review "$@"
                    ;;
                snapshot)
                    ~/.dotfiles/scripts/stack-snapshot save
                    ;;
                diff)
                    ~/.dotfiles/scripts/stack-snapshot diff
                    ;;
                webview)
                    npx tsx ~/.dotfiles/scripts/stack/index.ts webview "$@"
                    ;;
                flow)
                    npx tsx ~/.dotfiles/scripts/stack/index.ts flow "$@"
                    ;;
                sync)
                    npx tsx ~/.dotfiles/scripts/stack/index.ts sync "$@"
                    ;;
                project|home|branches|update|push|inject)
                    npx tsx ~/.dotfiles/scripts/stack/index.ts "$subcmd" "$@"
                    ;;
                *)
                    echo "loops stack commands:"
                    echo "  loops stack review   - review stack in nvim"
                    echo "  loops stack snapshot - save current state"
                    echo "  loops stack diff     - show changes since snapshot"
                    echo "  loops stack branches - list stack branches in order (--json, --names)"
                    echo "  loops stack update   - rebase downstream branches (--from=<branch>, --dry-run)"
                    echo "  loops stack push     - push all stack branches (--force, --remote=<remote>)"
                    echo "  loops stack webview  - open stack viewer in browser (<prefix> or --project <name>)"
                    echo "  loops stack inject   - AI-powered patch routing (--save, --no-claude)"
                    echo "  loops stack flow     - sync + push (--dry-run)"
                    echo "  loops stack sync     - rebase stack onto trunk, prune merged, push"
                    echo "  loops stack home     - work-in-progress dashboard"
                    echo "  loops stack project  - manage projects (list, show, create, delete, add, remove, set-memory)"
                    ;;
            esac
            ;;
        review-branch)
            ~/.dotfiles/scripts/branch-review "$@"
            ;;
        pr-review)
            _loops_pr_review "$@"
            ;;
        clean-migrations)
            _loops_clean_migrations "$@"
            ;;
        staging)
            ~/.dotfiles/scripts/staging "$@"
            ;;
        *)
            echo "Usage: loops <command>"
            echo ""
            echo "Commands:"
            echo "  stack review      Review stack in nvim (diffview)"
            echo "  review-branch     Review branch against main with blessing"
            echo "  pr-review         Review PRs assigned to you (with blessing)"
            echo "  clean-migrations  Remove empty migration folders"
            echo "  staging           Check build/deploy status, watch, or deploy"
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
    local pr_branch=$(git branch --show-current 2>/dev/null)
    nvim -c "DiffviewOpen main..${pr_branch}" \
         -c "lua require('custom.branch-review').setup({branch='${pr_branch}', base='main'})"
}

# Swap git remotes (toggle origin between phil-loops and loops-so)
git-swap-remote() {
    local current_origin=$(git remote get-url origin 2>/dev/null)

    if [[ "$current_origin" == *"phil-loops"* ]]; then
        git remote rename origin phil-loops
        git remote rename upstream origin
        echo "Switched: origin → Loops-so (main repo)"
    elif [[ "$current_origin" == *"Loops-so"* || "$current_origin" == *"loops-so"* ]]; then
        git remote rename origin upstream
        git remote rename phil-loops origin
        echo "Switched: origin → phil-loops (your fork)"
    else
        echo "Unknown origin: $current_origin"
    fi

    git remote -v | grep origin
}

export GPG_TTY=$(tty)
export PATH="$HOME/.local/bin:$HOME/.dotfiles/scripts:$PATH"

task() {
    if [[ "$1" == "dev" ]]; then
        echo "silly! did you reaaaally want to run with ngrok?"
        echo "  hint: use 'dev' to run without ngrok"
        read -r "reply?continue with ngrok? [y/N] "
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            command task "$@"
        else
            echo "ok, bailing out. use 'dev' next time!"
        fi
    else
        command task "$@"
    fi
}

alias dev="NGROK=false command task dev 2>&1 | tee /tmp/loops-dev.log"
hold() {
    if [[ "$1 $2" == "my beer" ]]; then
        shift 2
        claude --dangerously-skip-permissions "$@"
    else
        echo "🍺 Usage: hold my beer"
    fi
}
