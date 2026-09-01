defmodule PhilomenaWeb.TagViewTest do
  use PhilomenaWeb.ConnCase, async: true

  alias Philomena.Tags.Tag
  alias Philomena.Users.User
  alias PhilomenaWeb.TagView

  defp viewer_conn(conn, user), do: Plug.Conn.assign(conn, :current_user, user)

  defp tag_fixture do
    alias_tag = %Tag{id: 2, slug: "artist-alias", name: "artist:alias"}

    hidden_link = %Philomena.ArtistLinks.ArtistLink{
      id: 3,
      user: %User{id: 4, slug: "hidden-artist", name: "Hidden Artist"},
      uri: "https://example.com/hidden-artist",
      public: false
    }

    tag = %Tag{
      id: 1,
      slug: "artist-test",
      name: "artist:test",
      category: "origin",
      images_count: 0,
      short_description: nil,
      description: "",
      mod_notes: nil,
      aliases: [alias_tag],
      implied_tags: [],
      implied_by_tags: [],
      channels: [],
      public_links: [],
      hidden_links: [hidden_link]
    }

    dnp_entry = %Philomena.DnpEntries.DnpEntry{id: 5, dnp_type: "No Edits"}
    {tag, [{"", dnp_entry}]}
  end

  defp render_tag_info(conn, user, {tag, dnp_entries}) do
    Phoenix.View.render_to_string(
      TagView,
      "_tag_info_row.html",
      %{
        conn: viewer_conn(conn, user),
        tag: tag,
        body: "",
        dnp_entries: dnp_entries
      }
    )
  end

  describe "tag-info staff affordances" do
    test "regular viewers do not receive tag-management, hidden-link, or DNP controls", %{
      conn: conn
    } do
      response = render_tag_info(conn, %User{role: "user"}, tag_fixture())

      refute response =~ "Edit details"
      refute response =~ "Usage"
      refute response =~ "Create new DNP entry"
      refute response =~ "Hidden links:"
      refute response =~ "Hidden Artist"
      refute response =~ "https://example.com/hidden-artist"
      refute response =~ ~p"/tags/artist-alias/alias/edit"
    end

    test "plain moderators receive tag-management, hidden-link, and DNP controls", %{
      conn: conn
    } do
      response = render_tag_info(conn, %User{role: "moderator"}, tag_fixture())

      assert response =~ "Edit details"
      assert response =~ "Usage"
      assert response =~ "Create new DNP entry"
      assert response =~ "Hidden links:"
      assert response =~ "Hidden Artist"
      assert response =~ "https://example.com/hidden-artist"
      refute response =~ ~p"/tags/artist-alias/alias/edit"
    end

    test "Tag-admin role maps enable alias-management links", %{conn: conn} do
      user = %User{role: "moderator", role_map: %{"Tag" => %{"admin" => true}}}
      response = render_tag_info(conn, user, tag_fixture())

      assert response =~ ~p"/tags/artist-alias/alias/edit"
    end
  end
end
