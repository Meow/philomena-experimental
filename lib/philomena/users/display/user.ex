defmodule Philomena.Users.Display.User do
  @moduledoc """
  Presentation data for a user.
  """

  alias Philomena.Users.User

  @enforce_keys [
    :name,
    :slug,
    :id,
    :created_at,
    :avatar,
    :statistics,
    :labels,
    :staff?
  ]
  defstruct @enforce_keys

  @type version :: %{
          width: pos_integer(),
          height: pos_integer(),
          mime_type: String.t(),
          uri: String.t()
        }

  @type statistics :: %{
          images_count: integer(),
          image_faves_count: integer(),
          image_votes_count: integer(),
          comments_count: integer(),
          metadata_updates_count: integer(),
          posts_count: integer(),
          topics_count: integer()
        }

  @type label ::
          :senior_administrator_role
          | :administrator_role
          | :senior_moderator_role
          | :moderator_role
          | :senior_assistant_role
          | :assistant_role
          | {:secondary_role, String.t()}
          | {:personal_title, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          slug: String.t(),
          id: integer(),
          created_at: DateTime.t(),
          avatar: version() | nil,
          labels: [label()],
          statistics: statistics()
        }

  def render(%User{} = user) do
    %__MODULE__{
      name: user.name,
      slug: user.slug,
      id: user.id,
      created_at: user.created_at,
      avatar:
        if user.avatar do
          %{
            width: user.avatar_width,
            height: user.avatar_height,
            mime_type: user.avatar_mime_type,
            uri: "#{avatar_url_root()}/#{user.avatar}"
          }
        end,
      statistics: %{
        images_count: user.images_count,
        image_faves_count: user.image_faves_count,
        image_votes_count: user.image_votes_count,
        comments_count: user.comments_count,
        metadata_updates_count: user.metadata_updates_count,
        posts_count: user.posts_count,
        topics_count: user.topics_count
      },
      labels: labels(user),
      staff?: staff?(user)
    }
  end

  defp labels(%User{} = user) do
    [
      staff_role_label(user),
      secondary_role_label(user),
      personal_title_label(user)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp staff_role_label(%User{} = user) do
    if staff?(user) do
      case user.role do
        "admin" ->
          select_label_role(user, :senior_administrator_role, :administrator_role)

        "moderator" ->
          select_label_role(user, :senior_moderator_role, :moderator_role)

        "assistant" ->
          select_label_role(user, :senior_assistant_role, :assistant_role)

        _ ->
          nil
      end
    end
  end

  defp secondary_role_label(%User{} = user) do
    if user.secondary_role do
      {:secondary_role, user.secondary_role}
    end
  end

  defp personal_title_label(%User{} = user) do
    if user.personal_title do
      {:personal_title, user.personal_title}
    end
  end

  defp select_label_role(%User{senior_staff: senior_staff}, senior_label_role, normal_label_role) do
    if senior_staff do
      senior_label_role
    else
      normal_label_role
    end
  end

  defp staff?(%User{role: role, hide_default_role: hide_default_role}) do
    role != "user" and not hide_default_role
  end

  defp avatar_url_root do
    Application.get_env(:philomena, :avatar_url_root)
  end
end
