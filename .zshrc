
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

eval "$(starship init zsh)"

alias kcup="kubectl config use-context production"
alias kcus="kubectl config use-context staging"
alias zconfig="nvim ~/.zshrc"
alias zsource="cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc"
alias dev="aws-vault exec prod-dev -- task dev"
alias check="aws-vault exec prod -- ./scripts/check-suppression-list.sh"
alias db="task db:port_forward"
alias db:rw="task db:port_forward:rw"
alias refresh="rm -fr .next node_modules && task dev"

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

export GPG_TTY=$(tty)
