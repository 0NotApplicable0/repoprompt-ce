# Process spawning

`Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift` is the single `posix_spawn`
entry point for every CLI/tool/agent subprocess (grok, codex, antigravity, the MCP bridge CLIs,
etc.). A couple of spawn-attribute invariants there are load-bearing and have caused
hard-to-diagnose hangs when missing. This is contributor/debugging guidance — document new
spawn-environment fixes here so the next person finds the symptom→cause mapping fast.

## Invariant: spawned children must start with an empty signal mask

`ProcessLauncher.spawn` sets `POSIX_SPAWN_SETSIGMASK` with an **empty** `sigset_t`
(`posix_spawnattr_setsigmask`, alongside the existing `POSIX_SPAWN_SETSIGDEF`). Do not remove this.

**Why:** `posix_spawn` inherits the **calling thread's** signal mask. We spawn from GCD/worker
threads whose mask may have signals blocked. Without resetting it, the child inherits a blocked
mask and starts life with signals masked. Runtimes that depend on signal delivery then never make
progress.

**Symptom seen in practice (the grok freeze):** a Grok CLI run would intermittently **freeze
mid-run**, typically after it had issued several MCP tool calls — live streaming stopped, the run
never completed, but the subprocess stayed alive (not crashed). grok's async gateway relies on
signal delivery internally, so an inherited blocked mask wedged it. Running the same grok command
**manually** in a terminal always worked, because an interactive shell spawns it with a clean mask
— which is exactly what made this so confusing. The fix gives every spawned child a clean
(all-unblocked) signal mask regardless of which thread we spawned from.

**If a spawned CLI/agent ever freezes again with no crash and no output, but works when run
manually:** suspect the inherited signal environment first (mask and default dispositions), not the
tool itself. Confirm by spawning the same command from a thread with signals blocked
(`pthread_sigmask`) and checking whether it wedges.

**Regression test:**
`Tests/RepoPromptTests/MCP/Control/ProcessLauncherDescriptorInheritanceTests.swift` →
`testSpawnedChildSignalMaskIsResetEvenWhenSpawningThreadBlocksSignals` blocks `SIGUSR1` on the
spawning thread, spawns a child that signals itself, and asserts the child is **not** killed by it.
It fails if the `SETSIGMASK` reset is removed.

## Related invariant: SIGPIPE default disposition

Parent-side write paths use no-SIGPIPE hardening (`FDWriteSupport.configureNoSigPipe`). The spawn
restores the **default** `SIGPIPE` disposition in children (`POSIX_SPAWN_SETSIGDEF` with `SIGPIPE`)
so CLI/tool processes keep normal pipe semantics. Keep both the no-SIGPIPE parent hardening and the
child default-restore in sync if you touch either.
