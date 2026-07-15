defmodule Philomena.FiltersTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Filters` functions.

  These pin the index/search viewer-visibility scoping, the `FilterPage` struct
  shape, the per-role authorization matrices on the form loaders and write
  paths (owner vs unrelated user vs admin, the non-castable/unknown id split,
  banned and missing-fingerprint actors on the tag toggles), and the preserved
  oddities: a missing switch id raising `ArgumentError`, and make-public being
  an idempotent success.
  """

  use Philomena.DataCase, async: false

  # search_filters/3 and delete_filter/2 (via unindex) touch OpenSearch, so this
  # module follows the search rules: async: false, index cycled in setup.
  @moduletag :search

  import Philomena.AttributionFixtures
  import Philomena.FiltersFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Filters
  alias Philomena.Filters.Filter
  alias Philomena.Filters.FilterPage
  alias Philomena.Repo
  alias Philomena.Users.User
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to the write-access checks
  # the tag toggles run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  @pagination %{page_number: 1, page_size: 25}

  setup do
    Search.clear_index!(Filter)
    :ok
  end

  describe "index_filters/1" do
    test "an anonymous visitor gets no personal filters, only system filters" do
      system = system_filter_fixture()

      assert {[], system_filters} = Filters.index_filters(actor())
      assert system.id in Enum.map(system_filters, & &1.id)
    end

    test "a signed-in user gets their own filters and the system filters" do
      user = confirmed_user_fixture()
      mine = filter_fixture(user)
      _theirs = filter_fixture(confirmed_user_fixture())
      system = system_filter_fixture()

      assert {my_filters, system_filters} = Filters.index_filters(actor(user))

      my_ids = Enum.map(my_filters, & &1.id)
      assert mine.id in my_ids
      # Only the viewer's own filters land in the first list.
      assert my_filters |> Enum.map(& &1.user_id) |> Enum.uniq() == [user.id]

      assert system.id in Enum.map(system_filters, & &1.id)
    end

    test "the returned filters carry their :user preloaded" do
      user = confirmed_user_fixture()
      filter_fixture(user)

      {[mine | _], _system} = Filters.index_filters(actor(user))
      refute match?(%Ecto.Association.NotLoaded{}, mine.user)
    end
  end

  describe "search_filters/3" do
    test "an anonymous viewer finds public and system filters but not private ones" do
      public = filter_fixture(confirmed_user_fixture(), %{public: true})
      private = filter_fixture(confirmed_user_fixture())
      SearchHelpers.reindex_all!(Filter)

      assert {:ok, page} = Filters.search_filters(actor(), "*", @pagination)

      ids = Enum.map(page.entries, & &1.id)
      assert public.id in ids
      refute private.id in ids
    end

    test "a signed-in user additionally finds their own private filters" do
      user = confirmed_user_fixture()
      mine = filter_fixture(user)
      theirs = filter_fixture(confirmed_user_fixture())
      SearchHelpers.reindex_all!(Filter)

      assert {:ok, page} = Filters.search_filters(actor(user), "*", @pagination)

      ids = Enum.map(page.entries, & &1.id)
      assert mine.id in ids
      refute theirs.id in ids
    end

    test "a moderator is scoped exactly like any other user, not to everything" do
      # search_filters has no staff-wide grant: a moderator sees only public,
      # system, and their own filters, so another user's private one is excluded.
      moderator = moderator_user_fixture()
      theirs = filter_fixture(confirmed_user_fixture())
      SearchHelpers.reindex_all!(Filter)

      assert {:ok, page} = Filters.search_filters(actor(moderator), "*", @pagination)
      refute theirs.id in Enum.map(page.entries, & &1.id)
    end

    test "restricting the query to a name finds that filter" do
      user = confirmed_user_fixture()
      mine = filter_fixture(user)
      SearchHelpers.reindex_all!(Filter)

      assert {:ok, page} = Filters.search_filters(actor(user), "name:#{mine.name}", @pagination)
      assert mine.id in Enum.map(page.entries, & &1.id)
    end

    test "a malformed query returns the compiler error" do
      assert {:error, msg} = Filters.search_filters(actor(), "name:(", @pagination)
      assert is_binary(msg)
    end
  end

  describe "load_filter_page/2" do
    test "an anonymous viewer loads a system filter's page" do
      system = system_filter_fixture()

      assert {:ok, %FilterPage{filter: filter, spoilered_tags: [], hidden_tags: []}} =
               Filters.load_filter_page(actor(), "#{system.id}")

      assert filter.id == system.id
      # The filter carries its :user preloaded for the page.
      refute match?(%Ecto.Association.NotLoaded{}, filter.user)
    end

    test "the owner loads their private filter's page with tags ordered by name" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      zed = tag_fixture(%{name: "zed tag"})
      abe = tag_fixture(%{name: "abe tag"})

      {:ok, filter} = Filters.hide_tag(actor(user), filter, zed.slug)
      {:ok, filter} = Filters.hide_tag(actor(user), filter, abe.slug)

      assert {:ok, %FilterPage{hidden_tags: hidden, spoilered_tags: []}} =
               Filters.load_filter_page(actor(user), "#{filter.id}")

      # Tags come back ordered by name ascending.
      assert Enum.map(hidden, & &1.name) == ["abe tag", "zed tag"]
    end

    test "an anonymous viewer cannot load another user's private filter" do
      filter = filter_fixture(confirmed_user_fixture())

      assert Filters.load_filter_page(actor(), "#{filter.id}") == {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Filters.load_filter_page(actor(), "not-a-number") == {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Filters.load_filter_page(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Filters.load_filter_page(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "new_filter/2" do
    test "a signed-in user with no base filter gets a blank changeset" do
      assert {:ok, %Ecto.Changeset{data: %Filter{} = data}} =
               Filters.new_filter(actor(confirmed_user_fixture()), nil)

      assert data.id == nil
    end

    test "basing a new filter on a visible filter prefills its tag lists" do
      owner = confirmed_user_fixture()
      source = filter_fixture(owner, %{public: true})
      tag = tag_fixture()
      {:ok, source} = Filters.hide_tag(actor(owner), source, tag.slug)

      assert {:ok, %Ecto.Changeset{data: %Filter{} = data}} =
               Filters.new_filter(actor(confirmed_user_fixture()), "#{source.id}")

      assert tag.id in data.hidden_tag_ids
    end

    test "basing a new filter on an unknown id yields a blank form" do
      assert {:ok, %Ecto.Changeset{data: %Filter{hidden_tag_ids: []}}} =
               Filters.new_filter(actor(confirmed_user_fixture()), "999999999")
    end

    test "an anonymous actor is unauthorized" do
      assert Filters.new_filter(actor(), nil) == {:error, :unauthorized}
    end
  end

  describe "load_filter_for_edit/2" do
    test "the owner loads their filter paired with an edit changeset" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert {:ok, {%Filter{} = loaded, %Ecto.Changeset{} = changeset}} =
               Filters.load_filter_for_edit(actor(user), "#{filter.id}")

      assert loaded.id == filter.id
      assert changeset.data.id == filter.id
    end

    test "an unrelated user is unauthorized" do
      filter = filter_fixture(confirmed_user_fixture())

      assert Filters.load_filter_for_edit(actor(confirmed_user_fixture()), "#{filter.id}") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Filters.load_filter_for_edit(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Filters.load_filter_for_edit(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Filters.load_filter_for_edit(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "update_filter/3" do
    test "the owner renames their filter" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert {:ok, %Filter{}} =
               Filters.update_filter(actor(user), "#{filter.id}", %{"name" => "Renamed Filter"})

      assert Repo.reload!(filter).name == "Renamed Filter"
    end

    test "an admin updates another user's filter" do
      filter = filter_fixture(confirmed_user_fixture())

      assert {:ok, %Filter{}} =
               Filters.update_filter(actor(admin_user_fixture()), "#{filter.id}", %{
                 "name" => "Admin Renamed"
               })

      assert Repo.reload!(filter).name == "Admin Renamed"
    end

    test "an invalid name is a rejected changeset" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Filters.update_filter(actor(user), "#{filter.id}", %{"name" => ""})

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "an unrelated user is unauthorized and leaves the row unchanged" do
      filter = filter_fixture(confirmed_user_fixture())

      assert Filters.update_filter(actor(confirmed_user_fixture()), "#{filter.id}", %{
               "name" => "Hijacked"
             }) == {:error, :unauthorized}

      assert Repo.reload!(filter).name == filter.name
    end

    test "a non-castable id is not-found" do
      assert Filters.update_filter(actor(confirmed_user_fixture()), "abc", %{"name" => "x"}) ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Filters.update_filter(actor(confirmed_user_fixture()), "999999999", %{"name" => "x"}) ==
               {:error, :unauthorized}

      assert Filters.update_filter(actor(admin_user_fixture()), "999999999", %{"name" => "x"}) ==
               {:error, :not_found}
    end
  end

  describe "delete_filter/2" do
    test "the owner deletes their filter" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert {:ok, %Filter{} = deleted} = Filters.delete_filter(actor(user), "#{filter.id}")
      assert deleted.id == filter.id
      assert Repo.reload(filter) == nil
    end

    test "an unrelated user is unauthorized and leaves the row" do
      filter = filter_fixture(confirmed_user_fixture())

      assert Filters.delete_filter(actor(confirmed_user_fixture()), "#{filter.id}") ==
               {:error, :unauthorized}

      refute Repo.reload(filter) == nil
    end

    test "a non-castable id is not-found" do
      assert Filters.delete_filter(actor(confirmed_user_fixture()), "abc") == {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Filters.delete_filter(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Filters.delete_filter(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "make_filter_public/2" do
    test "the owner makes their private filter public" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      refute filter.public

      assert {:ok, %Filter{public: true}} =
               Filters.make_filter_public(actor(user), "#{filter.id}")

      assert Repo.reload!(filter).public
    end

    test "making an already-public filter public again is an idempotent success" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user, %{public: true})

      assert {:ok, %Filter{public: true}} =
               Filters.make_filter_public(actor(user), "#{filter.id}")
    end

    test "an unrelated user is unauthorized" do
      filter = filter_fixture(confirmed_user_fixture())

      assert Filters.make_filter_public(actor(confirmed_user_fixture()), "#{filter.id}") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Filters.make_filter_public(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Filters.make_filter_public(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Filters.make_filter_public(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "switch_current_filter/2" do
    test "a signed-in user switches to their own filter, persisting the choice" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert {:ok, %Filter{} = switched} =
               Filters.switch_current_filter(actor(user), "#{filter.id}")

      assert switched.id == filter.id
      assert Repo.get!(User, user.id).current_filter_id == filter.id
    end

    test "a signed-in user is switched to the default filter for a private filter" do
      default = system_filter_fixture(%{name: "Default"})
      user = confirmed_user_fixture()
      others = filter_fixture(confirmed_user_fixture())

      assert {:ok, %Filter{} = switched} =
               Filters.switch_current_filter(actor(user), "#{others.id}")

      assert switched.id == default.id
      assert Repo.get!(User, user.id).current_filter_id == default.id
    end

    test "an anonymous visitor gets the resolved filter back without persistence" do
      public = filter_fixture(confirmed_user_fixture(), %{public: true})

      assert {:ok, %Filter{} = switched} = Filters.switch_current_filter(actor(), "#{public.id}")
      assert switched.id == public.id
    end

    test "an anonymous visitor is switched to the default for a private filter" do
      default = system_filter_fixture(%{name: "Default"})
      private = filter_fixture(confirmed_user_fixture())

      assert {:ok, %Filter{} = switched} = Filters.switch_current_filter(actor(), "#{private.id}")
      assert switched.id == default.id
    end

    test "a well-formed id naming no row is not-found" do
      assert Filters.switch_current_filter(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :not_found}
    end

    test "a non-castable id is not-found" do
      assert Filters.switch_current_filter(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "a nil id raises, as the query layer rejects a nil comparison" do
      # Preserved oddity: with no id the switch reaches Repo.get_by(id: nil),
      # which refuses to compare against nil.
      assert_raise ArgumentError, ~r/nil given for :id\. Comparison with nil is forbidden/, fn ->
        Filters.switch_current_filter(actor(confirmed_user_fixture()), nil)
      end
    end
  end

  describe "create_filter/2" do
    test "a signed-in user creates a filter attributed to themselves" do
      user = confirmed_user_fixture()

      assert {:ok, %Filter{} = filter} =
               Filters.create_filter(actor(user), %{"name" => "My New Filter"})

      assert filter.user_id == user.id
      assert filter.name == "My New Filter"
    end

    test "a blank name is a rejected changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Filters.create_filter(actor(confirmed_user_fixture()), %{"name" => ""})

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "an anonymous actor is unauthorized" do
      assert Filters.create_filter(actor(), %{"name" => "x"}) == {:error, :unauthorized}
    end
  end

  describe "hide_tag/3 and unhide_tag/3" do
    test "the owner hides then unhides a tag by slug" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert {:ok, %Filter{} = hidden} = Filters.hide_tag(actor(user), filter, tag.slug)
      assert tag.id in hidden.hidden_tag_ids

      assert {:ok, %Filter{} = shown} = Filters.unhide_tag(actor(user), hidden, tag.slug)
      refute tag.id in shown.hidden_tag_ids
    end

    test "an unknown tag slug is not-found" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert Filters.hide_tag(actor(user), filter, "no-such-tag") == {:error, :not_found}
    end

    test "an unrelated user is unauthorized" do
      filter = filter_fixture(confirmed_user_fixture())
      tag = tag_fixture()

      assert Filters.hide_tag(actor(confirmed_user_fixture()), filter, tag.slug) ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected before authorization, even with a good slug" do
      # verify_write_access runs first and decides the ban before the filter
      # authorization, so a banned owner is {:error, :ban}.
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert Filters.hide_tag(actor(user, ban: @ban), filter, tag.slug) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert Filters.hide_tag(actor(user, fingerprint: nil), filter, tag.slug) ==
               {:error, :unauthorized}
    end

    test "the ban wins over a missing fingerprint" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert Filters.hide_tag(actor(user, ban: @ban, fingerprint: nil), filter, tag.slug) ==
               {:error, :ban}
    end
  end

  describe "spoiler_tag/3 and unspoiler_tag/3" do
    test "the owner spoilers then unspoilers a tag by slug" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert {:ok, %Filter{} = spoilered} = Filters.spoiler_tag(actor(user), filter, tag.slug)
      assert tag.id in spoilered.spoilered_tag_ids

      assert {:ok, %Filter{} = plain} = Filters.unspoiler_tag(actor(user), spoilered, tag.slug)
      refute tag.id in plain.spoilered_tag_ids
    end

    test "an unknown tag slug is not-found" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)

      assert Filters.spoiler_tag(actor(user), filter, "no-such-tag") == {:error, :not_found}
    end

    test "an unrelated user is unauthorized" do
      filter = filter_fixture(confirmed_user_fixture())
      tag = tag_fixture()

      assert Filters.spoiler_tag(actor(confirmed_user_fixture()), filter, tag.slug) ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected" do
      user = confirmed_user_fixture()
      filter = filter_fixture(user)
      tag = tag_fixture()

      assert Filters.spoiler_tag(actor(user, ban: @ban), filter, tag.slug) == {:error, :ban}
    end
  end
end
