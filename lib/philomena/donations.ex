defmodule Philomena.Donations do
  @moduledoc """
  The Donations context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Attribution.Actor
  alias Philomena.Donations.Donation
  alias Philomena.Users.User

  # Inserts a donation from `attrs`. Visible for testing.
  @doc false
  def insert_donation(attrs \\ %{}) do
    %Donation{}
    |> Donation.changeset(attrs)
    |> Repo.insert()
  end

  # Returns an `%Ecto.Changeset{}` for tracking donation changes.
  defp change_donation(%Donation{} = donation) do
    Donation.changeset(donation, %{})
  end

  @doc """
  Returns the paginated donation listing for the admin index, on behalf of
  `actor`, newest first, with each donation's user preloaded.

  ## Examples

      iex> load_donations(admin, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_donations(user,  pagination)
      {:error, :unauthorized}

  """
  @spec load_donations(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_donations(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index, Donation) do
      donations =
        Donation
        |> order_by(desc: :created_at, asc: :user_id)
        |> preload(:user)
        |> Repo.paginate(pagination)

      {:ok, donations}
    end
  end

  @doc """
  Loads the user named by `slug` together with their donations, on behalf of
  `actor`, pairing them with a changeset for adding a donation.

  ## Examples

      iex> load_user_donations(admin, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_user_donations(admin, invalid_slug)
      {:error, :not_found}

      iex> load_user_donations(user, user.slug)
      {:error, :unauthorized}

  """
  @spec load_user_donations(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_user_donations(%Actor{} = actor, slug) do
    with :ok <- authorize(actor, :index, Donation) do
      user =
        User
        |> where(slug: ^slug)
        |> preload(donations: :user)
        |> Repo.one()

      case user do
        nil -> {:error, :not_found}
        %User{} -> {:ok, {user, change_donation(%Donation{})}}
      end
    end
  end

  @doc """
  Creates a donation on behalf of `actor` from `attrs`.

  ## Examples

      iex> create_donation(admin, donation_params)
      {:ok, %Donation{}}

      iex> create_donation(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_donation(user, donation_params)
      {:error, :unauthorized}

  """
  @spec create_donation(Actor.t(), map()) ::
          {:ok, Donation.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_donation(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :index, Donation) do
      insert_donation(attrs)
    end
  end
end
