defmodule Philomena.Attribution.Display.Attribution do
  @moduledoc """
  Presentation data for user attribution.
  """

  import Philomena.Authorization, only: [permitted?: 3]

  alias Philomena.Attribution
  alias Philomena.Attribution.Actor
  alias Philomena.Attribution.AnonymousName

  alias Philomena.Attribution.Display.{
    Anonymous,
    AnonymousRevealed,
    User
  }

  @type t ::
          {:anonymous, Anonymous.t()}
          | {:anonymous_revealed, AnonymousRevealed.t()}
          | {:user, User.t()}

  @spec display_attribution(Actor.t(), struct()) :: t()
  def display_attribution(%Actor{} = actor, object) do
    cond do
      not is_nil(object.user) and not Attribution.anonymous?(object) ->
        {:user, %User{user: object.user, awards: object.user.awards}}

      not is_nil(object.user) and permitted?(actor, :reveal_anon, object) ->
        discriminant = AnonymousName.discriminant(object)

        {:anonymous_revealed, %AnonymousRevealed{user: object.user, discriminant: discriminant}}

      true ->
        discriminant = AnonymousName.discriminant(object)

        {:anonymous, %Anonymous{discriminant: discriminant}}
    end
  end
end
