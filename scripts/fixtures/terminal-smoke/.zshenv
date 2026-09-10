# Isolate this login-shell integration check from user and system startup customizations.
unsetopt GLOBAL_RCS
# macOS login(1) resets HOME even with -p. Keep all subsequent shell writes in the owned test directory.
HOME="${KUBIX_TERMINAL_SMOKE_DIRECTORY}/home"
