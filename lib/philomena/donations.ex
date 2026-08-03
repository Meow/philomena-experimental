defmodule Philomena.Donations do
  @moduledoc """
  Authorized administration of donation records.

  Donation history is financial data. Controller-facing functions authorize
  the requested action, and the per-user loader additionally authorizes the
  sensitive target before returning it.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Authorization
  alias Philomena.Donations.Donation
  alias Philomena.Loader
  alias Philomena.Repo
  alias Philomena.Users.User

  defp insert_donation(attrs) do
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

      iex> load_donations(user, pagination)
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
  Loads the user named by `slug` with their donations and a new-donation
  changeset.

  This form loader verifies write access, authorizes the routed `:show` action
  against donations, then safely loads and authorizes the target user's
  financial history. A missing slug is not found; a real but forbidden target
  is unauthorized.

  ## Examples

      iex> load_user_donations(admin, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_user_donations(admin, invalid_slug)
      {:error, :not_found}

      iex> load_user_donations(user, user.slug)
      {:error, :unauthorized}

  """
  @spec load_user_donations(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_user_donations(%Actor{} = actor, slug) do
    user_query =
      User
      |> where(slug: ^slug)
      |> preload(donations: :user)

    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :show, Donation),
         {:ok, user} <- Loader.one(user_query),
         :ok <- authorize(actor, :show_donations, user) do
      {:ok, {user, change_donation(%Donation{})}}
    end
  end

  @doc """
  Creates a donation on behalf of `actor` from `attrs`.

  Verifies write access and authorizes `:create` before inserting. Database and
  validation failures are returned as changesets.

  ## Examples

      iex> create_donation(admin, donation_params)
      {:ok, %Donation{}}

      iex> create_donation(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_donation(user, donation_params)
      {:error, :unauthorized}

  """
  @spec create_donation(Actor.t(), map()) ::
          {:ok, Donation.t()}
          | Authorization.write_error()
          | {:error, Ecto.Changeset.t()}
  def create_donation(%Actor{} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Donation) do
      insert_donation(attrs)
    end
  end
end
