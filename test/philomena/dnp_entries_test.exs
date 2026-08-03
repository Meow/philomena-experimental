defmodule Philomena.DnpEntriesTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.DnpEntries` functions.

  These pin the `DnpListing` page shape and its "mine" vs public scoping, the
  `:show`/`:edit`/`:update` authorization on the possibly-nil entry load
  (including the plain/moderator-unauthorized vs admin-not-found split on an
  unknown id), the mod-note staff gate, the selectable-tag gating that turns an
  actor with nothing to file against into `{:error, :unauthorized}`, the ban
  ordering on the write paths, and the bespoke changeset re-render shapes.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures
  import Philomena.ArtistLinksFixtures
  import Philomena.DnpEntriesFixtures
  import Philomena.ModNotesFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.DnpEntries
  alias Philomena.DnpEntries.{DnpEntry, DnpListing}
  alias Philomena.ModerationLogs.ModerationLog

  # A truthy ban value in the shape production passes; only its presence matters
  # to the write-access and not-banned checks the write paths run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  @pagination [page: 1, page_size: 25]

  defp artist_tag do
    tag_fixture(name: "artist:dnp-test-#{System.unique_integer([:positive])}")
  end

  # A confirmed user holding a verified artist link, so the user has a linked
  # tag to file a DNP request against. Returns {user, tag}.
  defp linked_user do
    user = confirmed_user_fixture()
    tag = artist_tag()
    verified_artist_link_fixture(user, tag)
    {user, tag}
  end

  defp dnp_entry_attrs(tag, attrs \\ %{}) do
    Enum.into(attrs, %{
      "tag_id" => to_string(tag.id),
      "dnp_type" => "No Edits",
      "reason" => "Test DNP reason"
    })
  end

  describe "load_dnp_listing/3" do
    test "the mine listing returns the user's own entries with the status column" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert %DnpListing{status_column: true, dnp_entries: page} =
               DnpEntries.load_dnp_listing(actor(user), %{"mine" => "1"}, @pagination)

      assert entry.id in Enum.map(page.entries, & &1.id)
    end

    test "the default listing returns only listed entries, without the status column" do
      {user, tag} = linked_user()
      listed = dnp_entry_fixture(user, tag, %{state: "listed"})

      {other, other_tag} = linked_user()
      requested = dnp_entry_fixture(other, other_tag)

      assert %DnpListing{status_column: false, dnp_entries: page} =
               DnpEntries.load_dnp_listing(actor(), %{}, @pagination)

      ids = Enum.map(page.entries, & &1.id)
      assert listed.id in ids
      refute requested.id in ids
    end

    test "the viewer's linked tags travel along for the sidebar" do
      {user, tag} = linked_user()

      assert %DnpListing{linked_tags: tags} =
               DnpEntries.load_dnp_listing(actor(user), %{}, @pagination)

      assert tag.id in Enum.map(tags, & &1.id)
    end

    test "an anonymous viewer has no linked tags" do
      assert %DnpListing{linked_tags: []} = DnpEntries.load_dnp_listing(actor(), %{}, @pagination)
    end
  end

  describe "load_dnp_entry/2" do
    test "loads a listed entry for an anonymous viewer, with the tag preloaded" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag, %{state: "listed"})

      assert {:ok, loaded} = DnpEntries.load_dnp_entry(actor(), to_string(entry.id))
      assert loaded.id == entry.id
      refute match?(%Ecto.Association.NotLoaded{}, loaded.tag)
    end

    test "the requesting user may load their own not-yet-listed entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:ok, loaded} = DnpEntries.load_dnp_entry(actor(user), to_string(entry.id))
      assert loaded.id == entry.id
    end

    test "an unrelated user may not load a still-requested entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.load_dnp_entry(actor(confirmed_user_fixture()), to_string(entry.id)) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not-found for every signed-in role" do
      assert DnpEntries.load_dnp_entry(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert DnpEntries.load_dnp_entry(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert DnpEntries.load_dnp_entry(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is not-found for an anonymous viewer" do
      assert DnpEntries.load_dnp_entry(actor(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert DnpEntries.load_dnp_entry(actor(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "mod_notes/3" do
    test "a moderator gets the rendered mod notes for the entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      note =
        mod_note_fixture_for(moderator_user_fixture(), %{"dnp_entry_id" => entry.id})

      # The renderer zips each note with its rendered body into a {note, body}
      # tuple, so the identity renderer pairs each note with itself.
      notes = DnpEntries.mod_notes(actor(moderator_user_fixture()), entry, & &1)
      assert is_list(notes)
      assert note.id in Enum.map(notes, fn {loaded, _body} -> loaded.id end)
    end

    test "an assistant is permitted to read mod notes" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert is_list(DnpEntries.mod_notes(actor(assistant_user_fixture()), entry, & &1))
    end

    test "a regular user gets nil" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.mod_notes(actor(confirmed_user_fixture()), entry, & &1) == nil
    end

    test "an anonymous viewer gets nil" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.mod_notes(actor(), entry, & &1) == nil
    end
  end

  describe "load_new_dnp_entry/2" do
    test "a user with a linked tag gets a changeset and their selectable tags" do
      {user, tag} = linked_user()

      assert {:ok, %{changeset: %Ecto.Changeset{}, selectable_tags: tags}} =
               DnpEntries.load_new_dnp_entry(actor(user), %{})

      assert tag.id in Enum.map(tags, & &1.id)
    end

    test "a banned actor is rejected before the tag check" do
      {user, _tag} = linked_user()

      assert DnpEntries.load_new_dnp_entry(actor(user, ban: @ban), %{}) == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before the tag check" do
      assert DnpEntries.load_new_dnp_entry(actor(nil, fingerprint: nil), %{}) ==
               {:error, :unauthorized}
    end

    test "an actor with no selectable tag is unauthorized" do
      assert DnpEntries.load_new_dnp_entry(actor(confirmed_user_fixture()), %{}) ==
               {:error, :unauthorized}
    end
  end

  describe "create_dnp_entry/2" do
    test "a user with a linked tag files a request against it" do
      {user, tag} = linked_user()

      assert {:ok, %DnpEntry{} = entry} =
               DnpEntries.create_dnp_entry(actor(user), %{"dnp_entry" => dnp_entry_attrs(tag)})

      assert entry.tag_id == tag.id
      assert entry.requesting_user_id == user.id
    end

    test "a staff member files against the top-level tag_id" do
      moderator = moderator_user_fixture()
      tag = artist_tag()

      assert {:ok, %DnpEntry{} = entry} =
               DnpEntries.create_dnp_entry(actor(moderator), %{
                 "tag_id" => to_string(tag.id),
                 "dnp_entry" => dnp_entry_attrs(tag)
               })

      assert entry.tag_id == tag.id
      assert entry.requesting_user_id == moderator.id
    end

    test "a banned actor is rejected" do
      {user, tag} = linked_user()

      assert DnpEntries.create_dnp_entry(actor(user, ban: @ban), %{
               "dnp_entry" => dnp_entry_attrs(tag)
             }) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      {user, tag} = linked_user()

      assert DnpEntries.create_dnp_entry(actor(user, fingerprint: nil), %{
               "dnp_entry" => dnp_entry_attrs(tag)
             }) == {:error, :unauthorized}
    end

    test "an actor with no selectable tag is unauthorized" do
      assert DnpEntries.create_dnp_entry(actor(confirmed_user_fixture()), %{"dnp_entry" => %{}}) ==
               {:error, :unauthorized}
    end

    test "an invalid request re-renders with the changeset and selectable tags" do
      {user, tag} = linked_user()

      assert {:error, %{changeset: %Ecto.Changeset{} = changeset, selectable_tags: tags}} =
               DnpEntries.create_dnp_entry(actor(user), %{
                 "dnp_entry" => dnp_entry_attrs(tag, %{"reason" => ""})
               })

      refute changeset.valid?
      assert tag.id in Enum.map(tags, & &1.id)
    end
  end

  describe "load_dnp_entry_for_edit/3" do
    test "a moderator loads the entry, a changeset, and the selectable tags" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:ok, %{dnp_entry: loaded, changeset: %Ecto.Changeset{}, selectable_tags: [_ | _]}} =
               DnpEntries.load_dnp_entry_for_edit(
                 actor(moderator_user_fixture()),
                 to_string(entry.id),
                 %{"tag_id" => to_string(tag.id)}
               )

      assert loaded.id == entry.id
    end

    test "a regular user may not edit an entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.load_dnp_entry_for_edit(actor(user), to_string(entry.id), %{
               "tag_id" => to_string(tag.id)
             }) == {:error, :unauthorized}
    end

    test "a non-integer id is not-found" do
      tag = artist_tag()

      assert DnpEntries.load_dnp_entry_for_edit(
               actor(moderator_user_fixture()),
               "not-a-number",
               %{
                 "tag_id" => to_string(tag.id)
               }
             ) == {:error, :not_found}
    end
  end

  describe "update_dnp_entry/3" do
    test "a moderator updates an entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:ok, %DnpEntry{}} =
               DnpEntries.update_dnp_entry(
                 actor(moderator_user_fixture()),
                 to_string(entry.id),
                 %{
                   "tag_id" => to_string(tag.id),
                   "dnp_entry" => dnp_entry_attrs(tag, %{"reason" => "Updated reason"})
                 }
               )

      assert elem(DnpEntries.load_dnp_entry(actor(moderator_user_fixture()), entry.id), 1).reason ==
               "Updated reason"
    end

    test "an invalid update re-renders with the entry, changeset, and selectable tags" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:error,
              %{
                dnp_entry: %DnpEntry{},
                changeset: %Ecto.Changeset{} = changeset,
                selectable_tags: [_ | _]
              }} =
               DnpEntries.update_dnp_entry(
                 actor(moderator_user_fixture()),
                 to_string(entry.id),
                 %{
                   "tag_id" => to_string(tag.id),
                   "dnp_entry" => dnp_entry_attrs(tag, %{"reason" => ""})
                 }
               )

      refute changeset.valid?
    end

    test "a regular user may not update an entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.update_dnp_entry(actor(user), to_string(entry.id), %{
               "tag_id" => to_string(tag.id),
               "dnp_entry" => dnp_entry_attrs(tag)
             }) == {:error, :unauthorized}
    end

    test "a non-integer id is not-found" do
      tag = artist_tag()

      assert DnpEntries.update_dnp_entry(actor(moderator_user_fixture()), "not-a-number", %{
               "tag_id" => to_string(tag.id),
               "dnp_entry" => dnp_entry_attrs(tag)
             }) == {:error, :not_found}
    end
  end

  describe "insert_dnp_entry/3" do
    test "inserts a DNP entry filed against the matching offered tag" do
      user = confirmed_user_fixture()
      tag = artist_tag()

      assert {:ok, %DnpEntry{} = entry} =
               DnpEntries.insert_dnp_entry(user, [tag], dnp_entry_attrs(tag))

      assert entry.tag_id == tag.id
      assert entry.requesting_user_id == user.id
    end

    test "a tag_id not among the offered tags records the linked-tags error" do
      user = confirmed_user_fixture()
      tag = artist_tag()

      assert {:error, %Ecto.Changeset{} = changeset} =
               DnpEntries.insert_dnp_entry(
                 user,
                 [tag],
                 dnp_entry_attrs(tag, %{"tag_id" => "999999"})
               )

      assert %{tag_id: ["must be one of your linked tags"]} = errors_on(changeset)
    end
  end

  describe "load_admin_dnp_entries/3" do
    test "an anonymous viewer is unauthorized" do
      assert DnpEntries.load_admin_dnp_entries(actor(), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "a regular user is unauthorized" do
      assert DnpEntries.load_admin_dnp_entries(actor(confirmed_user_fixture()), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "a moderator and an admin are authorized" do
      for user <- [moderator_user_fixture(), admin_user_fixture()] do
        assert {:ok, %Scrivener.Page{}} =
                 DnpEntries.load_admin_dnp_entries(actor(user), %{}, @pagination)
      end
    end

    test "the default view lists the active states and excludes listed entries" do
      {user, tag} = linked_user()
      requested = dnp_entry_fixture(user, tag)

      {other, other_tag} = linked_user()
      listed = dnp_entry_fixture(other, other_tag, %{state: "listed"})

      assert {:ok, page} =
               DnpEntries.load_admin_dnp_entries(
                 actor(moderator_user_fixture()),
                 %{},
                 @pagination
               )

      ids = Enum.map(page.entries, & &1.id)
      assert requested.id in ids
      refute listed.id in ids
    end

    test "a states list restricts to those states" do
      {user, tag} = linked_user()
      requested = dnp_entry_fixture(user, tag)

      {other, other_tag} = linked_user()
      listed = dnp_entry_fixture(other, other_tag, %{state: "listed"})

      assert {:ok, page} =
               DnpEntries.load_admin_dnp_entries(
                 actor(moderator_user_fixture()),
                 %{"states" => ["listed"]},
                 @pagination
               )

      ids = Enum.map(page.entries, & &1.id)
      assert listed.id in ids
      refute requested.id in ids
    end

    test "an eq param filters by the tag name" do
      {user, tag} = linked_user()
      wanted = dnp_entry_fixture(user, tag)

      {other, other_tag} = linked_user()
      unrelated = dnp_entry_fixture(other, other_tag)

      assert {:ok, page} =
               DnpEntries.load_admin_dnp_entries(
                 actor(moderator_user_fixture()),
                 %{"eq" => tag.name},
                 @pagination
               )

      ids = Enum.map(page.entries, & &1.id)
      assert wanted.id in ids
      refute unrelated.id in ids
    end
  end

  describe "transition_dnp_entry/3" do
    test "a moderator transitions an entry and writes a moderation log" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)
      moderator = moderator_user_fixture()

      assert {:ok, %DnpEntry{aasm_state: "acknowledged"} = transitioned} =
               DnpEntries.transition_dnp_entry(
                 actor(moderator),
                 to_string(entry.id),
                 "acknowledged"
               )

      assert transitioned.id == entry.id

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Admin.DnpEntry.Transition:create"
      assert log.subject_path == "/dnp/#{entry.id}"
      assert log.body == "Acknowledged DNP entry #{entry.id} on #{tag.name}"
    end

    test "an admin transitions an entry" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:ok, %DnpEntry{aasm_state: "rescinded"}} =
               DnpEntries.transition_dnp_entry(
                 actor(admin_user_fixture()),
                 to_string(entry.id),
                 "rescinded"
               )
    end

    test "an anonymous actor is unauthorized" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.transition_dnp_entry(actor(), to_string(entry.id), "acknowledged") ==
               {:error, :unauthorized}

      assert Repo.aggregate(ModerationLog, :count) == 0
    end

    test "a regular user is unauthorized" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert DnpEntries.transition_dnp_entry(
               actor(confirmed_user_fixture()),
               to_string(entry.id),
               "acknowledged"
             ) == {:error, :unauthorized}

      assert Repo.aggregate(ModerationLog, :count) == 0
    end

    test "an invalid target state is a rejected changeset and writes no log" do
      {user, tag} = linked_user()
      entry = dnp_entry_fixture(user, tag)

      assert {:error, %Ecto.Changeset{} = changeset} =
               DnpEntries.transition_dnp_entry(
                 actor(moderator_user_fixture()),
                 to_string(entry.id),
                 "not-a-state"
               )

      refute changeset.valid?
      assert Repo.aggregate(ModerationLog, :count) == 0
    end

    test "an unknown well-formed id is not-found for an authorized actor" do
      assert DnpEntries.transition_dnp_entry(
               actor(moderator_user_fixture()),
               "2147483647",
               "acknowledged"
             ) ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found for an authorized actor" do
      assert DnpEntries.transition_dnp_entry(
               actor(moderator_user_fixture()),
               "not-a-number",
               "acknowledged"
             ) == {:error, :not_found}
    end
  end
end
