# Roles SQL shape audit

Refs: master -> context-logic
Status: complete

Query sites inspected: 10 logical sites, including the deleted `Roles` context,
the admin-user role form and assignment flow, role-bearing user preloads,
`Users.User`/`Users.Role` associations, and the erase worker.

---

## Changed shapes

### User lock query and role preload

- Master: `master:lib/philomena/users.ex:615-639` updated the already-loaded
  user in the admin update transaction; there was no locking `SELECT` or
  transaction-time role preload.
- context-logic: `lib/philomena/users.ex:197-201` defines
  `user_lock_query/1`, used by the admin update at `:1867-1874` and other
  user workflows. The final shape is a member lookup on `users` by primary key
  with `FOR UPDATE`, plus the Ecto many-to-many role preload:
  `roles INNER JOIN users_roles ON users_roles.role_id = roles.id WHERE
users_roles.user_id IN (caller user ids)`.
- Delta: new locking read and role-association preload in the refactored
  transaction. The role preload is a new workload for this operation; the
  locking query itself belongs to the Users/shared audit.
- Index status: covered; no index action
- Evidence: `users_pkey` covers the locked user lookup; `roles_pkey` covers the
  role join target; and the existing unique
  `index_users_roles_on_user_id_and_role_id (user_id, role_id)` has the preload
  filter column first. No runtime plan was needed for an index candidate.
- Confidence: high

### Erase worker moderator role preload

- Master: `master:lib/philomena/workers/user_erase_worker.ex:5-9` loaded both
  users with `Users.get_user!/1`; it issued no role preload in the worker.
  The request controller did preload the target's roles, but that was a
  separate request-time operation (`master:lib/philomena_web/controllers/admin/user/erase_controller.ex:9-14`).
- context-logic: `lib/philomena/workers/user_erase_worker.ex:5-9` calls
  `Users.fetch_user_for_erase!/1`, whose `lib/philomena/users.ex:2819-2823`
  performs a user primary-key lookup followed by the same many-to-many role
  preload used above.
- Delta: new role preload for the moderator loaded by the background worker;
  this supplies the synthetic actor's role map. It is a new/unpaired workload,
  not a changed predicate on `roles` or `users_roles`.
- Index status: covered; no index action
- Evidence: `users_pkey`, `roles_pkey`, and
  `index_users_roles_on_user_id_and_role_id (user_id, role_id)` cover the
  normalized shape. No runtime plan was needed for an index candidate.
- Confidence: high

---

## Unchanged or non-index-relevant sites

- Role catalog for the admin form: `master:lib/philomena_web/controllers/admin/user_controller.ex:75-77`
  used `Repo.all(Role)`; `lib/philomena/users.ex:123-127` now performs the
  same unfiltered `SELECT roles.* FROM roles`, moved into `admin_user_form/1`.
  The deleted `master:lib/philomena/roles.ex:20-22` `list_roles/0` was not
  called by repository code.
- Role assignment lookup: `master:lib/philomena/users.ex:615-619` and
  `lib/philomena/users.ex:130-146` both select all rows matching
  `roles.id IN (caller role ids)`. `RoleForm` now casts and deduplicates IDs
  before the query and rejects invalid input; that changes validation and
  bind cardinality, not the relational access shape. `roles_pkey` covers it.
- Session and authentication role setup is shape-equivalent: the master
  `load_with_roles/1` at `master:lib/philomena/users.ex:1049-1053` and the
  current `load_with_roles/1`/`load_user_with_roles/1` at
  `lib/philomena/users.ex:164-173` issue the same role preload. The current
  timestamped session path at `:1028-1037` uses that same preload after its
  token lookup.
- Admin edit/update and erase request loads retain the same role-specific
  preload. The controller declarations at
  `master:lib/philomena_web/controllers/admin/user_controller.ex:13-17` and
  `master:lib/philomena_web/controllers/admin/user/erase_controller.ex:9-14`
  moved to `Users.load_user_by_slug/4` callers at
  `lib/philomena/users.ex:1835-1838`, `:1867-1869`, and `:2145-2148`.
  The association SQL remains the same; the parent-user loader is owned by
  Users.
- `Philomena.Roles.Role` changed only by adding `@type t` at
  `lib/philomena/roles/role.ex:5`; its table fields and changeset are
  unchanged. `Users.User`'s `many_to_many :roles` association and
  `Users.Role`'s `users_roles` schema are unchanged. `RoleForm` and
  `AdminUserForm` add no SQL by themselves.

---

## New, deleted, moved, or ambiguous sites

- `master:lib/philomena/roles.ex` was deleted in context-logic. Its
  `list_roles/0` read is represented by the moved admin-form query above;
  `get_role!/1` was a primary-key lookup with no repository callers found in
  either ref. `create_role/1`, `update_role/2`, `delete_role/1`, and
  `change_role/1` likewise had no callers; their removal does not expose a
  changed live SQL workload. If an external caller relied on `get_role!/1`,
  its former lookup was covered by `roles_pkey`.
- No role lookup by `name` or `resource_type` exists in either ref; those
  columns are consumed in memory while building `role_map`. No index on either
  column is therefore justified by this audit.
- The two new role-preload paths above should be linked from the Users/shared
  report rather than receiving duplicate index recommendations here.

---

## Follow-ups

- No index candidate remains for Roles. Existing coverage is:
  `roles_pkey`, `index_users_roles_on_role_id (role_id)`, and unique
  `index_users_roles_on_user_id_and_role_id (user_id, role_id)`.
- The new role-ID validation in `RoleForm` is a behavior/correctness change
  (invalid or missing role IDs now produce a role error) and is not an index
  concern.
- No `EXPLAIN` was run because every newly observed role-related access path
  is already covered and no missing access path was identified.
