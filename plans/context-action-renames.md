# Request-facing context action renames

## Outcome

Rename the public context operations that serve HTTP controllers so their names
make the corresponding REST action obvious. This plan is intentionally a rename
inventory: the mechanical execution pass will update definitions, callers,
tests, documentation, and examples without changing behavior or result shapes.

The inventory was built from the current `context-logic` branch's controller
calls and route actions. A collection `index` operation is named `list_*`; a
search operation is named `query_*`; standard member actions use `new_*`,
`show_*`, `edit_*`, `create_*`, `update_*`, and `delete_*`. Nested singleton
routes qualify the route resource (`create_image_subscription`, for example),
and distinct API/page loaders retain distinct names when their contracts differ.

Only operations whose primary purpose is to service a request are included.
Internal loaders, transaction composition functions, indexing/worker services,
presentation helpers, generic authentication lookups, mail-delivery helpers,
and other non-request-facing operations remain unchanged. A row is a rename;
already target-shaped functions are deliberately omitted.

## Rename matrix

### `Philomena.Activities`

| Current             | Target              | Primary caller             |
| ------------------- | ------------------- | -------------------------- |
| `load_front_page/4` | `list_activities/4` | `ActivityController.index` |

### `Philomena.Adverts`

| Current                  | Target           | Primary caller                                                     |
| ------------------------ | ---------------- | ------------------------------------------------------------------ |
| `load_adverts/2`         | `list_adverts/2` | `Admin.AdvertController.index`                                     |
| `load_advert_for_edit/2` | `edit_advert/2`  | `Admin.AdvertController.edit`, `Admin.Advert.ImageController.edit` |

`record_click/1` is click-tracking support for the show request, not the
request's context action, and remains unchanged.

### `Philomena.ArtistLinks`

| Current                       | Target                              | Primary caller                                   |
| ----------------------------- | ----------------------------------- | ------------------------------------------------ |
| `load_artist_links_index/3`   | `list_admin_artist_links/3`         | `Admin.ArtistLinkController.index`               |
| `load_artist_link_for_new/2`  | `new_artist_link/2`                 | `Profile.ArtistLinkController.new`               |
| `load_artist_link_for_show/3` | `show_artist_link/3`                | `Profile.ArtistLinkController.show`              |
| `load_artist_link_for_edit/3` | `edit_artist_link/3`                | `Profile.ArtistLinkController.edit`              |
| `verify_artist_link/2`        | `create_artist_link_verification/2` | `Admin.ArtistLink.VerificationController.create` |
| `contact_artist_link/2`       | `create_artist_link_contact/2`      | `Admin.ArtistLink.ContactController.create`      |
| `reject_artist_link/2`        | `create_artist_link_reject/2`       | `Admin.ArtistLink.RejectController.create`       |

The existing `list_artist_links/2`, `create_artist_link/3`, and
`update_artist_link/4` already match their callers.

### `Philomena.Autocomplete`

| Current              | Target                         | Primary caller                         |
| -------------------- | ------------------------------ | -------------------------------------- |
| `get_autocomplete/0` | `show_compiled_autocomplete/0` | `Autocomplete.CompiledController.show` |

### `Philomena.Badges`

| Current                 | Target               | Primary caller                                                   |
| ----------------------- | -------------------- | ---------------------------------------------------------------- |
| `load_badges/2`         | `list_badges/2`      | `Admin.BadgeController.index`                                    |
| `load_badge_for_edit/2` | `edit_badge/2`       | `Admin.BadgeController.edit`, `Admin.Badge.ImageController.edit` |
| `load_badge_users/3`    | `list_badge_users/3` | `Admin.Badge.UserController.index`                               |
| `load_award_for_new/2`  | `new_award/2`        | `Profile.AwardController.new`                                    |
| `award_badge/3`         | `create_award/3`     | `Profile.AwardController.create`                                 |
| `load_award_for_edit/3` | `edit_award/3`       | `Profile.AwardController.edit`                                   |
| `update_badge_award/4`  | `update_award/4`     | `Profile.AwardController.update`                                 |
| `revoke_badge_award/3`  | `delete_award/3`     | `Profile.AwardController.delete`                                 |

### `Philomena.Bans`

| Current                           | Target                    | Primary caller                         |
| --------------------------------- | ------------------------- | -------------------------------------- |
| `admin_fingerprint_bans/3`        | `list_fingerprint_bans/3` | `Admin.FingerprintBanController.index` |
| `load_fingerprint_ban_for_edit/2` | `edit_fingerprint_ban/2`  | `Admin.FingerprintBanController.edit`  |
| `admin_subnet_bans/3`             | `list_subnet_bans/3`      | `Admin.SubnetBanController.index`      |
| `load_subnet_ban_for_edit/2`      | `edit_subnet_ban/2`       | `Admin.SubnetBanController.edit`       |
| `admin_user_bans/3`               | `list_user_bans/3`        | `Admin.UserBanController.index`        |
| `load_user_ban_for_edit/2`        | `edit_user_ban/2`         | `Admin.UserBanController.edit`         |

The existing `new_*_ban`, `create_*_ban`, `update_*_ban`, and `delete_*_ban`
operations already preserve their controller verbs.

### `Philomena.Channels`

| Current                   | Target                          | Primary caller                          |
| ------------------------- | ------------------------------- | --------------------------------------- |
| `load_channels/4`         | `list_channels/4`               | `ChannelController.index`               |
| `visit_channel/2`         | `show_channel/2`                | `ChannelController.show`                |
| `clear_notification/2`    | `create_channel_read/2`         | `Channel.ReadController.create`         |
| `subscribe/2`             | `create_channel_subscription/2` | `Channel.SubscriptionController.create` |
| `unsubscribe/2`           | `delete_channel_subscription/2` | `Channel.SubscriptionController.delete` |
| `load_channel_for_edit/2` | `edit_channel/2`                | `ChannelController.edit`                |

### `Philomena.Comments`

| Current                     | Target                     | Primary caller                                                       |
| --------------------------- | -------------------------- | -------------------------------------------------------------------- |
| `load_comment/2`            | `show_comment/2`           | `Api.Json.CommentController.show`                                    |
| `search_comments/4`         | `query_comments/4`         | `CommentController.index`, `Api.Json.Search.CommentController.index` |
| `paginate_image_comments/3` | `list_image_comments/3`    | `Image.CommentController.index`                                      |
| `find_comment_page/4`       | `list_comment_page/4`      | `Image.CommentController.index`                                      |
| `load_comment_for_show/3`   | `show_comment/3`           | `Image.CommentController.show`                                       |
| `load_comment_for_edit/3`   | `edit_comment/3`           | `Image.CommentController.edit`                                       |
| `comment_history/3`         | `list_comment_history/3`   | `Image.Comment.HistoryController.index`                              |
| `hide_comment/4`            | `create_comment_hide/4`    | `Image.Comment.HideController.create`                                |
| `unhide_comment/3`          | `delete_comment_hide/3`    | `Image.Comment.HideController.delete`                                |
| `destroy_comment/3`         | `create_comment_delete/3`  | `Image.Comment.DeleteController.create`                              |
| `approve_comment/3`         | `create_comment_approve/3` | `Image.Comment.ApproveController.create`                             |

`load_image/3` is a helper that does not directly correspond to the
rendered resource.

### `Philomena.Commissions`

| Current                      | Target               | Primary caller                           |
| ---------------------------- | -------------------- | ---------------------------------------- |
| `load_directory/3`           | `list_commissions/3` | `CommissionController.index`             |
| `load_commission_for_show/2` | `show_commission/2`  | `Profile.CommissionController.show`      |
| `load_commission_for_edit/2` | `edit_commission/2`  | `Profile.CommissionController.edit`      |
| `load_item_for_edit/3`       | `edit_item/3`        | `Profile.Commission.ItemController.edit` |

The existing commission/item `new_*`, `create_*`, `update_*`, and `delete_*`
operations already match their callers.

### `Philomena.Conversations`

| Current                     | Target                       | Primary caller                                                    |
| --------------------------- | ---------------------------- | ----------------------------------------------------------------- |
| `load_conversation_index/3` | `list_conversations/3`       | `ConversationController.index`                                    |
| `load_conversation_page/3`  | `show_conversation/3`        | `ConversationController.show`                                     |
| `set_conversation_read/3`   | `update_conversation_read/3` | `Conversation.ReadController.create` (also used for delete/false) |
| `set_conversation_hidden/3` | `update_conversation_hide/3` | `Conversation.HideController.create` (also used for delete/false) |
| `approve_message/3`         | `create_message_approve/3`   | `Conversation.Message.ApproveController.create`                   |

`set_conversation_read/3` and `set_conversation_hidden/3` are modeled as
updates, but exposed as create/delete actions by the controller.

### `Philomena.DnpEntries`

| Current                     | Target                          | Primary caller                               |
| --------------------------- | ------------------------------- | -------------------------------------------- |
| `load_admin_dnp_entries/3`  | `list_admin_dnp_entries/3`      | `Admin.DnpEntryController.index`             |
| `load_dnp_listing/3`        | `list_dnp_entries/3`            | `DnpEntryController.index`                   |
| `load_dnp_entry_page/3`     | `show_dnp_entry/3`              | `DnpEntryController.show`                    |
| `load_new_dnp_entry/2`      | `new_dnp_entry/2`               | `DnpEntryController.new`                     |
| `load_dnp_entry_for_edit/2` | `edit_dnp_entry/2`              | `DnpEntryController.edit`                    |
| `transition_dnp_entry/3`    | `create_dnp_entry_transition/3` | `Admin.DnpEntry.TransitionController.create` |

### `Philomena.Donations`

| Current                 | Target                  | Primary caller                       |
| ----------------------- | ----------------------- | ------------------------------------ |
| `load_donations/2`      | `list_donations/2`      | `Admin.DonationController.index`     |
| `load_user_donations/2` | `show_user_donations/2` | `Admin.Donation.UserController.show` |

### `Philomena.DuplicateReports`

| Current                             | Target                                     | Primary caller                                                                |
| ----------------------------------- | ------------------------------------------ | ----------------------------------------------------------------------------- |
| `load_duplicate_report_index/3`     | `list_duplicate_reports/3`                 | `DuplicateReportController.index`                                             |
| `load_duplicate_report/2`           | `show_duplicate_report/2`                  | `DuplicateReportController.show`                                              |
| `new_reverse_search/1`              | `create_reverse_search/1`                  | `Search.ReverseController.create`                                             |
| `search_duplicates/3`               | `create_reverse_search/3`                  | `Search.ReverseController.create`, `Api.Json.Search.ReverseController.create` |
| `accept_duplicate_report/2`         | `create_duplicate_report_accept/2`         | `DuplicateReport.AcceptController.create`                                     |
| `accept_reverse_duplicate_report/2` | `create_duplicate_report_accept_reverse/2` | `DuplicateReport.AcceptReverseController.create`                              |
| `claim_duplicate_report/2`          | `create_duplicate_report_claim/2`          | `DuplicateReport.ClaimController.create`                                      |
| `unclaim_duplicate_report/2`        | `delete_duplicate_report_claim/2`          | `DuplicateReport.ClaimController.delete`                                      |
| `reject_duplicate_report/2`         | `create_duplicate_report_reject/2`         | `DuplicateReport.RejectController.create`                                     |

The `new_reverse_search/1` and `search_duplicates/3` targets intentionally
share the route resource but remain separate arities/contracts.

### `Philomena.Filters`

| Current                   | Target                    | Primary caller                                                     |
| ------------------------- | ------------------------- | ------------------------------------------------------------------ |
| `index_filters/2`         | `list_filters/2`          | `FilterController.index`                                           |
| `search_filters/3`        | `query_filters/3`         | `FilterController.index`, `Api.Json.Search.FilterController.index` |
| `load_filter/2`           | `show_filter/2`           | `Api.Json.FilterController.show`                                   |
| `load_filter_page/2`      | `show_filter_page/2`      | `FilterController.show`                                            |
| `load_filter_for_edit/2`  | `edit_filter/2`           | `FilterController.edit`                                            |
| `switch_current_filter/2` | `update_current_filter/2` | `Filter.CurrentController.update`                                  |
| `hide_tag/3`              | `create_filter_hide/3`    | `Filter.HideController.create`                                     |
| `unhide_tag/3`            | `delete_filter_hide/3`    | `Filter.HideController.delete`                                     |
| `make_filter_public/2`    | `create_filter_public/2`  | `Filter.PublicController.create`                                   |
| `spoiler_tag/3`           | `create_filter_spoiler/3` | `Filter.SpoilerController.create`                                  |
| `unspoiler_tag/3`         | `delete_filter_spoiler/3` | `Filter.SpoilerController.delete`                                  |

### `Philomena.Forums`

| Current                 | Target                        | Primary caller                                                 |
| ----------------------- | ----------------------------- | -------------------------------------------------------------- |
| `load_forum_index/2`    | `list_forums/2`               | `ForumController.index`, `Api.Json.ForumController.index`      |
| `load_admin_forums/1`   | `list_admin_forums/1`         | `Admin.ForumController.index`                                  |
| `load_forum/2`          | `show_forum/2`                | `Api.Json.ForumController.show`                                |
| `load_forum_show/3`     | `show_forum_page/3`           | `ForumController.show`, `Api.Json.Forum.TopicController.index` |
| `subscribe/2`           | `create_forum_subscription/2` | `Forum.SubscriptionController.create`                          |
| `unsubscribe/2`         | `delete_forum_subscription/2` | `Forum.SubscriptionController.delete`                          |
| `load_forum_for_edit/2` | `edit_forum/2`                | `Admin.ForumController.edit`                                   |

### `Philomena.Galleries`

| Current                       | Target                          | Primary caller                            |
| ----------------------------- | ------------------------------- | ----------------------------------------- |
| `load_gallery_index/3`        | `list_galleries/3`              | `GalleryController.index`                 |
| `search_galleries/3`          | `query_galleries/3`             | `Api.Json.Search.GalleryController.index` |
| `load_gallery_page/3`         | `show_gallery/3`                | `GalleryController.show`                  |
| `load_gallery_for_edit/2`     | `edit_gallery/2`                | `GalleryController.edit`                  |
| `add_image_to_gallery/3`      | `create_gallery_image/3`        | `Gallery.ImageController.create`          |
| `remove_image_from_gallery/3` | `delete_gallery_image/3`        | `Gallery.ImageController.delete`          |
| `reorder_gallery/3`           | `update_gallery_order/3`        | `Gallery.OrderController.update`          |
| `mark_gallery_read/2`         | `create_gallery_read/2`         | `Gallery.ReadController.create`           |
| `subscribe_gallery/2`         | `create_gallery_subscription/2` | `Gallery.SubscriptionController.create`   |
| `unsubscribe_gallery/2`       | `delete_gallery_subscription/2` | `Gallery.SubscriptionController.delete`   |

### `Philomena.Images`

| Current                    | Target                            | Primary caller                                                     |
| -------------------------- | --------------------------------- | ------------------------------------------------------------------ |
| `load_image_index/2`       | `list_images/2`                   | `ImageController.index`                                            |
| `search_images/2,3`        | `query_images/2,3`                | `SearchController.index`, `Api.Json.Search.ImageController.index`  |
| `featured_image/2`         | `show_featured_image/2`           | `Api.Json.Image.FeaturedController.show`                           |
| `load_api_image/2`         | `show_api_image/2`                | `Api.Json.ImageController.show`, `Api.Json.OembedController.index` |
| `load_image_for_show/2`    | `show_image/2`                    | `ImageController` show loader                                      |
| `load_image_page/3`        | `show_image_page/3`               | `ImageController.show`                                             |
| `watched_images/2`         | `list_watched_images/2`           | `Api.Rss.WatchedController.index`                                  |
| `load_approval_queue/2`    | `list_approval_queue/2`           | `Admin.ApprovalController.index`                                   |
| `upload_image/3`           | `create_image/3`                  | `ImageController.create`, `Api.Json.ImageController.create`        |
| `approve_image/2`          | `create_image_approve/2`          | `Image.ApproveController.create`                                   |
| `update_anonymous/2`       | `update_image_anonymous/2`        | `Image.AnonymousController.create` (also used for delete)          |
| `set_comment_locked/3`     | `update_image_comment_lock/3`     | `Image.CommentLockController.create` (also used for delete)        |
| `hide_image/3`             | `create_image_hide/3`             | `Image.DeleteController.create`                                    |
| `update_hide_reason/3`     | `update_image_hide/3`             | `Image.DeleteController.update`                                    |
| `unhide_image/2`           | `delete_image_hide/2`             | `Image.DeleteController.delete`                                    |
| `destroy_image/2`          | `create_image_destroy/2`          | `Image.DestroyController.create`                                   |
| `create_fave/2`            | `create_image_fave/2`             | `Image.FaveController.create`                                      |
| `delete_fave/2`            | `delete_image_fave/2`             | `Image.FaveController.delete`                                      |
| `image_fave_list/2`        | `list_image_faves/2`              | `Image.FavoriteController.index`                                   |
| `feature_image/2`          | `create_image_feature/2`          | `Image.FeatureController.create`                                   |
| `update_file/3`            | `update_image_file/3`             | `Image.FileController.update`                                      |
| `remove_image_hash/2`      | `delete_image_hash/2`             | `Image.HashController.delete`                                      |
| `mark_image_read/2`        | `create_image_read/2`             | `Image.ReadController.create`                                      |
| `repair_image/2`           | `create_image_repair/2`           | `Image.RepairController.create`                                    |
| `load_new_image/1`         | `new_image/1`                     | `ImageController.new`                                              |
| `update_scratchpad/3`      | `update_image_scratchpad/3`       | `Image.ScratchpadController.update`                                |
| `update_description/3`     | `update_image_description/3`      | `Image.DescriptionController.update`                               |
| `update_sources/3`         | `update_image_sources/3`          | `Image.SourceController.update`                                    |
| `remove_source_history/2`  | `delete_image_source_history/2`   | `Image.SourceHistoryController.delete`                             |
| `subscribe_image/2`        | `create_image_subscription/2`     | `Image.SubscriptionController.create`                              |
| `unsubscribe_image/2`      | `delete_image_subscription/2`     | `Image.SubscriptionController.delete`                              |
| `update_tags/3`            | `update_image_tags/3`             | `Image.TagController.update`                                       |
| `update_locked_tags/3`     | `update_image_locked_tags/3`      | `Image.TagLockController.update`                                   |
| `set_tag_locked/3`         | `update_image_tag_lock/3`         | `Image.TagLockController.create` (also used for delete)            |
| `set_description_locked/3` | `update_image_description_lock/3` | `Image.DescriptionLockController.create` (also used for delete)    |
| `delete_user_vote/2`       | `create_image_tamper/2`           | `Image.TamperController.create`                                    |
| `update_uploader/3`        | `update_image_uploader/3`         | `Image.UploaderController.update`                                  |
| `batch_update_tags/2`      | `update_batch_tags/2`             | `Admin.Batch.TagController.update`                                 |
| `create_vote/3`            | `create_image_vote/3`             | `Image.VoteController.create`                                      |
| `delete_vote/2`            | `delete_image_vote/2`             | `Image.VoteController.delete`                                      |
| `create_image_hide/2`      | `create_image_user_hide/2`        | `Image.HideController.create`                                      |
| `delete_image_hide/2`      | `delete_image_user_hide/2`        | `Image.HideController.delete`                                      |
| `find_consecutive_image/3` | `list_image_navigation/3`         | `Image.NavigateController.index`                                   |
| `find_image_index_page/3`  | `list_image_index_page/3`         | `Image.NavigateController.index`                                   |
| `related_images/3`         | `list_related_images/3`           | `Image.RelatedController.index`                                    |
| `random_image_id/2`        | `list_random_images/2`            | `Image.RandomController.index`                                     |

`change_image/*`, `load_hidable_image/*`, `tag_list/1`, interaction helpers,
and indexing/worker functions are supporting APIs rather than endpoint actions
and remain unchanged.

`update_anonymous/2`, `set_comment_locked/3`, `set_tag_locked/3`, and
`set_description_locked/3` are modeled as updates, but exposed as
create/delete actions by the controller.

### `Philomena.ModNotes`

| Current                    | Target             | Primary caller                  |
| -------------------------- | ------------------ | ------------------------------- |
| `load_mod_note_index/4`    | `list_mod_notes/4` | `Admin.ModNoteController.index` |
| `load_mod_note_for_edit/2` | `edit_mod_note/2`  | `Admin.ModNoteController.edit`  |

### `Philomena.ModerationLogs`

| Current                  | Target                   | Primary caller                  |
| ------------------------ | ------------------------ | ------------------------------- |
| `load_moderation_logs/2` | `list_moderation_logs/2` | `ModerationLogController.index` |

### `Philomena.Notifications`

| Current                  | Target                                | Primary caller                         |
| ------------------------ | ------------------------------------- | -------------------------------------- |
| `load_unread/2`          | `list_unread_notifications/2`         | `NotificationController.index`         |
| `load_unread_category/3` | `show_unread_notification_category/3` | `Notification.CategoryController.show` |

### `Philomena.Polls`

| Current                | Target        | Primary caller              |
| ---------------------- | ------------- | --------------------------- |
| `load_poll_for_edit/3` | `edit_poll/3` | `Topic.PollController.edit` |

### `Philomena.Posts`

| Current                | Target                  | Primary caller                                                 |
| ---------------------- | ----------------------- | -------------------------------------------------------------- |
| `load_post/2`          | `show_post/2`           | `Api.Json.PostController.show`                                 |
| `load_topic_post/4`    | `show_topic_post/4`     | `Api.Json.Forum.Topic.PostController.show`                     |
| `search_posts/3`       | `query_posts/3`         | `PostController.index`, `Api.Json.Search.PostController.index` |
| `load_post_for_edit/4` | `edit_post/4`           | `Topic.PostController.edit`                                    |
| `hide_post/5`          | `create_post_hide/5`    | `Topic.Post.HideController.create`                             |
| `unhide_post/4`        | `delete_post_hide/4`    | `Topic.Post.HideController.delete`                             |
| `destroy_post/4`       | `create_post_delete/4`  | `Topic.Post.DeleteController.create`                           |
| `approve_post/4`       | `create_post_approve/4` | `Topic.Post.ApproveController.create`                          |
| `post_history/4`       | `list_post_history/4`   | `Topic.Post.HistoryController.index`                           |

### `Philomena.Profiles`

| Current                      | Target                               | Primary caller                      |
| ---------------------------- | ------------------------------------ | ----------------------------------- |
| `load_profile_page/4`        | `show_profile/4`                     | `ProfileController.show`            |
| `load_ip_history/3`          | `list_profile_ip_history/3`          | `Profile.IpHistoryController.index` |
| `load_fingerprint_history/3` | `list_profile_fingerprint_history/3` | `Profile.FpHistoryController.index` |

The metadata sections loaded by `load_profile_page/2` are presentation details,
not separate request-facing actions.

### `Philomena.Reports`

| Current               | Target                  | Primary caller                        |
| --------------------- | ----------------------- | ------------------------------------- |
| `load_user_reports/2` | `list_user_reports/2`   | `ReportController.index`              |
| `load_report_index/3` | `list_reports/3`        | `Admin.ReportController.index`        |
| `load_report/2`       | `show_report/2`         | `Admin.ReportController.show`         |
| `claim_report/2`      | `create_report_claim/2` | `Admin.Report.ClaimController.create` |
| `unclaim_report/2`    | `delete_report_claim/2` | `Admin.Report.ClaimController.delete` |
| `close_report/2`      | `create_report_close/2` | `Admin.Report.CloseController.create` |

### `Philomena.Rules`

| Current                | Target        | Primary caller        |
| ---------------------- | ------------- | --------------------- |
| `load_new_rule/1`      | `new_rule/1`  | `RuleController.new`  |
| `load_rule_for_show/2` | `show_rule/2` | `RuleController.show` |
| `load_rule_for_edit/2` | `edit_rule/2` | `RuleController.edit` |

`list_rules_for/1`, `list_rule_versions/1`, `create_rule/2`, and
`update_rule/3` already match their controller verbs.

### `Philomena.SiteNotices`

| Current                       | Target                | Primary caller                     |
| ----------------------------- | --------------------- | ---------------------------------- |
| `load_site_notices/2`         | `list_site_notices/2` | `Admin.SiteNoticeController.index` |
| `load_site_notice_for_edit/2` | `edit_site_notice/2`  | `Admin.SiteNoticeController.edit`  |

### `Philomena.SourceChanges`

| Current                        | Target                              | Primary caller                                    |
| ------------------------------ | ----------------------------------- | ------------------------------------------------- |
| `image_source_changes/4`       | `list_image_source_changes/4`       | `Image.SourceChangeController.index`              |
| `user_source_changes/4`        | `list_user_source_changes/4`        | `Profile.SourceChangeController.index`            |
| `ip_source_changes/4`          | `list_ip_source_changes/4`          | `IpProfile.SourceChangeController.index`          |
| `fingerprint_source_changes/4` | `list_fingerprint_source_changes/4` | `FingerprintProfile.SourceChangeController.index` |

### `Philomena.StaticPages`

| Current                | Target                | Primary caller                 |
| ---------------------- | --------------------- | ------------------------------ |
| `load_page_listing/1`  | `list_pages/1`        | `PageController.index`         |
| `load_page_for_show/2` | `show_page/2`         | `PageController.show`          |
| `load_page_history/2`  | `list_page_history/2` | `Page.HistoryController.index` |
| `load_page_for_edit/2` | `edit_page/2`         | `PageController.edit`          |

### `Philomena.TagChanges`

| Current                                 | Target                                   | Primary caller                                         |
| --------------------------------------- | ---------------------------------------- | ------------------------------------------------------ |
| `image_tag_changes/4`                   | `list_image_tag_changes/4`               | `Image.TagChangeController.index`                      |
| `user_tag_changes/4`                    | `list_user_tag_changes/4`                | `Profile.TagChangeController.index`                    |
| `ip_tag_changes/4`                      | `list_ip_tag_changes/4`                  | `IpProfile.TagChangeController.index`                  |
| `fingerprint_tag_changes/4`             | `list_fingerprint_tag_changes/4`         | `FingerprintProfile.TagChangeController.index`         |
| `tag_tag_changes/4`                     | `list_tag_tag_changes/4`                 | `Tag.TagChangeController.index`                        |
| `revert_tag_changes/2`                  | `create_tag_change_revert/2`             | `TagChange.RevertController.create`                    |
| `full_revert_user_tag_changes/2`        | `create_user_tag_change_revert/2`        | `Profile.TagChange.RevertController.create`            |
| `full_revert_ip_tag_changes/2`          | `create_ip_tag_change_revert/2`          | `IpProfile.TagChange.RevertController.create`          |
| `full_revert_fingerprint_tag_changes/2` | `create_fingerprint_tag_change_revert/2` | `FingerprintProfile.TagChange.RevertController.create` |

`list_tag_changes/3` already has the requested name; it is shown as a no-op
row to make the collection naming decision explicit.

### `Philomena.Tags`

| Current                     | Target                 | Primary caller                                               |
| --------------------------- | ---------------------- | ------------------------------------------------------------ |
| `search_tags/3`             | `query_tags/3`         | `TagController.index`, `Api.Json.Search.TagController.index` |
| `load_tag/2`                | `show_tag/2`           | `Api.Json.TagController.show`                                |
| `load_tag_page/3`           | `show_tag_page/3`      | `TagController.show`                                         |
| `load_tag_for_edit/2`       | `edit_tag/2`           | `TagController.edit`                                         |
| `load_tag_image_for_edit/2` | `edit_tag_image/2`     | `Tag.ImageController.edit`                                   |
| `load_tag_alias_for_edit/2` | `edit_tag_alias/2`     | `Tag.AliasController.edit`                                   |
| `tag_detail/2`              | `list_tag_details/2`   | `Tag.DetailController.index`                                 |
| `alias_tag/3`               | `update_tag_alias/3`   | `Tag.AliasController.update`                                 |
| `unalias_tag/2`             | `delete_tag_alias/2`   | `Tag.AliasController.delete`                                 |
| `remove_tag_image/2`        | `delete_tag_image/2`   | `Tag.ImageController.delete`                                 |
| `reindex_tag_by_slug/2`     | `create_tag_reindex/2` | `Tag.ReindexController.create`                               |
| `watch_tag/2`               | `create_tag_watch/2`   | `Tag.WatchController.create`                                 |
| `unwatch_tag/2`             | `delete_tag_watch/2`   | `Tag.WatchController.delete`                                 |

`list_tags_by_ids/1` is already an explicit list operation; `update_tag/3`,
`update_tag_image/3`, and `delete_tag/2` already match their callers.

### `Philomena.Topics`

| Current                | Target                        | Primary caller                                                      |
| ---------------------- | ----------------------------- | ------------------------------------------------------------------- |
| `load_forum_topic/4`   | `show_forum_topic/4`          | `Api.Json.Forum.TopicController.show`                               |
| `load_topic/3`         | `show_topic/3`                | `Api.Json.Forum.TopicController.show`                               |
| `load_topic_page/5`    | `show_topic_page/5`           | `TopicController.show`, `Api.Json.Forum.Topic.PostController.index` |
| `load_new_topic/2`     | `new_topic/2`                 | `TopicController.new`                                               |
| `update_topic_title/4` | `update_topic/4`              | `TopicController.update`                                            |
| `hide_topic/4`         | `create_topic_hide/4`         | `Topic.HideController.create`                                       |
| `unhide_topic/3`       | `delete_topic_hide/3`         | `Topic.HideController.delete`                                       |
| `move_topic/4`         | `create_topic_move/4`         | `Topic.MoveController.create`                                       |
| `mark_topic_read/3`    | `create_topic_read/3`         | `Topic.ReadController.create`                                       |
| `stick_topic/3`        | `create_topic_stick/3`        | `Topic.StickController.create`                                      |
| `unstick_topic/3`      | `delete_topic_stick/3`        | `Topic.StickController.delete`                                      |
| `lock_topic/4`         | `create_topic_lock/4`         | `Topic.LockController.create`                                       |
| `unlock_topic/3`       | `delete_topic_lock/3`         | `Topic.LockController.delete`                                       |
| `subscribe/3`          | `create_topic_subscription/3` | `Topic.SubscriptionController.create`                               |
| `unsubscribe/3`        | `delete_topic_subscription/3` | `Topic.SubscriptionController.delete`                               |

### `Philomena.UserFingerprints`

| Current                      | Target                       | Primary caller                      |
| ---------------------------- | ---------------------------- | ----------------------------------- |
| `load_fingerprint_profile/2` | `show_fingerprint_profile/2` | `FingerprintProfileController.show` |

### `Philomena.UserIps`

| Current             | Target              | Primary caller             |
| ------------------- | ------------------- | -------------------------- |
| `load_ip_profile/2` | `show_ip_profile/2` | `IpProfileController.show` |

### `Philomena.Users`

| Current                               | Target                         | Primary caller                                           |
| ------------------------------------- | ------------------------------ | -------------------------------------------------------- |
| `load_profile_by_id/2`                | `show_profile/2`               | `Api.Json.ProfileController.show`                        |
| `search_users/3`                      | `query_users/3`                | `Admin.UserController.index`                             |
| `load_user_for_edit/2`                | `edit_user/2`                  | `Admin.UserController.edit`                              |
| `update_user_details/3`               | `update_user/3`                | `Admin.UserController.update`                            |
| `load_profile_for_description_edit/2` | `edit_profile_description/2`   | `Profile.DescriptionController.edit`                     |
| `update_description/3`                | `update_profile_description/3` | `Profile.DescriptionController.update`                   |
| `load_profile_for_scratchpad_edit/2`  | `edit_profile_scratchpad/2`    | `Profile.ScratchpadController.edit`                      |
| `update_scratchpad/3`                 | `update_profile_scratchpad/3`  | `Profile.ScratchpadController.update`                    |
| `load_alias_matches/2`                | `list_profile_aliases/2`       | `Profile.AliasController.index`                          |
| `load_user_for_avatar_edit/1`         | `edit_avatar/1`                | `AvatarController.edit`                                  |
| `remove_avatar/1`                     | `delete_avatar/1`              | `AvatarController.delete`                                |
| `load_user_for_rename/1`              | `edit_name/1`                  | `Registration.NameController.edit`                       |
| `change_user_password/1,2`            | `edit_password/1,2`            | `PasswordController.edit`, `RegistrationController.edit` |
| `admin_reactivate_user/2`             | `create_user_activation/2`     | `Admin.User.ActivationController.create`                 |
| `admin_deactivate_user/2`             | `delete_user_activation/2`     | `Admin.User.ActivationController.delete`                 |
| `admin_reset_api_key/2`               | `delete_user_api_key/2`        | `Admin.User.ApiKeyController.delete`                     |
| `admin_remove_avatar/2`               | `delete_user_avatar/2`         | `Admin.User.AvatarController.delete`                     |
| `admin_wipe_downvotes/2`              | `delete_user_downvotes/2`      | `Admin.User.DownvoteController.delete`                   |
| `load_user_for_erase/2`               | `new_user_erase/2`             | `Admin.User.EraseController.new`                         |
| `admin_erase_user/2`                  | `create_user_erase/2`          | `Admin.User.EraseController.create`                      |
| `load_user_for_force_filter/2`        | `new_user_force_filter/2`      | `Admin.User.ForceFilterController.new`                   |
| `admin_force_filter/3`                | `create_user_force_filter/3`   | `Admin.User.ForceFilterController.create`                |
| `admin_unforce_filter/2`              | `delete_user_force_filter/2`   | `Admin.User.ForceFilterController.delete`                |
| `admin_unlock_user/2`                 | `create_user_unlock/2`         | `Admin.User.UnlockController.create`                     |
| `admin_verify_user/2`                 | `create_user_verification/2`   | `Admin.User.VerificationController.create`               |
| `admin_unverify_user/2`               | `delete_user_verification/2`   | `Admin.User.VerificationController.delete`               |
| `admin_wipe_votes/2`                  | `delete_user_votes/2`          | `Admin.User.VoteController.delete`                       |
| `admin_wipe_user/2`                   | `create_user_wipe/2`           | `Admin.User.WipeController.create`                       |
| `clear_recent_filters/1`              | `delete_recent_filters/1`      | `Filter.ClearRecentController.delete`                    |
| `change_user_registration/2`          | `new_registration/2`           | `RegistrationController.new`                             |
| `register_user/1`                     | `create_registration/1`        | `RegistrationController.create`                          |
| `apply_user_email/3`                  | `create_email/3`               | `Registration.EmailController.create`                    |
| `update_user_email/2`                 | `show_email/2`                 | `Registration.EmailController.show`                      |
| `reset_user_password/2`               | `update_password/2`            | `PasswordController.update`                              |
| `update_user_password/3`              | `update_password/3`            | `Registration.PasswordController.update`                 |
| `confirm_user/1`                      | `update_confirmation/1`        | `ConfirmationController.update`                          |
| `reactivate_user_by_token/1`          | `create_reactivation/1`        | `ReactivationController.create`                          |
| `unlock_user_by_token/1`              | `show_unlock/1`                | `UnlockController.show`                                  |
| `deactivate_account/2`                | `delete_deactivation/2`        | `DeactivationController.delete`                          |
| `consume_totp_token/2`                | `create_session_totp/2`        | `Session.TotpController.create`                          |
| `setup_totp_secret/1`                 | `edit_totp/1`                  | `Registration.TotpController.edit`                       |

Authentication lookups, token/session primitives, changeset constructors,
mail delivery, preview preload, staff-category lookup, and other generic
service helpers called while handling these requests remain unchanged.

### Contexts with no request-facing rename

| Context                      | Reason                                                                             |
| ---------------------------- | ---------------------------------------------------------------------------------- |
| `Philomena.ImageFaves`       | Exposes aggregate transaction composition only.                                    |
| `Philomena.ImageHides`       | Exposes aggregate transaction composition only.                                    |
| `Philomena.ImageIntensities` | Exposes media-derived-data persistence only.                                       |
| `Philomena.ImageVotes`       | Exposes aggregate transaction composition only.                                    |
| `Philomena.Interactions`     | Personalization data helper, not an endpoint operation.                            |
| `Philomena.PollOptions`      | Poll-owned loader/helper, not called by a controller.                              |
| `Philomena.PollVotes`        | Controller operations are already `list_votes`, `create_votes`, and `delete_vote`. |
| `Philomena.SiteStatistics`   | Maintenance/statistics service, not an endpoint operation.                         |
| `Philomena.UserNameChanges`  | History service consumed by profile assembly.                                      |
| `Philomena.UserStatistics`   | Counter transaction service only.                                                  |
| `Philomena.Versions`         | History/transaction service consumed by owning contexts.                           |

## Mechanical execution and verification

1. Apply each mapping at its listed arity, preserving clauses, specs, docs,
   examples, result contracts, and behavior. Do not merge functions merely
   because their target names are similar; retain the API/page/admin
   distinctions recorded above.
2. Update every in-repository caller, including context-to-context calls,
   workers only when they reference a renamed request operation, fixtures,
   tests, doctests, and comments. Search for both old and new names so no
   stale call remains.
3. Run `mix format --check-formatted`, the affected context/controller tests,
   and the affected frontend/API route tests. Finish with the repository's
   normal `scripts/philomena.sh test` sequence when the mechanical rename is
   complete.

## Completion criteria

- Every listed current function has the listed target name at the same arity.
- No request-facing `load_*`, bespoke admin verb, or route-semantic operation
  remains outside the deliberate exclusions or already target-shaped APIs.
- All controller, context, test, documentation, and example references use
  the new names.
- No behavior, authorization, loading order, result shape, or route changes
  are introduced by the rename pass.
