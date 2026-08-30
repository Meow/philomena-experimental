defmodule Mix.Tasks.Philomena.ContextBoundaries do
  @moduledoc """
  Enforces the controller/context boundary rules from the context-refactor plan.
  """

  use Mix.Task

  alias Philomena.ContextBoundaryCheck

  @shortdoc "Checks controller/context architectural boundaries"

  @impl Mix.Task
  def run(_args) do
    case ContextBoundaryCheck.violations(File.cwd!()) do
      [] ->
        Mix.shell().info("Context boundary checks passed")

      violations ->
        details =
          Enum.map_join(violations, "\n", fn violation ->
            "#{violation.file}:#{violation.line}: #{violation.message}"
          end)

        Mix.raise("Context boundary violations:\n#{details}")
    end
  end
end
