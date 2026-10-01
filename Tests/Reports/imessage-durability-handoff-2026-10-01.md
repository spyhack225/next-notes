# IM-16 durable-host handoff — 2026-10-01

The production host stays blocked. The watcher/bridge/adapter chain can be tested
in isolation, but binding it directly to remote tool turns would not make crash
recovery safe. An action that fired before its reply was recorded has an unknown
outcome; a restart must reconcile that outcome or ask, never automatically resend.

P6-01 is committed as `ff40a93`: five installed actual-store restart cases, the
existing task test and owner-store isolation pass. It characterizes today's
failure-on-restart behavior. Core is 16/18, with the known wake failure and an
unresolved dictation microphone/hold classification failure; a recheck has
separate capture timing/no-audio failures. No recovery or core readiness claim.

P6-02a is committed as `670bc35`: canonical JSON→SQLite storage, 18 installed
actual-store cases, existing tasks and isolation of 21 files/23 defaults pass.
JSON remains read authority; mirror failure stays visible, and corrupt/unsupported
SQLite is retained. Final contention is 1.029/1.358 ms. Parent P6-02 retains
P6-02b's original trusted artifact/evidence producers and actual UI consumers.

P3-02 is committed as `7e3aba1`: three installed duplex runs, related regressions
and the original capture correction flow through real approval/final validity
pass. Removing the actual post-wait revision check fails on stale action fire.
Core remains 16/18: wake accuracy and varying dictation capture/retry failures
are unresolved. No model/default, numeric gate or phase exit is promoted.

P6-03's actual-manager event journal and P3-06a's shadow reducer/producer hooks
are now active, with disjoint owners. The journal worker owns the existing
manager/store plus narrow Executor final-fire fact hooks; the shadow worker
owns capture/coordinator/audio identities and factual PermissionGate hooks.
Root serializes registry changes, installed verification and roadmap updates.
TaskBridge and OutputScheduler remain subsequent contracts. AgentCapabilityManifest already exists. Remote TaskOrigin
must reuse ActionOriginContext and preserve message/session/transport identity;
contracts alone do not repair the live adapter's dropped identity. The external
Codex WEBSITE-TO-MAC-EXPERIENCE task owns app/site UI; its hunks remain separate.

IM-16 needs all of these before production binding:

- One task identity with durable remote origin, transport and source-message
  identity; recipient routing must remain bound to the paired channel.
- Journalled attempts/leases and receipt linkage around external actions;
  unknown or stale attempts cannot automatically fire or overwrite a newer run.
- Recovery that distinguishes never-fired from fired-with-unknown-outcome,
  restores required approvals and preserves completed results.
- The single task and delivery owner, durable pending deliveries, one result
  transport, and sleep/wake backlog fixtures proving order and no duplicate send.

Keep the existing isolated adapter, authority, approval and backlog fixtures.
Do not add another remote work queue, direct production watcher host, separate
recovery path, or resend-on-wake loop. The local ignored roadmap index, AO
STATUS/Phase 6 and NextNotes-iMessage README/STATUS/IM-16 task text now record
this same boundary. The iMessage source/shared files were declared frozen by
the owner; existing foreign source hunks are preserved by scoped commits.
