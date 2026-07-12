defmodule Philomena.StaticPagesTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.StaticPages`
  functions.

  These pin the staff-only index gate, the public show loader (including the
  unknown-slug unauthorized/not-found split), and the create/update authorization
  matrix - including the `Ecto.Multi` 4-tuple error shape
  (`{:error, :static_page, changeset, changes}`) the write paths surface on a
  validation failure.
  """

  use Philomena.DataCase, async: true

  import Philomena.StaticPagesFixtures
  import Philomena.UsersFixtures

  alias Philomena.StaticPages
  alias Philomena.StaticPages.StaticPage

  describe "load_page_listing/1" do
    test "an admin gets the list of static pages" do
      page = static_page_fixture(admin_user_fixture())

      assert {:ok, pages} = StaticPages.load_page_listing(admin_user_fixture())
      assert page.id in Enum.map(pages, & &1.id)
    end

    test "a moderator with the StaticPage admin grant may list them" do
      moderator = role_moderator_fixture("StaticPage")

      assert {:ok, _pages} = StaticPages.load_page_listing(moderator)
    end

    test "a regular user is unauthorized" do
      assert StaticPages.load_page_listing(confirmed_user_fixture()) == {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert StaticPages.load_page_listing(nil) == {:error, :unauthorized}
    end
  end

  describe "load_page_for_show/2" do
    test "an anonymous viewer loads a page by slug" do
      page = static_page_fixture(admin_user_fixture())

      assert {:ok, loaded} = StaticPages.load_page_for_show(nil, page.slug)
      assert loaded.id == page.id
    end

    test "an unknown slug is unauthorized for a user, not-found for an admin" do
      assert StaticPages.load_page_for_show(confirmed_user_fixture(), "no-such-page") ==
               {:error, :unauthorized}

      assert StaticPages.load_page_for_show(admin_user_fixture(), "no-such-page") ==
               {:error, :not_found}
    end
  end

  describe "new_page/1" do
    test "an admin gets a blank changeset" do
      assert {:ok, %Ecto.Changeset{data: %StaticPage{}}} =
               StaticPages.new_page(admin_user_fixture())
    end

    test "a regular user is unauthorized" do
      assert StaticPages.new_page(confirmed_user_fixture()) == {:error, :unauthorized}
    end
  end

  describe "create_page/2" do
    test "an admin creates a page and its initial version" do
      slug = unique_static_page_slug()

      assert {:ok, %{static_page: %StaticPage{} = page, version: _version}} =
               StaticPages.create_page(admin_user_fixture(), %{
                 "title" => "Created Page",
                 "slug" => slug,
                 "body" => "Body text"
               })

      assert page.slug == slug
    end

    test "invalid attrs surface the Multi static_page error tuple" do
      assert {:error, :static_page, %Ecto.Changeset{} = changeset, _changes} =
               StaticPages.create_page(admin_user_fixture(), %{"title" => ""})

      refute changeset.valid?
    end

    test "a regular user is unauthorized" do
      assert StaticPages.create_page(confirmed_user_fixture(), %{
               "title" => "x",
               "slug" => "y",
               "body" => "z"
             }) == {:error, :unauthorized}
    end
  end

  describe "load_page_for_edit/2" do
    test "an admin loads a page and a changeset" do
      page = static_page_fixture(admin_user_fixture())

      assert {:ok, {%StaticPage{} = loaded, %Ecto.Changeset{}}} =
               StaticPages.load_page_for_edit(admin_user_fixture(), page.slug)

      assert loaded.id == page.id
    end

    test "a regular user is unauthorized" do
      page = static_page_fixture(admin_user_fixture())

      assert StaticPages.load_page_for_edit(confirmed_user_fixture(), page.slug) ==
               {:error, :unauthorized}
    end
  end

  describe "update_page/3" do
    test "an admin updates a page and stores a new version" do
      admin = admin_user_fixture()
      page = static_page_fixture(admin)

      # The new Version row requires the full page fields, not just the changed
      # one, so the update carries slug and body alongside the new title.
      assert {:ok, %{static_page: %StaticPage{} = updated, version: _version}} =
               StaticPages.update_page(admin, page.slug, %{
                 "title" => "Updated Title",
                 "slug" => page.slug,
                 "body" => "Updated body"
               })

      assert updated.title == "Updated Title"
      assert StaticPages.get_static_page!(page.id).title == "Updated Title"
    end

    test "an invalid update surfaces the Multi static_page error tuple" do
      admin = admin_user_fixture()
      page = static_page_fixture(admin)

      assert {:error, :static_page, %Ecto.Changeset{} = changeset, _changes} =
               StaticPages.update_page(admin, page.slug, %{"title" => ""})

      refute changeset.valid?
      assert StaticPages.get_static_page!(page.id).title == page.title
    end

    test "an unknown slug is unauthorized for a user, not-found for an admin" do
      assert StaticPages.update_page(confirmed_user_fixture(), "no-such-page", %{"title" => "x"}) ==
               {:error, :unauthorized}

      assert StaticPages.update_page(admin_user_fixture(), "no-such-page", %{"title" => "x"}) ==
               {:error, :not_found}
    end

    test "a regular user is unauthorized" do
      page = static_page_fixture(admin_user_fixture())

      assert StaticPages.update_page(confirmed_user_fixture(), page.slug, %{"title" => "Hijacked"}) ==
               {:error, :unauthorized}
    end
  end
end
