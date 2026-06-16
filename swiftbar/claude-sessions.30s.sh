#!/bin/zsh
# SwiftBar plugin — claude sessions: which Claude Code session is working on what,
# across every repo. Menu-bar badge = # of LIVE sessions; the dropdown lists each
# (repo · branch · state) with branch/purpose/files in a submenu, plus the dotfiles
# `own` lanes with real process-liveness. All logic lives in `claude-sessions`
# (python): this just renders its --swiftbar output.
#
# <bitbar.title>claude sessions</bitbar.title>
# <bitbar.desc>Live Claude Code sessions across repos (presence + process-liveness).</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# 30s filename interval → keeps the badge current AND reaps dead-session records
# ambiently (the reader GCs them on every run), so the menu-bar self-heals.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
exec "$HOME/.dotfiles/scripts/claude-sessions" --swiftbar
