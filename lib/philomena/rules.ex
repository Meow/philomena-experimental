defmodule Philomena.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.IntegerId
  alias Philomena.Repo

  alias Philomena.Rules.Rule
  alias Philomena.Rules.RuleVersion
  alias Philomena.Users.User

  @doc """
  Returns the list of rules.

  ## Examples

      iex> list_rules()
      [%Rule{}, ...]

  """
  def list_rules do
    Repo.all(from r in Rule, order_by: [asc: r.position])
  end

  @doc """
  Returns the list of visible rules.

  ## Examples

      iex> list_visible_rules()
      [%Rule{}, ...]
  """
  def list_visible_rules do
    Repo.all(
      from r in Rule,
        where: r.hidden == false and r.internal == false,
        order_by: [asc: r.position]
    )
  end

  @doc """
  Returns a list of all the reportable rules.

  ## Examples

      iex> list_reportable_rules()
      [%Rule{name: "Rule #0", ...}, ...]

  """
  def list_reportable_rules do
    Repo.all(
      from r in Rule,
        where: r.internal == false,
        order_by: [asc: r.position]
    )
  end

  @doc """
  Gets a single rule. Returns nil if the rule does not exist.

  ## Examples

      iex> find_rule(123)
      %Rule{}

      iex> find_rule(456)
      nil

  """
  def find_rule(id), do: Repo.get(Rule, id)

  @doc """
  Gets a single rule by its position.

  Raises `Ecto.NoResultsError` if the Rule does not exist.

  ## Examples

      iex> get_by_position!(0)
      %Rule{name: "Rule #0", position: 0, ...}

      iex> get_by_position!(99999)
      ** (Ecto.NoResultsError)

  """
  def get_by_position!(position), do: Repo.get_by!(Rule, position: position)

  @doc """
  Gets a single rule by its name.

  Raises `Ecto.NoResultsError` if the Rule does not exist.

  ## Examples

      iex> get_by_name!("Rule #0")
      %Rule{name: "Rule #0", ...}

      iex> get_by_name!("Nonexistent Rule")
      ** (Ecto.NoResultsError)

  """
  def get_by_name!(name), do: Repo.get_by!(Rule, name: name)

  @doc """
  Returns a list of all rule versions for a given rule.

  ## Examples

      iex> list_rule_versions(rule)
      [%RuleVersion{...}, ...]

  """
  def list_rule_versions(%Rule{} = rule) do
    Repo.all(
      from rv in RuleVersion,
        where: rv.rule_id == ^rule.id,
        order_by: [desc: rv.created_at, desc: rv.id],
        preload: [:user]
    )
  end

  defp create_rule_version(%Rule{} = rule, %User{} = user) do
    %RuleVersion{}
    |> RuleVersion.changeset(%{
      name: rule.name,
      title: rule.title,
      description: rule.description,
      short_description: rule.short_description,
      example: rule.example,
      rule_id: rule.id,
      user_id: user.id
    })
    |> Repo.insert()
  end

  defp create_rule_version(%Rule{} = rule, nil) do
    create_rule_version(rule, %User{id: nil})
  end

  defp insert_rule(attrs) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a rule and stores the initial version attributed to a user.

  If the user is nil, then it is assumed to be a system action.

  ## Examples

      iex> create_rule_with_version(%{name: "Rule #0", ...}, user)
      {:ok, [%Rule{}, %RuleVersion{}]}

      iex> create_rule_with_version(%{bad_field: bad_value, ...}, user)
      {:error, %Ecto.Changeset{}}

  """
  def create_rule_with_version(attrs, user) do
    Repo.transact(fn ->
      with {:ok, rule} <- insert_rule(attrs),
           {:ok, rule_version} <- create_rule_version(rule, user) do
        {:ok, [rule, rule_version]}
      end
    end)
  end

  defp save_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a rule and stores the new version attributed to a user.

  If the user is nil, then it is assumed to be a system edit.

  ## Examples

      iex> update_rule_with_version(rule, user, %{field: new_value})
      {:ok, [%Rule{}, %RuleVersion{}]}

      iex> update_rule_with_version(rule, user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_rule_with_version(%Rule{} = rule, user, attrs) do
    Repo.transact(fn ->
      with {:ok, updated_rule} <- save_rule(rule, attrs),
           {:ok, rule_version} <- create_rule_version(updated_rule, user) do
        {:ok, [updated_rule, rule_version]}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking rule changes.

  ## Examples

      iex> change_rule(rule)
      %Ecto.Changeset{data: %Rule{}}

  """
  def change_rule(%Rule{} = rule, attrs \\ %{}) do
    Rule.changeset(rule, attrs)
  end

  @doc """
  Returns the rules `user` (the current viewer, possibly `nil`) may see for the
  index, ordered by position.

  A viewer who may edit rules sees every rule; everyone else sees only the
  visible (non-hidden, non-internal) rules.
  """
  @spec list_rules_for(User.t() | nil) :: [Rule.t()]
  def list_rules_for(user) do
    if Canada.Can.can?(user, :edit, Rule) do
      list_rules()
    else
      list_visible_rules()
    end
  end

  @doc """
  Loads the rule at `position` for `user` (the current viewer, possibly `nil`) to
  be shown.

  Returns `{:error, :not_found}` for a position no row could have,
  `{:error, :unauthorized}` when the viewer may not see the rule, and
  `{:error, :rule_hidden}` when the rule is hidden or internal and the viewer may
  not edit it (a distinct case the controller redirects to the rules index).
  Otherwise `{:ok, rule}`.
  """
  @spec load_rule_for_show(User.t() | nil, any()) ::
          {:ok, Rule.t()} | {:error, :not_found | :unauthorized | :rule_hidden}
  def load_rule_for_show(user, position) do
    with {:ok, rule} <- load_authorized_rule(user, position, :show) do
      if (rule.hidden or rule.internal) and not Canada.Can.can?(user, :edit, rule) do
        {:error, :rule_hidden}
      else
        {:ok, rule}
      end
    end
  end

  @doc """
  Prepares the new-rule form on behalf of `user`.

  Returns `{:error, :unauthorized}` when the viewer may not create rules,
  otherwise `{:ok, changeset}`.
  """
  @spec load_new_rule(User.t() | nil) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def load_new_rule(user) do
    with :ok <- authorize(user, :new, Rule) do
      {:ok, change_rule(%Rule{})}
    end
  end

  @doc """
  Creates a rule (with its initial version) on behalf of `user` from `attrs`.

  Returns `{:error, :unauthorized}` when the viewer may not create rules,
  `{:error, %Ecto.Changeset{}}` on a validation failure, and
  `{:ok, [rule, rule_version]}` on success.
  """
  @spec create_rule(User.t() | nil, map()) ::
          {:ok, [Rule.t() | RuleVersion.t()]}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized}
  def create_rule(user, attrs) do
    with :ok <- authorize(user, :create, Rule) do
      create_rule_with_version(attrs, user)
    end
  end

  @doc """
  Loads the rule at `position` for `user` to be edited.

  Returns `{:error, :not_found}` for a position no row could have,
  `{:error, :unauthorized}` when the viewer may not edit the rule, and otherwise
  `{:ok, {rule, changeset}}`.
  """
  @spec load_rule_for_edit(User.t() | nil, any()) ::
          {:ok, {Rule.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_rule_for_edit(user, position) do
    with {:ok, rule} <- load_authorized_rule(user, position, :edit) do
      {:ok, {rule, change_rule(rule)}}
    end
  end

  @doc """
  Updates the rule at `position` (with a new version) on behalf of `user` from
  `attrs`.

  Returns `{:error, :not_found}` for a position no row could have,
  `{:error, :unauthorized}` when the viewer may not edit the rule,
  `{:error, {rule, changeset}}` on a validation failure (carrying the unchanged
  rule for re-rendering the form), and `{:ok, [rule, rule_version]}` on success.
  """
  @spec update_rule(User.t() | nil, any(), map()) ::
          {:ok, [Rule.t() | RuleVersion.t()]}
          | {:error, {Rule.t(), Ecto.Changeset.t()}}
          | {:error, :not_found | :unauthorized}
  def update_rule(user, position, attrs) do
    with {:ok, rule} <- load_authorized_rule(user, position, :update) do
      case update_rule_with_version(rule, user, attrs) do
        {:ok, [updated_rule, rule_version]} -> {:ok, [updated_rule, rule_version]}
        {:error, changeset} -> {:error, {rule, changeset}}
      end
    end
  end

  # Loads and authorizes the rule at `position` for `action`. Authorization runs
  # against the loaded record, nil included, before the not-found decision: an
  # unknown well-formed position the viewer may not act on comes back
  # unauthorized, and one it may act on comes back not-found.
  defp load_authorized_rule(user, position, action) do
    with {:ok, position} <- IntegerId.parse(position),
         rule = Repo.get_by(Rule, position: position),
         :ok <- authorize(user, action, rule),
         %Rule{} <- rule do
      {:ok, rule}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end
end
