defmodule Philomena.Images.Search.Scope do
  @moduledoc """
  The image search scope: the compiled filter, search parameters, and the
  default pagination window. The actor is passed separately to operations
  that need authorization or viewer-specific behavior.

  Built once by the caller and passed to every image search
  function. `params` keeps its raw string keys; search functions read only
  the keys they understand ("q", "sf", "sd", "sort", "del", "hidden", "rel").
  `filter` is the compiled OpenSearch query body of the viewer's active
  filter and is excluded from every result set.
  """

  @enforce_keys [:filter]
  defstruct filter: nil,
            params: %{},
            pagination: %{page_number: 1, page_size: 25}

  @type t :: %__MODULE__{
          filter: map(),
          params: map(),
          pagination: %{page_number: pos_integer(), page_size: pos_integer()}
        }
end
