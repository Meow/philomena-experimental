# Human review of the summarized changes in summary.md

## Index candidates section

1. user_fingerprints candidate index. Confirmed missing, causes request timeout issues in current production deployments of `master`. To add `(user_id, updated_at DESC, id DESC)`.
2. commission_items candidate index. Ignored. p99 of item count per commission is 14.
3. moderation_logs candidate index. Ignored. Moderation logs are cleaned periodically (every 2 weeks). No request timeouts. Table has never grown beyond 10,000 entries. Global listing is largely for infrequent auditing purposes.
4. mod_nodes candidate indices. Ignored. p99 of moderation notes over all moderated items is 2.
5. artist_links candidate indices. Ignored. Requires bitmap operation and re-sort when multiple aasm_state filters are provided for querying. Additional indexing would provide marginal benefit. Good candidate for OpenSearch indexing which can handle this more efficiently.
6. channels candidate index. Ignored. Current channels count is 727.
7. user_ips candidate index. Confirmed. To add `(user_id, updated_at DESC, id DESC)` and remove `(user_id, updated_at DESC)`.
8. user_name_changes candidate index. Ignored. Name changes permitted only once every 90 days; maximum amount of name changes per user in 3650 days would be 40.
9. posts candidate index. Confirmed. To add `(topic_id, id) WHERE hidden_from_users IS FALSE`.
10. image_votes candidate index. Confirmed. To remove `user_id` and add `(user_id, image_id)`.
11. duplicate_reports candidate index. Ignored. p99 of duplicate report count per image pair is 5.
12. filters candidate index. Ignored. p99 of filter count per user_id is 71.
13. source_changes fingerprint candidate index. Ignored. This is an infrequently-used moderation tool. Good candidate for OpenSearch indexing, like TagChanges currently has.

## Unresolved questions section

### Wave A

- Staff are now intended to have their visibility rules applied everywhere, including the homepage.
- Adverts lookup in `record_click` now intentionally ignores adverts which are no longer active.
- Channels `like_sanitize` incorrectly added leading and trailing wildcards to the query; this has been fixed, and the same helper in the Commissions query builder has been adjusted to match it.
- The homepage channel and topic-strip listings should not generate count queries. This must be addressed before merge.
- Notification/category pages should have tie-breakers added, but this will be a follow-up item and not work for this branch.
- Improper singleton behavior for autocomplete is a correctness issue but should not affect practical production workloads as the loader allows for one row instead of requiring one row. To be fixed in follow-up work.

### Wave B

- Missing display filter link for "All Entries" to be added to resolve this before merge.
- These are intentional correctness adjustments. Inactive/deleted users are not intended to be considered for interaction. Nested resources must validate their parent resources.

### Wave C

- These are largely intentional correctness adjustments. Staff are now intended to have their visibility rules applied everywhere, including the homepage. There is one small policy issue (rather than a correctness issue) that must be addressed before merge: topics which have been hidden from users should not be shown in the topic listing for a forum, as they have already been moderated.
- Topic posts are filtered by topic_position and should also be ordered by ascending topic_position. This must be addressed before merge.
- The visible-post indexing candidate is confirmed and the corresponding index is to be added before merge.
- Unapproved comments were previously filtered in the display; filtering them in the database is a correctness fix. Moving the poll_options `vote_count > 0` predicate from an in-memory filter to a database filter should have no correctness or performance impact. The maximum number of options per poll is 20.

### Wave D

- The viewer-hide predicate for the featured image is a consistency/correctness fix and intended.
- The image_votes candidate index is necessary based on production table statistics and to be added before merge.
- Batch tag and tag reversion were previously restricted from applying to hidden images because it would corrupt tag image counters. This was fixed during the scoped work, so there is no longer a need to restrict them.

### Wave E

- The per-image gallery selection index is sufficient for the current, unbounded production workload. No index is expected to be needed.
- DuplicateReports is now intended to authorize the source and target images upon report creation. A candidate index for reverse-pair acceptance has been ignored, as discussed above. The other changes require revision. Filing automated reports against hidden images should occur, and must be fixed before merge. Hiding reports against hidden images in per-image report listings when the user cannot see hidden images must be fixed before merge; the listing should include all candidate reports.
- The semantic change in Filters to move from the query-based selection to a PK-only selection followed by in-memory authorization is intended. The recent/user filters union selection changes are also intended. Array replacement is unchanged from production and will not be considered; the proper correctness fix is to normalize the association and add appropriate indexing to the resulting join table.
- Slug-based loading and authorization for tags is an intended consistency fix. Consistent handling of image visibility is an intended correctness fix.
- TagChanges are intended to create one row for each image affected by a batch update (tag change reversion/batch tagging).
- SourceChanges timestamp ordering is intentional to match the currently OpenSearch-backed TagChanges. New candidate indexes are not currently considered necessary. Should the need arise, querying will be migrated to OpenSearch.

## Audit reconciliation

The shared and summary reports were checked against the review and source/index
evidence. The following dispositions are now reflected in those reports:

- Confirmed follow-ups are the UserFingerprints composite, the UserIps
  three-column replacement (with the old two-column index removable only after
  repository-wide usage verification), the partial Posts last-pointer index,
  and the ImageVotes cleanup replacement. The ImageVotes two-column request
  leaves `up` residual; migration review should compare it with the
  three-column equality variant.
- Commission-item, ModerationLogs, ModNotes, ArtistLinks, Channels,
  UserNameChanges, DuplicateReports reverse-pair, Filters owner-ordering, and
  SourceChanges history candidates are explicitly rejected for their reviewed
  low-volume/infrequent workloads, existing coverage, or planned OpenSearch/
  association-normalization paths.
- Filters array replacement is a moved, unchanged workload from tag aliasing;
  speculative GIN indexes were removed from the candidate list. Normalize the
  filter/tag association and index the resulting join table instead.
- Batch tag/revert code still derives visible-image sets for counter deltas but
  processes hidden-image taggings in the migration/reversion paths; retain a
  regression test for that distinction rather than treating the visibility
  predicate as an index gap.
- The topic-page ordering concern is a correctness fix: posts bounded by
  `topic_position` must be ordered ascending by that field. Homepage channel and
  topic strips must not incur Scrivener count queries.
- DuplicateReports still has one merge-blocking correctness check: automated
  report generation currently excludes hidden targets via
  `hidden_from_users = false`, while the reviewed policy requires those targets
  to be eligible. Per-image report SQL already has no endpoint-visibility
  predicate and the template iterates every returned report; verify this with
  a regression test, but do not treat it as a missed SQL filter or index gap.

No application code or migrations were changed during this reconciliation.
