defmodule Philomena.Attribution do
  @moduledoc """
  Cross-context attribution display utilities.
  """

  import Philomena.Authorization, only: [permitted?: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Attribution.AnonymousName
  alias Philomena.Attribution.Display
  alias Philomena.Attribution.Subject

  @doc """
  Renders the attribution for an object implementing the `Subject` protocol.

  ## Examples

      iex> display_attribution(admin_actor, post)
      {:anonymous_revealed, %AnonymousRevealed{discriminant: "ABCD", user: %User{}}}

      iex> display_attribution(user_actor, post)
      {:anonymous, %Anonymous{discriminant: "ABCD"}}

      iex> display_attribution(user_actor, comment)
      {:anonymous, %User{user: %User{}, awards: [%Award{}]}}

  """
  @spec display_attribution(Actor.t(), struct()) :: Display.Attribution.t()
  def display_attribution(%Actor{} = actor, object) do
    cond do
      not is_nil(object.user) and not Subject.anonymous?(object) ->
        {:user, Display.User.render(object.user)}

      not is_nil(object.user) and permitted?(actor, :reveal_anon, object) ->
        discriminant = AnonymousName.discriminant(object)

        {:anonymous_revealed, Display.AnonymousRevealed.render(object.user, discriminant)}

      true ->
        discriminant = AnonymousName.discriminant(object)

        {:anonymous, Display.Anonymous.render(discriminant)}
    end
  end

  @doc """
  Renders the identity metadata (IP/fingerprint) for an object which contains them.

  ## Examples

      iex> display_identity_metadata(admin_actor, post)
      %IdentityMetadata{ip: %Postgrex.INET{address: {127, 0, 0, 1}}, fingerprint: "ffff"}

      iex> display_identity_metadata(user_actor, post)
      nil

  """
  @spec display_identity_metadata(Actor.t(), struct()) :: Display.IdentityMetadata.t() | nil
  def display_identity_metadata(%Actor{} = actor, object) do
    if permitted?(actor, :show, :identity_metadata) do
      Display.IdentityMetadata.render(object)
    end
  end
end
