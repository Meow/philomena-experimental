defmodule Philomena.Repo do
  use Ecto.Repo,
    otp_app: :philomena,
    adapter: Ecto.Adapters.Postgres

  use Scrivener, page_size: 250

  @type pagination_params :: map() | keyword()
end
