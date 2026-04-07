#!/usr/bin/env bash
# Convenience wrapper. Delegates to install.sh --uninstall so all install logic
# (jq merge, backup, rollback) lives in one place.
exec "$(dirname "${BASH_SOURCE[0]}")/install.sh" --uninstall
