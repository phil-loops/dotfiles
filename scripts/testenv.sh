# Source first in a test script: every git the test runs ignores the machine's global and system
# config and reads only a test identity, with signing off, from the environment (see testenv.py).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=5 \
  GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=test \
  GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=test@example.invalid \
  GIT_CONFIG_KEY_2=commit.gpgsign GIT_CONFIG_VALUE_2=false \
  GIT_CONFIG_KEY_3=tag.gpgsign GIT_CONFIG_VALUE_3=false \
  GIT_CONFIG_KEY_4=init.defaultBranch GIT_CONFIG_VALUE_4=main
# …and a hook the test installs can't write the machine's pane record (scripts/pane-branch)
export PANE_BRANCH_DIR=/dev/null/pane-branch
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
