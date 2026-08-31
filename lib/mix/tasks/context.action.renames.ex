defmodule Mix.Tasks.Context.Action.Renames do
  use Mix.Task

  alias Philomena.ContextActionRenames

  @shortdoc "Preview or apply context action renames from the plan"
  @moduledoc """
  Applies the request-facing context action rename matrix.

      mix context.action.renames
      mix context.action.renames --write
      mix context.action.renames --comments-only --write

  The default is a preview.  `--write` is required to change files.  Use
  `--no-comments` for code-only edits, or `--comments-only` to rewrite only
  comments.
  """

  @switches [
    plan: :string,
    root: :string,
    write: :boolean,
    no_comments: :boolean,
    comments_only: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      raise Mix.Error, "invalid options: #{inspect(invalid)}"
    end

    root = Path.expand(opts[:root] || File.cwd!())
    plan = Path.expand(opts[:plan] || "plans/context-action-renames.md", root)
    mappings = ContextActionRenames.load_plan!(plan)
    paths = source_paths(root, paths)

    results =
      ContextActionRenames.rewrite_files(paths, mappings,
        comments: opts[:no_comments] != true,
        comments_only: opts[:comments_only]
      )

    changed = Enum.filter(results, &(&1.source != &1.rewritten))

    Enum.each(changed, fn result ->
      action = if opts[:write], do: "write", else: "would write"
      Mix.shell().info("#{action} #{Path.relative_to(result.path, root)}")

      if opts[:write], do: File.write!(result.path, result.rewritten)
    end)

    Mix.shell().info(
      "#{length(changed)} file(s) #{if(opts[:write], do: "updated", else: "would change")}"
    )
  end

  defp source_paths(root, []) do
    ["lib", "test"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1 <> "/**/*.{ex,exs}")))
    |> Enum.sort()
  end

  defp source_paths(root, paths) do
    Enum.map(paths, fn path ->
      path = Path.expand(path, root)
      if File.regular?(path), do: path, else: raise(Mix.Error, "not a regular file: #{path}")
    end)
  end
end
