# Debugging races with ThreadSanitizer

For contributors: how to run kinhin's test suite under ThreadSanitizer (`scripts/tsan.sh`) and read the result.

## When to run it

Run it when you touch shared state: actors, locks, `Mutex`, or anything `nonisolated(unsafe)` (fleet engine, controllers, token store, test doubles that swap global behavior). CI runs it nightly and on demand (`workflow_dispatch`), not on every push, because it takes about 5–10 minutes.

```bash
scripts/tsan.sh                          # whole suite
scripts/tsan.sh -- --filter FleetEngine  # forward arguments to swift test
```

The script is `swift test --sanitize thread` in debug, run serially, with the full output tee'd to `.build/tsan.log`.

## Why it is serial

Never add `--parallel`. Under ThreadSanitizer the parallel worker bundles collide on the tests' fixed temp paths (for example `UpdateCheckTests`' version-named DMG), so suites fail at random, and the default target can exit 0 while other bundles are still running.

## Reading the result

Under TSan the exit code tracks sanitizer reports, not test results: TSan aborts the run at exit as soon as it holds a report, so a target whose tests all pass can still exit 1. Read the summary the script prints:

| Summary                                          | Meaning                                                                                  |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `ThreadSanitizer reports (grouped by SUMMARY)`   | A data race. The script exits 1; full stacks are in `.build/tsan.log`. Fix the race.     |
| `No ThreadSanitizer reports.` plus failing tests | An ordinary test regression. The failing `error: -[…]` lines are listed (first 20).      |
| `No ThreadSanitizer reports.` and exit 0         | Clean.                                                                                   |

There is no tolerated-race list: any report fails the script.

## Debugging a report

1. Open `.build/tsan.log` and find the `WARNING: ThreadSanitizer` block. It shows the two conflicting accesses with stacks, and where each thread was created.
2. Re-run just the affected suite with `scripts/tsan.sh -- --filter <TestClass>` to iterate quickly.
3. Fix it with a `Mutex` or an actor (see the Concurrency section of [CLAUDE.md](https://github.com/RabinApps/kinhin/blob/main/CLAUDE.md)), not a new `DispatchQueue`, semaphore or `NSLock`. Test globals that swap behavior across threads (such as `StubProtocol.handler`) keep their storage behind a `Mutex`; give any new test global the same treatment instead of `nonisolated(unsafe)`.
