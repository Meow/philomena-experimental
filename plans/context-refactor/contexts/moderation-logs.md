# ModerationLogs context plan

Source: `lib/philomena/moderation_logs.ex`; consumers: moderation-log controller
and most administrative contexts.

## Findings

- The FIXME in the public docs states the core integrity problem: logs are often
  inserted after the transaction that performed the moderated change.
- Several `create_moderation_log` overloads are globally public service APIs,
  while the controller-facing list function shares the same small module.
- The module layout is mixed and docs do not define how callers participate in a
  transaction.

## Work

- Replace post-hoc logging with a Multi-compatible service (for example,
  `put_log/…`) that contexts compose into the same database transaction as the
  mutation. Keep a direct insert only for truly non-transactional maintenance and
  name/document that exception.
- Standardize actor attribution, subject/action fields, before/after data, and
  failure behavior. A failed log should roll back the moderated database change.
- Keep `load_moderation_logs/2` actor-scoped with `:index` authorization and safe
  pagination/filter input. Put private changeset/query/cleanup mechanics first,
  then the public list and transaction service APIs.
- Migrate contexts wave by wave; remove the FIXME only when no controller
  mutation writes its log outside the owning transaction.

## Verification

- Add rollback tests proving both mutation and log succeed/fail together, plus
  actor attribution and listing authorization/pagination coverage.
