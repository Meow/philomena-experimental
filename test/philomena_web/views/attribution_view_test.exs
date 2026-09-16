defmodule PhilomenaWeb.AttributionViewTest do
  use Philomena.DataCase, async: true

  import Philomena.UsersFixtures

  alias Philomena.Attribution.Display.{Anonymous, AnonymousRevealed, User}
  alias PhilomenaWeb.AttributionView

  defp render(template, attribution) do
    Phoenix.View.render_to_string(AttributionView, template,
      attribution: attribution,
      awards: true
    )
  end

  test "renders display names and profile links without a conn or source object" do
    user = user_fixture(name: "Uploader")
    user = Philomena.Users.Display.User.render(user)

    html = render("_user.html", {:user, %{user: user, awards: []}})
    assert html =~ ~s(href="/profiles/Uploader")
    assert html =~ "Uploader"

    html =
      render(
        "_user.html",
        {:anonymous_revealed, %AnonymousRevealed{user: user, discriminant: "ABCD"}}
      )

    assert html =~ ~s(href="/profiles/Uploader")
    assert html =~ "Uploader (#ABCD, hidden)"

    html = render("_user.html", {:anonymous, %Anonymous{discriminant: "ABCD"}})
    assert html =~ "Background Pony #ABCD"
    refute html =~ "href"
  end

  test "revealed anonymous users retain anonymous avatars and have no titles" do
    user = %Philomena.Users.User{
      name: "Uploader",
      slug: "uploader",
      avatar: "custom.png",
      personal_title: "Personal title"
    }

    anonymous = {:anonymous, %Anonymous{discriminant: "ABCD"}}
    revealed = {:anonymous_revealed, %AnonymousRevealed{user: user, discriminant: "ABCD"}}

    assert AttributionView.avatar_url(anonymous) == AttributionView.avatar_url(revealed)

    html = render("_avatar.html", revealed)
    assert html == render("_avatar.html", anonymous)
    refute html =~ "custom.png"
    refute html =~ "href"

    assert render("_title.html", revealed) == ""
    assert render("_title.html", anonymous) == ""
    assert render("_title.html", {:user, %User{user: user, awards: []}}) =~ "Personal title"
  end
end
