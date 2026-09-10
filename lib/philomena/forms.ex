defmodule Philomena.Forms do
  @moduledoc """
  Helpers for building and applying changesets for form schemas.

  Form schemas are modules that expose a `changeset/2` function. `change_if/2`
  builds a changeset for display, while `create/2` and `update/2` apply the
  corresponding Ecto action. `copy_errors/2` transfers validation errors to a
  separate form changeset.
  """

  @doc """
  Copies validation errors from `source_changeset` onto `target`.

  `target` may be a schema struct or an existing changeset. Error messages,
  options, and the source action are preserved, which lets a persistence
  changeset report its errors through the form submitted by the caller.

  ## Examples

      iex> source = add_error(Ecto.Changeset.change(%Form{}), :anonymous, "is invalid")
      iex> copied = copy_errors(source, %Form{})
      iex> copied.errors
      [anonymous: {"is invalid", []}]

  """
  @spec copy_errors(Ecto.Changeset.t(source), target | Ecto.Changeset.t(target)) ::
          Ecto.Changeset.t(target)
        when source: struct(), target: struct()
  def copy_errors(%Ecto.Changeset{} = source_changeset, target) do
    target_changeset =
      Enum.reduce(source_changeset.errors, Ecto.Changeset.change(target), fn
        {field, {message, opts}}, target_changeset ->
          Ecto.Changeset.add_error(target_changeset, field, message, opts)
      end)

    %{target_changeset | action: source_changeset.action}
  end

  @doc """
  Builds a changeset for a source when `condition` is true.

  This is used for rendering optional affordances.

  The schema module must provide a `changeset/2` function.

  ## Examples

      iex> changeset = change_if(fn -> %Form{description: "A description"} end, true)
      iex> changeset.data
      %Form{description: "A description"}

  """
  @spec change_if((-> source), boolean()) :: Ecto.Changeset.t(source) | nil
        when source: struct()
  def change_if(source, condition) do
    if condition do
      source = source.()
      source.__struct__.changeset(source, %{})
    end
  end

  @doc """
  Validates `attrs` with `schema` and applies the `:create` action.

  The schema module must provide a `changeset/2` function.

  Returns `{:ok, struct}` when the form is valid, or `{:error, changeset}`
  when validation fails.

  ## Examples

      iex> {:ok, form} = create(Form, %{anonymous: true})
      iex> form.anonymous
      true

  """
  @spec create(module(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  def create(schema, attrs) do
    apply_attrs(schema, attrs, :create)
  end

  @doc """
  Validates `attrs` against the populated `source` projection and applies the
  `:update` action.

  The schema module must provide a `changeset/2` function.

  Returns `{:ok, struct, changes}` when the form is valid. `struct` is the
  applied presentation value, while `changes` contains only the submitted
  changes and can be passed to the persistence changeset. Returns
  `{:error, changeset}` when validation fails.

  ## Examples

      iex> {:ok, form, changes} = update(%Form{comments_locked: false}, %{comments_locked: true})
      iex> form.comments_locked
      true
      iex> changes
      %{comments_locked: true}

  """
  @spec update(source, map()) ::
          {:ok, source, map()} | {:error, Ecto.Changeset.t(source)}
        when source: struct()
  def update(%schema{} = source, attrs) do
    changeset = schema.changeset(source, attrs)

    case Ecto.Changeset.apply_action(changeset, :update) do
      {:ok, updated_source} -> {:ok, updated_source, changeset.changes}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec apply_attrs(module(), map(), atom()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  defp apply_attrs(schema, attrs, action) do
    schema
    |> struct!()
    |> schema.changeset(attrs)
    |> Ecto.Changeset.apply_action(action)
  end
end
