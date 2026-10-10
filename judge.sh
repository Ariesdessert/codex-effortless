#!/usr/bin/env bash
# The UserPromptSubmit hook as hooks.json runs it. Everything lives in effortless.pl next to this file;
# this name stays so an installed, trusted hook keeps working across updates.
exec perl "$(dirname "${BASH_SOURCE[0]}")/effortless.pl" "${@:-hook}"
