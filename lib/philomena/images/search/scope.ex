defmodule Philomena.Images.Search.Scope do
  @moduledoc """
  The viewer's image search scope: who is searching, their compiled filter,
  the search parameters, and the default pagination window.

  Built once by the caller and passed to every image search
  function. `params` keeps its raw string keys; search functions read only
  the keys they understand ("q", "sf", "sd", "sort", "del", "hidden", "rel").
  `filter` is the compiled OpenSearch query body of the viewer's active
  filter and is excluded from every result set.
  """

  # FIXME: this gets used as a replacement for Actor.
  # It is not a replacement for Actor. Actor must always be the mechanism
  # via which authorization is performed.

  alias Philomena.Users.User

  @enforce_keys [:user, :filter]
  defstruct user: nil,
            filter: nil,
            params: %{},
            pagination: %{page_number: 1, page_size: 25}

  @type t :: %__MODULE__{
          user: User.t() | nil,
          filter: map(),
          params: map(),
          pagination: %{page_number: pos_integer(), page_size: pos_integer()}
        }
end
