defmodule Philomena.TagChanges.QueryBuilder do
  @moduledoc false

  import Ecto.Changeset

  alias Philomena.TagChanges.Query
  alias Philomena.TagChanges.QueryForm

  @doc """
  Validates the listing parameters and builds the OpenSearch query and sort.

  The caller supplies the already-authorized query capabilities in `options`.
  Invalid sort or query syntax returns the rejected query-form changeset.
  """
  @spec build_query(map(), keyword()) ::
          {:ok, map(), QueryForm.t()} | {:error, Ecto.Changeset.t()}
  def build_query(params \\ %{}, options \\ []) do
    changeset =
      %QueryForm{}
      |> QueryForm.changeset(params)
      |> compile_query(options)

    with {:ok, query_form} <- apply_action(changeset, :create) do
      body = %{
        query: query_form.compiled_query,
        sort: [
          %{Atom.to_string(query_form.sf) => query_form.sd},
          %{"id" => query_form.sd}
        ]
      }

      {:ok, body, query_form}
    end
  end

  defp compile_query(%Ecto.Changeset{valid?: false} = changeset, _options), do: changeset

  defp compile_query(changeset, options) do
    case Query.compile(get_field(changeset, :tcq),
           user: options[:user],
           identity_metadata?: options[:identity_metadata?] || false
         ) do
      {:ok, query} ->
        put_change(changeset, :compiled_query, query)

      {:error, message} ->
        add_error(changeset, :tcq, message)
    end
  end
end
