defmodule PhilomenaWeb.AttributionView do
  use PhilomenaWeb, :view

  alias Philomena.Attribution.Display.Attribution
  alias PhilomenaWeb.AvatarGeneratorView

  @spec avatar_url(Attribution.t()) :: String.t()
  def avatar_url(attribution) do
    case attribution do
      {:user, %{user: %{avatar: avatar}}} when not is_nil(avatar) ->
        "#{avatar_url_root()}/#{avatar}"

      {:user, %{user: %{name: name}}} ->
        generated_avatar_url(name)

      {_type, %{discriminant: discriminant}} ->
        generated_avatar_url(discriminated_name(discriminant))
    end
  end

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

  @spec user_labels(Attribution.t()) :: [{String.t(), String.t()}]
  def user_labels({:user, %{user: user}}) do
    []
    |> personal_title(user)
    |> secondary_role(user)
    |> staff_role(user)
  end

  def user_labels({_kind, _attribution}), do: []

  defp personal_title(labels, %{personal_title: t}) do
    if blank?(t) do
      labels
    else
      [{"label--primary", t} | labels]
    end
  end

  defp personal_title(labels, _user), do: labels

  defp secondary_role(labels, %{secondary_role: t}) do
    if blank?(t) do
      labels
    else
      [{"label--warning", t} | labels]
    end
  end

  defp secondary_role(labels, _user), do: labels

  defp staff_role(labels, %{hide_default_role: false, role: "admin", senior_staff: true}),
    do: [{"label--danger", "Head Administrator"} | labels]

  defp staff_role(labels, %{hide_default_role: false, role: "admin"}),
    do: [{"label--danger", "Administrator"} | labels]

  defp staff_role(labels, %{hide_default_role: false, role: "moderator", senior_staff: true}),
    do: [{"label--success", "Senior Moderator"} | labels]

  defp staff_role(labels, %{hide_default_role: false, role: "moderator"}),
    do: [{"label--success", "Moderator"} | labels]

  defp staff_role(labels, %{hide_default_role: false, role: "assistant", senior_staff: true}),
    do: [{"label--purple", "Senior Assistant"} | labels]

  defp staff_role(labels, %{hide_default_role: false, role: "assistant"}),
    do: [{"label--purple", "Assistant"} | labels]

  defp staff_role(labels, _user),
    do: labels

  defp avatar_url_root do
    Application.get_env(:philomena, :avatar_url_root)
  end

  defp anonymous_name_prefix do
    "Background Pony"
  end
end
