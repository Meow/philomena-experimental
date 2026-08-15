# Philomena context refactor plans

This directory plans the remaining context-layer cleanup after the namespace
refactor. [all-contexts.md](all-contexts.md) defines the contract and migration
order shared by every context. The files under [contexts/](contexts/) record the
context-specific audit findings, behavior decisions, and verification work.
Implementation style for this work is defined by the repository's
[context development guide](../../CONTEXT_STYLE.md).

## Scope

The inventory includes every top-level `Philomena` module that is a domain
context, is consumed by a controller, or owns persistence operations used by a
context. It deliberately excludes OTP/infrastructure modules (`Application`,
`Config`, `ExqSupervisor`, `Mailer`, `Native`, `Release`, and `Repo`), generic
utilities (`Attribution`, `IntegerId`, `Markdown`, `SearchIndexer`,
`SearchMigrator`, `SearchPolicy`, and `Slug`), and background-job entry points.
`Authorization`, `Loader`, `RateLimiter`, and `Subscriptions` are covered by the
shared plan because changing them affects several contexts at once.

## Plans

| Area                               | Individual plan                                   |
| ---------------------------------- | ------------------------------------------------- |
| Homepage assembly                  | [Activities](contexts/activities.md)              |
| Advertising                        | [Adverts](contexts/adverts.md)                    |
| Artist ownership links             | [ArtistLinks](contexts/artist-links.md)           |
| Compiled autocomplete              | [Autocomplete](contexts/autocomplete.md)          |
| Badges and awards                  | [Badges](contexts/badges.md)                      |
| Fingerprint, subnet, and user bans | [Bans](contexts/bans.md)                          |
| Livestream channels                | [Channels](contexts/channels.md)                  |
| Image comments                     | [Comments](contexts/comments.md)                  |
| Commission profiles and items      | [Commissions](contexts/commissions.md)            |
| Private conversations              | [Conversations](contexts/conversations.md)        |
| Do-not-post entries                | [DnpEntries](contexts/dnp-entries.md)             |
| Donations                          | [Donations](contexts/donations.md)                |
| Duplicate reports                  | [DuplicateReports](contexts/duplicate-reports.md) |
| Filters                            | [Filters](contexts/filters.md)                    |
| Forums                             | [Forums](contexts/forums.md)                      |
| Galleries                          | [Galleries](contexts/galleries.md)                |
| Image favorites                    | [ImageFaves](contexts/image-faves.md)             |
| Image features                     | [ImageFeatures](contexts/image-features.md)       |
| Image hides                        | [ImageHides](contexts/image-hides.md)             |
| Image intensities                  | [ImageIntensities](contexts/image-intensities.md) |
| Image votes                        | [ImageVotes](contexts/image-votes.md)             |
| Images                             | [Images](contexts/images.md)                      |
| Aggregated image interactions      | [Interactions](contexts/interactions.md)          |
| Moderator notes                    | [ModNotes](contexts/mod-notes.md)                 |
| Moderation logs                    | [ModerationLogs](contexts/moderation-logs.md)     |
| Notifications                      | [Notifications](contexts/notifications.md)        |
| Poll options                       | [PollOptions](contexts/poll-options.md)           |
| Poll votes                         | [PollVotes](contexts/poll-votes.md)               |
| Polls                              | [Polls](contexts/polls.md)                        |
| Forum posts                        | [Posts](contexts/posts.md)                        |
| Profile-page assembly              | [Profiles](contexts/profiles.md)                  |
| User reports                       | [Reports](contexts/reports.md)                    |
| Roles                              | [Roles](contexts/roles.md)                        |
| Site rules                         | [Rules](contexts/rules.md)                        |
| Site notices                       | [SiteNotices](contexts/site-notices.md)           |
| Image source changes               | [SourceChanges](contexts/source-changes.md)       |
| Static pages                       | [StaticPages](contexts/static-pages.md)           |
| Tag changes                        | [TagChanges](contexts/tag-changes.md)             |
| Tags                               | [Tags](contexts/tags.md)                          |
| Forum topics                       | [Topics](contexts/topics.md)                      |
| Fingerprint profiles               | [UserFingerprints](contexts/user-fingerprints.md) |
| IP profiles                        | [UserIps](contexts/user-ips.md)                   |
| User-name change records           | [UserNameChanges](contexts/user-name-changes.md)  |
| Daily user statistics              | [UserStatistics](contexts/user-statistics.md)     |
| Users and accounts                 | [Users](contexts/users.md)                        |
| Post/comment versions              | [Versions](contexts/versions.md)                  |

Each checklist is intended to be independently mergeable after the shared
loading contract lands, but contexts coupled by nested resources should be done
in the waves described in the all-context plan.
