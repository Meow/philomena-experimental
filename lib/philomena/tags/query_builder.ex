defmodule Philomena.Tags.QueryBuilder do
  @moduledoc false

  import Ecto.Changeset

  alias Philomena.Tags.Query
  alias Philomena.Tags.QueryForm

  @doc """
  Validates tag-search input and builds its deterministic OpenSearch body.
  """
  @spec build_query(map()) ::
          {:ok, map(), QueryForm.t()} | {:error, Ecto.Changeset.t()}
  def build_query(params \\ %{}) do
    changeset =
      %QueryForm{}
      |> QueryForm.changeset(params)
      |> compile_query()

    with {:ok, query_form} <- apply_action(changeset, :create) do
      body = %{
        query: query_form.compiled_query,
        sort: [%{images: :desc}, %{name: :asc}, %{id: :asc}]
      }

      {:ok, body, query_form}
    end
  end

  defp compile_query(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp compile_query(changeset) do
    case Query.compile(get_field(changeset, :query)) do
      {:ok, query} -> put_change(changeset, :compiled_query, query)
      {:error, message} -> add_error(changeset, :query, message)
    end
  end
end
