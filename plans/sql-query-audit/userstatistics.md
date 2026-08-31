# UserStatistics SQL shape audit

Refs: master -> context-logic
Status: complete

Query sites inspected: 3 logical operation families, including delegated user
counter updates, daily upserts, bulk interaction updates, and profile reads.

--- repo status ---

Worktree was clean before this report was created. No application code,
migrations, tests, or schema files were changed.

--- relevant files ---

- `lib/philomena/user_statistics.ex`
- `lib/philomena/user_statistics/user_statistic.ex`
- `lib/philomena/users.ex` (delegated lifetime-counter updates)
- `lib/philomena/profiles.ex` (current profile statistics query)
- `lib/philomena_web/controllers/profile_controller.ex` (master profile statistics query)
- `lib/philomena/comments.ex`
- `lib/philomena/image_faves.ex`
- `lib/philomena/image_votes.ex`
- `lib/philomena/images.ex`
- `lib/philomena/posts.ex`
- `lib/philomena/topics.ex`
- `priv/repo/structure.sql`
- `priv/repo/migrations/20200617113333_prod_schema_sync2.exs`
- `priv/repo/migrations/20250430092058_user_statistics_new_pk.exs`
- `priv/repo/migrations/20250501023533_fix_various_counters.exs`
- `priv/repo/migrations/20260718000000_user_statistics_day_to_date.exs`

## Changed shapes

1. **Single-user lifetime increment plus daily upsert** — `inc_stat/3` in
   master; `increment/3` and `persist_increment/3` in context-logic.

   - Master shape: `UPDATE users SET <counter> = <counter> + $amount WHERE
users.id = $user_id`, followed in the same transaction by an
     `INSERT ... INTO user_statistics` for one `(user_id, day)` row with
     `ON CONFLICT (day, user_id) DO UPDATE` incrementing the selected counter.
   - Current shape: the same single-row `UPDATE users ... WHERE id = $user_id`
     is delegated to `Users.increment_counter/4`, followed by the same daily
     upsert. The dynamic branches are the seven permitted counter columns and
     positive/negative integer amounts; none changes the relational shape.
   - Classification: **unchanged** (the helper moved to `Users`). The current
     row-count check returns `{:error, :not_found}` before the daily insert when
     the user update affects zero rows; this is a behavior/correctness change,
     not an index-shape change.
   - Index coverage: `users_pkey (id)` covers the update; the
     `user_statistics` primary key and unique index on `(user_id, day)` cover
     conflict inference and the upsert target.

2. **Bulk lifetime increments plus daily upserts** — `put_bulk_increment/4`
   and `persist_bulk_increment/4` in context-logic, used by the image-fave and
   image-vote interaction migration paths.

   - Master counterpart: none. Master performed one single-user statistic
     operation per interaction owner through `inc_stat/3`.
   - Current shape: one `UPDATE users SET <counter> = <counter> + $amount WHERE
users.id IN ($user_id_1, ...)`, followed by one multi-row
     `INSERT ... INTO user_statistics` for the current day, with
     `ON CONFLICT (day, user_id) DO UPDATE` incrementing the selected counter.
     The empty-list branch emits no SQL; IDs are deduplicated before the query.
   - Classification: **new, index-relevant** workload. The user update adds an
     `id IN (...)` predicate and the daily write changes from repeated
     single-row inserts to a multi-row upsert, but both access paths are
     already covered.
   - Index coverage: `users_pkey (id)` supports each member of the `IN`
     predicate; `user_statistics_pkey (user_id, day)` and the equivalent
     unique `(user_id, day)` index support the upsert conflict target. No new
     index candidate is recommended. No representative plan was needed to
     justify an addition because both lookup keys are primary/unique covered.

3. **Per-user/date profile statistics aggregation** — `calculate_statistics/1`
   moved from `PhilomenaWeb.ProfileController` in master to
   `Philomena.Profiles` in context-logic.

   - Both refs issue the same collection query: `SELECT` from
     `user_statistics` with `user_id = $user_id AND day >= $date`, followed by
     application-side mapping into the 90-day series. There is no join,
     grouping, ordering, limit, offset, or distinct clause.
   - Classification: **unchanged** (moved only). The date-type conversion was
     already represented in both refs and does not belong to the
     master/context-logic delta.
   - Index coverage: the composite `(user_id, day)` primary key supports the
     equality-then-range access path. The standalone `user_id` B-tree also
     exists but is not required for this shape; no new index candidate is
     recommended.

## Unchanged or non-index-relevant sites

- The profile statistics query is unchanged and is described in the changed
  shapes section as a moved operation; the lifetime counter update and daily
  upsert are also unchanged for single-user calls.

## New, deleted, moved, or ambiguous sites

- The bulk lifetime-increment/multi-row daily-upsert path is a new workload
  with primary/unique coverage and no unresolved counterpart beyond the
  interaction migration callers.

## Index and migration review

`priv/repo/structure.sql` is unchanged for `user_statistics` between the two
refs. The table has `PRIMARY KEY (user_id, day)`, an equivalent unique B-tree
index on `(user_id, day)`, a standalone B-tree index on `user_id`, and a
cascading foreign key from `user_statistics.user_id` to `users.id`.

Relevant history confirms the composite key was established by
`20250430092058_user_statistics_new_pk.exs`; counter-column naming was updated
by `20250501023533_fix_various_counters.exs`; and `day` was converted to
`date` by `20260718000000_user_statistics_day_to_date.exs`. The older
`20200617113333_prod_schema_sync2.exs` only changes the former sequence and
does not add an access path relevant to these queries.

No index recommendation is raised for UserStatistics. The only changed SQL
shape is the new bulk `IN`/multi-row-upsert workload, and its lookup and
conflict columns are already covered by primary/unique indexes.

## Follow-ups

- Confirm the zero-row user-update behavior change separately from index
  concerns; it now prevents a daily statistic write for a missing user.
- No index candidate is recommended because the changed bulk access paths are
  primary/unique covered.
