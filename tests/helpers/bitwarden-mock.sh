#!/usr/bin/env bash
# Fake values only; never contact a vault or record secret-bearing arguments.
set -euo pipefail
printf '%s\n' "$1" >> "$BW_TEST_DIR/calls"
case "$1" in
    --version) printf 'test-version\n' ;;
    status)
        [[ "${BW_TEST_SCENARIO:-}" != status-failure ]] || exit 1
        state="$(cat "$BW_TEST_DIR/state")"
        if [[ "$state" == unlocked && -z "${BW_SESSION:-}" ]]; then state=locked; fi
        printf '{"status":"%s"}\n' "$state" ;;
    login|unlock)
        [[ "${BW_TEST_SCENARIO:-}" != "$1-failure" ]] || exit 1
        [[ "$2" == --raw ]] || exit 1
        printf 'unlocked\n' > "$BW_TEST_DIR/state"
        [[ "${BW_TEST_SCENARIO:-}" != empty-session ]] || exit 0
        printf 'SUPER_SECRET_SENTINEL_12345_SESSION' ;;
    sync)
        [[ "${BW_TEST_SCENARIO:-}" != sync-failure ]] || exit 1 ;;
    lock)
        [[ "${BW_TEST_SCENARIO:-}" != lock-failure ]] || exit 1
        printf 'locked\n' > "$BW_TEST_DIR/state" ;;
    list)
        [[ "${BW_TEST_SCENARIO:-}" != list-failure ]] || exit 1
        cat "$BW_TEST_DIR/items.json" ;;
    get)
        [[ "${BW_TEST_SCENARIO:-}" != get-failure ]] || exit 1
        [[ "$2" == item && "$3" == 11111111-1111-1111-1111-111111111111 ]] || exit 1
        cat "$BW_TEST_DIR/item.json" ;;
    *) exit 1 ;;
esac
