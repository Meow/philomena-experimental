defmodule Philomena.Donations do
  @moduledoc """
  The Donations context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Donations.Donation
  alias Philomena.Users.User

  @doc """
  Returns the list of donations.

  ## Examples

      iex> list_donations()
      [%Donation{}, ...]

  """
  def list_donations do
    Repo.all(Donation)
  end

  @doc """
  Returns the paginated donation listing for the admin index, on behalf of
  `actor`, newest first, with each donation's user preloaded.

  Authorizes `:index` against the donation model, so a viewer without donation
  access is `{:error, :unauthorized}`. Returns `{:ok, donations}` as a
  `m:Scrivener.Page` or `{:error, :unauthorized}`.
  """
  @spec load_donations(User.t() | nil, map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_donations(actor, pagination) do
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
  Loads the user named by the raw request `slug` together with their donations,
  on behalf of `actor`, pairing them with a changeset backing the add-donation
  form.

  Authorizes `:index` against the donation model first, so a viewer without
  donation access is `{:error, :unauthorized}`. An unknown slug is
  `{:error, :not_found}`.

  Returns `{:ok, {user, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec load_user_donations(User.t() | nil, String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_user_donations(actor, slug) do
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
  Gets a single donation.

  Raises `Ecto.NoResultsError` if the Donation does not exist.

  ## Examples

      iex> get_donation!(123)
      %Donation{}

      iex> get_donation!(456)
      ** (Ecto.NoResultsError)

  """
  def get_donation!(id), do: Repo.get!(Donation, id)

  @doc """
  Creates a donation on behalf of `actor` from the controller `attrs`.

  Authorizes `:index` against the donation model, then inserts the donation.
  Returns `{:ok, donation}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}` (e.g. a `user_id` naming no user).

  ## Examples

      iex> create_donation(admin, %{field: value})
      {:ok, %Donation{}}

      iex> create_donation(admin, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_donation(User.t() | nil, map()) ::
          {:ok, Donation.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_donation(actor, attrs) do
    with :ok <- authorize(actor, :index, Donation) do
      insert_donation(attrs)
    end
  end

  @doc """
  Inserts a donation from `attrs` without authorization.

  ## Examples

      iex> insert_donation(%{field: value})
      {:ok, %Donation{}}

      iex> insert_donation(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def insert_donation(attrs \\ %{}) do
    %Donation{}
    |> Donation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a donation.

  ## Examples

      iex> update_donation(donation, %{field: new_value})
      {:ok, %Donation{}}

      iex> update_donation(donation, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_donation(%Donation{} = donation, attrs) do
    donation
    |> Donation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Donation.

  ## Examples

      iex> delete_donation(donation)
      {:ok, %Donation{}}

      iex> delete_donation(donation)
      {:error, %Ecto.Changeset{}}

  """
  def delete_donation(%Donation{} = donation) do
    Repo.delete(donation)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking donation changes.

  ## Examples

      iex> change_donation(donation)
      %Ecto.Changeset{source: %Donation{}}

  """
  def change_donation(%Donation{} = donation) do
    Donation.changeset(donation, %{})
  end
end
