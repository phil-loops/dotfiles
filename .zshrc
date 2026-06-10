
# Auto-start tmux (skip with NO_TMUX=1 zsh)
if [[ -z "$TMUX" && -z "$NO_TMUX" && -t 0 ]]; then
  exec tmux new-session -A -s loops
fi

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

eval "$(starship init zsh)"

# Load zsh completion system so `compdef` works for custom completions below.
# -C skips the cache integrity check for faster startup.
autoload -Uz compinit && compinit -C

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
                    # No arg: if the current branch is part of a stack (has a
                    # recorded parent), let stack-review auto-resolve it — it
                    # upgrades any member branch to its project view. Only when
                    # we're not on a stack at all (e.g. main) do we fzf-pick.
                    if (( $# == 0 )); then
                        local cur=$(git branch --show-current 2>/dev/null)
                        if [[ -z "$(git config stack-branch.${cur}.parent 2>/dev/null)" ]]; then
                            local picked=$(~/.dotfiles/scripts/stack-list --pick) || return $?
                            [[ -z "$picked" ]] && return 130
                            ~/.dotfiles/scripts/stack-review "$picked"
                            return $?
                        fi
                    fi
                    ~/.dotfiles/scripts/stack-review "$@"
                    ;;
                list|ls)
                    ~/.dotfiles/scripts/stack-list "$@"
                    ;;
                integrate)
                    ~/.dotfiles/scripts/stack-integrate "$@"
                    ;;
                restack)
                    ~/.dotfiles/scripts/stack-restack "$@"
                    ;;
                *)
                    echo "loops stack commands:"
                    echo "  loops stack review [project|branch]   review stack in nvim diffview"
                    echo "  loops stack list                       list registered stack-projects"
                    echo "  loops stack list --pick                fzf-pick a stack and open in review"
                    echo "  loops stack integrate <project>        build virtual integration ref"
                    echo "  loops stack restack <project>          rebase whole project onto fresh origin/main"
                    echo "  loops stack restack <project> --plan   dry-run: show planned topo order"
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

_loops() {
    local -a branches
    if (( CURRENT == 2 )); then
        _values 'subcommand' \
            'stack[branch stack tools]' \
            'review-branch[review current branch vs main]' \
            'pr-review[review PRs assigned to you]' \
            'clean-migrations[remove empty migration folders]' \
            'staging[staging build/deploy status]'
    elif (( CURRENT == 3 )) && [[ "${words[2]}" == "stack" ]]; then
        _values 'stack subcommand' 'review[review stack in nvim diffview]'
    elif (( CURRENT == 4 )) && [[ "${words[2]}" == "stack" ]] && [[ "${words[3]}" == "review" ]]; then
        # Build branch → projects map from `stack-project.<proj>.branch <branch>` config.
        local -A branch_projects
        local line proj branch
        while IFS= read -r line; do
            [[ "$line" =~ ^stack-project\.(.+)\.branch[[:space:]]+(.+)$ ]] || continue
            proj="${match[1]}"
            branch="${match[2]}"
            if [[ -n "${branch_projects[$branch]}" ]]; then
                branch_projects[$branch]+=",${proj}"
            else
                branch_projects[$branch]="$proj"
            fi
        done < <(git config --get-regexp '^stack-project\..+\.branch$' 2>/dev/null)

        # Complete on project NAMES (resolves to the project's tip) and on
        # project member branches. Skips the long tail of unstacked local
        # branches; for those, type the name fully or add to a project first:
        #   git config --add stack-project.<name>.branch <branch>
        local -A projects_seen
        local -a project_names_entries project_branch_entries
        local b proj
        # Count branches per project for description
        for b in "${(@k)branch_projects}"; do
            for proj in ${(s:,:)branch_projects[$b]}; do
                projects_seen[$proj]=$((${projects_seen[$proj]:-0} + 1))
            done
            project_branch_entries+=("${b}:${branch_projects[$b]}")
        done
        for proj in "${(@k)projects_seen}"; do
            project_names_entries+=("${proj}:project (${projects_seen[$proj]} branches)")
        done

        _describe -t projects 'project' project_names_entries
        _describe -t project-branches 'project branch' project_branch_entries
    fi
}
compdef _loops loops

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

# Print a stack as a tree, walking up `stack-branch.<name>.parent` from the tip.
# Usage: stack-print [tip-branch]   (defaults to current branch)
stack-print() {
    local tip="${1:-$(git rev-parse --abbrev-ref HEAD)}"
    local chain=() b="$tip"
    while [[ -n "$b" && "$b" != "main" ]]; do
        chain=("$b" "${chain[@]}")
        b=$(git config --get "stack-branch.$b.parent")
    done
    printf 'main\n'
    local depth=1
    for b in "${chain[@]}"; do
        printf '%*s└─ %s   (%s)\n' $((depth*2)) "" "$b" "$(git log -1 --format=%s "$b" 2>/dev/null | cut -c1-70)"
        depth=$((depth+1))
    done
}

# Inspect a sibling git worktree's diff without touching the current checkout.
# Default: open in nvim (DiffviewOpen). --html: render as side-by-side HTML and open in the browser.
# Usage: wt [base-branch] [--html|-H]   (base defaults to main)
# For stack-aware review, use `loops stack review` (which also accepts --html).
wt() {
    local base="main"
    local html=0
    for arg in "$@"; do
        case "$arg" in
            --html|-H) html=1 ;;
            *) base="$arg" ;;
        esac
    done

    local current_top=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$current_top" ]]; then
        echo "Not in a git repository"
        return 1
    fi

    # Skip the current checkout and the harness-internal .claude/worktrees/* agent trees.
    local worktrees=$(git worktree list --porcelain | awk -v cur="$current_top" '
        /^worktree / { path = $2 }
        /^branch /   {
            sub("refs/heads/", "", $2)
            if (path != cur && path !~ /\/\.claude\/worktrees\//) print path "\t" $2
        }
    ')

    if [[ -z "$worktrees" ]]; then
        echo "No other worktrees (only the current checkout: $current_top)"
        return
    fi

    # Diff against the MERGE-BASE with base (not base's tip), so a branch that's
    # merely behind main doesn't show all of main's advancement as "changes".
    # Preview/diff against $(merge-base) includes uncommitted working-tree changes.
    local selection=$(echo "$worktrees" \
        | fzf --delimiter='\t' --with-nth=2 \
            --preview "mb=\$(git -C {1} merge-base ${base} HEAD 2>/dev/null); git -C {1} diff \$mb --stat 2>/dev/null || echo 'no diff vs ${base}'")

    [[ -z "$selection" ]] && return

    local wt_path=$(echo "$selection" | cut -f1)
    local wt_branch=$(echo "$selection" | cut -f2)

    if (( html )); then
        local slug=$(echo "$wt_branch" | tr '/' '-')
        local patch="/tmp/wt-${slug}.patch"
        local html_file="/tmp/wt-${slug}.html"
        (cd "$wt_path" && git diff "${base}...HEAD" > "$patch") || return
        npx --yes diff2html-cli -i file -s side -F "$html_file" -- "$patch" >/dev/null || return
        open "$html_file"
        echo "→ $html_file"
        return
    fi

    # --imply-local: right side of the A...B range shows the local working tree
    # (incl. uncommitted), while A is the merge-base.
    (cd "$wt_path" && nvim -c "DiffviewOpen ${base}...HEAD --imply-local")
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

# Daily work log (~/daily-log/YYYY-MM-DD.md, organized by Linear ticket)
alias eod="~/.dotfiles/scripts/daily-log show"
alias log-show="~/.dotfiles/scripts/daily-log show"
alias log-edit="~/.dotfiles/scripts/daily-log edit"
hold() {
    if [[ "$1 $2" == "my beer" ]]; then
        shift 2
        claude --dangerously-skip-permissions "$@"
    else
        echo "🍺 Usage: hold my beer"
    fi
}
