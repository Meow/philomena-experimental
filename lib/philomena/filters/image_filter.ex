defmodule Philomena.Filters.ImageFilter do
  @moduledoc """
  The compiled image-filter policy for one viewer.

  `query` is the OpenSearch clause used to exclude hidden images. The display
  fields contain the current filter's hidden/spoiler policy for evaluating an
  already-loaded image consistently in HTML and JSON representations.
  """

  alias Philomena.Attribution.Actor
  alias Philomena.Filters.Filter
  alias Philomena.Images.Query
  alias PhilomenaQuery.Parse.String

  @enforce_keys [:query, :display_query, :display_tag_ids]
  defstruct [:query, :display_query, :display_tag_ids]

  @type t :: %__MODULE__{
          query: map(),
          display_query: map(),
          display_tag_ids: [integer()]
        }

  @type compile_error ::
          {:invalid_filter, Filter.t() | nil, :hidden_complex_str | :spoilered_complex_str,
           term()}

  @spec compile(Actor.t(), Filter.t() | nil, Filter.t() | nil) ::
          {:ok, t()} | {:error, compile_error()}
  def compile(%Actor{} = actor, current_filter, forced_filter) do
    current = defaults(current_filter)
    forced = defaults(forced_filter)

    with {:ok, current_hidden} <-
           compile_expression(
             actor,
             current_filter,
             :hidden_complex_str,
             current.hidden_complex_str
           ),
         {:ok, forced_hidden} <-
           compile_expression(
             actor,
             forced_filter,
             :hidden_complex_str,
             forced.hidden_complex_str
           ),
         {:ok, current_spoiler} <-
           compile_expression(
             actor,
             current_filter,
             :spoilered_complex_str,
             current.spoilered_complex_str
           ) do
      hidden_query = %{bool: %{should: [current_hidden, forced_hidden]}}

      {:ok,
       %__MODULE__{
         query: %{
           bool: %{
             should: [
               %{terms: %{tag_ids: current.hidden_tag_ids ++ forced.hidden_tag_ids}},
               hidden_query
             ]
           }
         },
         display_query: %{bool: %{should: [hidden_query, current_spoiler]}},
         display_tag_ids: current.spoilered_tag_ids ++ current.hidden_tag_ids
       }}
    end
  end

  defp compile_expression(actor, filter, field, expression) do
    expression
    |> String.normalize()
    |> Query.compile(user: actor.user, filter: true)
    |> case do
      {:ok, query} -> {:ok, query}
      {:error, reason} -> {:error, {:invalid_filter, filter, field, reason}}
    end
  end

  defp defaults(nil) do
    %{
      hidden_tag_ids: [],
      spoilered_tag_ids: [],
      hidden_complex_str: nil,
      spoilered_complex_str: nil
    }
  end

  defp defaults(%Filter{} = filter), do: filter
end
