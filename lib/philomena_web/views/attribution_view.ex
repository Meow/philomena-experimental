defmodule PhilomenaWeb.AttributionView do
  use PhilomenaWeb, :view

  alias Philomena.Attribution.Display.Attribution
  alias Philomena.Users.Display.User
  alias PhilomenaWeb.AvatarGeneratorView

  @spec avatar_url(Attribution.t()) :: String.t()
  def avatar_url(attribution) do
    case attribution do
      {:user, %{user: %{avatar: avatar}}} when not is_nil(avatar) ->
        avatar.uri

      {:user, %{user: %{name: name}}} ->
        generated_avatar_url(name)

      {_type, %{discriminant: discriminant}} ->
        generated_avatar_url(discriminated_name(discriminant))
    end
  end

  @spec user_labels(Attribution.t()) :: [User.label()]
  def user_labels({:user, %{user: %{labels: labels}}}), do: labels
  def user_labels({_kind, _attribution}), do: []

  defp discriminated_name(discriminant) do
    "#{anonymous_name_prefix()} ##{discriminant}"
  end

  defp generated_avatar_url(name) do
    svg =
      name
      |> AvatarGeneratorView.generated_avatar()
      |> Enum.map_join(&safe_to_string/1)

    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  defp anonymous_name_prefix do
    "Background Pony"
  end
end
