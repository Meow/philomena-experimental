defmodule Philomena.ContextBoundaryCheck do
  @moduledoc """
  Static architectural checks for controller and domain-context boundaries.

  Elixir-source checks deliberately use the AST so comments, documentation
  examples, and similarly named modules do not create false positives. The
  template and presentation-policy guardrails are intentionally line-aware
  textual checks because Slime templates do not have an Elixir AST at this
  boundary. It is used by the context-boundary test in the repository suite.
  """

  @excluded_modules [
    Philomena.Application,
    Philomena.Attribution,
    Philomena.Config,
    Philomena.ExqSupervisor,
    Philomena.IntegerId,
    Philomena.Mailer,
    Philomena.Maintenance,
    Philomena.Markdown,
    Philomena.Multi,
    Philomena.Native,
    Philomena.Release,
    Philomena.Repo,
    Philomena.SearchIndexer,
    Philomena.SearchMigrator,
    Philomena.SearchPolicy,
    Philomena.SiteStatistics,
    Philomena.Slug
  ]

  # Phase 1 deliberately keeps the compatibility adapter in AppView while
  # callers migrate to context-owned results. Keep this allowlist anchored to
  # the exact source line so a new web-layer Canada call cannot hide behind it.
  @allowed_web_canada_calls MapSet.new([
                              {"lib/philomena_web/views/app_view.ex", 81}
                            ])

  # These are the phase-0 presentation-policy sites. They are temporary
  # migration exceptions, not examples for new code. The line anchor makes a
  # newly added role/ownership predicate fail the boundary check even when it
  # is added to an existing module or template.
  @allowed_presentation_policy_lines MapSet.new([
                                       {"lib/philomena_web/views/tag_change_view.ex", 24},
                                       {"lib/philomena_web/views/profile_view.ex", 22},
                                       {"lib/philomena_web/views/layout_view.ex", 70},
                                       {"lib/philomena_web/views/layout_view.ex", 72},
                                       {"lib/philomena_web/views/source_change_view.ex", 7},
                                       {"lib/philomena_web/views/api/json/profile_view.ex", 37},
                                       {"lib/philomena_web/views/admin/report_view.ex", 25},
                                       {"lib/philomena_web/views/admin/report_view.ex", 26},
                                       {"lib/philomena_web/templates/message/_message.html.slime",
                                        27},
                                       {"lib/philomena_web/templates/admin/user_ban/index.html.slime",
                                        54},
                                       {"lib/philomena_web/templates/admin/subnet_ban/index.html.slime",
                                        59},
                                       {"lib/philomena_web/templates/admin/user/_list.html.slime",
                                        27},
                                       {"lib/philomena_web/templates/admin/user/_list.html.slime",
                                        53},
                                       {"lib/philomena_web/templates/admin/fingerprint_ban/index.html.slime",
                                        58},
                                       {"lib/philomena_web/templates/profile/show.html.slime", 4},
                                       {"lib/philomena_web/templates/profile/show.html.slime",
                                        35},
                                       {"lib/philomena_web/templates/profile/show.html.slime",
                                        47},
                                       {"lib/philomena_web/templates/profile/show.html.slime",
                                        53},
                                       {"lib/philomena_web/templates/profile/show.html.slime",
                                        68},
                                       {"lib/philomena_web/templates/profile/show.html.slime",
                                        82},
                                       {"lib/philomena_web/templates/admin/report/_reports.html.slime",
                                        50},
                                       {"lib/philomena_web/templates/admin/report/_reports.html.slime",
                                        54},
                                       {"lib/philomena_web/templates/admin/report/show.html.slime",
                                        51},
                                       {"lib/philomena_web/templates/profile/_admin_block.html.slime",
                                        170},
                                       {"lib/philomena_web/templates/profile/_admin_block.html.slime",
                                        176},
                                       {"lib/philomena_web/templates/profile/commission/_listing_sidebar.html.slime",
                                        64},
                                       {"lib/philomena_web/templates/profile/_about_me.html.slime",
                                        6},
                                       {"lib/philomena_web/templates/profile/_commission.html.slime",
                                        26},
                                       {"lib/philomena_web/templates/profile/commission/_listing_items.html.slime",
                                        5},
                                       {"lib/philomena_web/templates/profile/commission/_listing_items.html.slime",
                                        11}
                                     ])

  @type violation :: %{
          file: String.t(),
          line: pos_integer(),
          message: String.t()
        }

  @doc """
  Returns context-boundary violations beneath `root`.

  The check covers every top-level `Philomena` domain module except the
  explicitly excluded infrastructure modules, every application source for
  direct Canada calls, every controller for persistence and request-path
  bang-loader calls, and presentation sources for legacy policy probes.

  ## Examples

      iex> ContextBoundaryCheck.violations(File.cwd!())
      []

  """
  @spec violations(String.t()) :: [violation()]
  def violations(root) do
    root
    |> checks()
    |> Enum.sort_by(&{&1.file, &1.line, &1.message})
  end

  @doc """
  Returns only presentation-policy violations in web views and templates.

  This separate entry point is useful to migration tooling; `violations/1`
  includes the same results in the repository-wide boundary check.
  """
  @spec presentation_policy_violations(String.t()) :: [violation()]
  def presentation_policy_violations(root) do
    root
    |> presentation_paths()
    |> Enum.flat_map(&presentation_policy_violations(&1, root))
    |> Enum.sort_by(&{&1.file, &1.line, &1.message})
  end

  defp checks(root) do
    context_paths =
      root
      |> Path.join("lib/philomena/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&excluded_module?/1)

    domain_paths = Path.wildcard(Path.join(root, "lib/philomena/**/*.ex"))
    web_paths = Path.wildcard(Path.join(root, "lib/philomena_web/**/*.ex"))
    template_paths = Path.wildcard(Path.join(root, "lib/philomena_web/**/*.slime"))
    controller_paths = Path.wildcard(Path.join(root, "lib/philomena_web/controllers/**/*.ex"))

    undocumented_functions(context_paths, root) ++
      forbidden_canada_calls(domain_paths ++ web_paths, root) ++
      forbidden_controller_calls(controller_paths, root) ++
      forbidden_template_can_calls(template_paths, root) ++
      presentation_policy_violations(root)
  end

  defp undocumented_functions(paths, root) do
    Enum.flat_map(paths, fn path ->
      path
      |> parse!()
      |> module_bodies()
      |> Enum.flat_map(&undocumented_definitions(&1, relative(path, root)))
    end)
  end

  defp excluded_module?(path) do
    module =
      path
      |> Path.basename(".ex")
      |> Macro.camelize()
      |> then(&Module.concat(Philomena, &1))

    module in @excluded_modules
  end

  defp undocumented_definitions(body, file) do
    body
    |> block_expressions()
    |> Enum.reduce(
      %{documented: MapSet.new(), pending_doc?: false, violations: []},
      fn
        {:@, _meta, [{:doc, _, [_value]}]}, state ->
          %{state | pending_doc?: true}

        {:def, meta, arguments}, state ->
          key = definition_key(arguments)

          cond do
            is_nil(key) ->
              %{state | pending_doc?: false}

            state.pending_doc? or MapSet.member?(state.documented, key) ->
              %{
                state
                | documented: MapSet.put(state.documented, key),
                  pending_doc?: false
              }

            true ->
              {name, arity} = key

              violation = %{
                file: file,
                line: meta[:line] || 1,
                message: "public context function #{name}/#{arity} has no @doc"
              }

              %{state | pending_doc?: false, violations: [violation | state.violations]}
          end

        {:defp, _meta, _arguments}, state ->
          %{state | pending_doc?: false}

        _expression, state ->
          state
      end
    )
    |> Map.fetch!(:violations)
  end

  defp forbidden_canada_calls(paths, root) do
    Enum.flat_map(paths, &canada_violations(&1, root))
  end

  defp canada_violations(path, root) do
    relative_path = relative(path, root)

    if relative_path in [
         "lib/philomena/authorization.ex",
         "lib/philomena/users/ability.ex"
       ] do
      []
    else
      ast = parse!(path)
      aliases = aliases(ast)

      remote_calls(ast, &canada_violation(&1, &2, &3, aliases, relative_path))
    end
  end

  defp canada_violation(module, function, meta, aliases, file) do
    if resolve_module(module, aliases) == "Canada.Can" and function == :can? and
         not allowlisted_web_canada_call?(file, meta[:line]) do
      %{
        file: file,
        line: meta[:line] || 1,
        message: canada_message(file)
      }
    end
  end

  defp allowlisted_web_canada_call?(file, line) do
    MapSet.member?(@allowed_web_canada_calls, {file, line})
  end

  defp canada_message("lib/philomena_web/" <> _),
    do: "web modules must not call Canada.Can.can?/3"

  defp canada_message(_file), do: "contexts must call Philomena.Authorization.authorize/3"

  defp forbidden_controller_calls(paths, root) do
    Enum.flat_map(paths, fn path ->
      ast = parse!(path)
      aliases = aliases(ast)
      relative_path = relative(path, root)

      remote_calls(ast, fn module, function, meta ->
        module = resolve_module(module, aliases)

        cond do
          repo_module?(module) ->
            %{
              file: relative_path,
              line: meta[:line] || 1,
              message: "controllers must not call Repo directly"
            }

          context_bang_loader?(module, function) ->
            %{
              file: relative_path,
              line: meta[:line] || 1,
              message: "controllers must not call bang loaders"
            }

          true ->
            nil
        end
      end)
    end)
  end

  # Paths come only from the fixed context inventory and repository-root
  # wildcards assembled by this offline test, never from request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp parse!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(columns: true, token_metadata: true)
  end

  defp module_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_module, [do: body]]} = node, bodies ->
          {node, [body | bodies]}

        node, bodies ->
          {node, bodies}
      end)

    bodies
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp definition_key([head | _body]) do
    head =
      case head do
        {:when, _meta, [guarded_head | _guards]} -> guarded_head
        head -> head
      end

    case head do
      {name, _meta, arguments} when is_atom(name) and is_list(arguments) ->
        {name, length(arguments)}

      {name, _meta, nil} when is_atom(name) ->
        {name, 0}

      _other ->
        nil
    end
  end

  defp definition_key(_arguments), do: nil

  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta,
         [
           {{:., _, [prefix_ast, :{}]}, _, module_asts}
         ]} = node,
        aliases ->
          prefix = module_name(prefix_ast)

          aliases =
            Enum.reduce(module_asts, aliases, fn module_ast, aliases ->
              suffix = module_name(module_ast)
              Map.put(aliases, short_name(suffix), prefix <> "." <> suffix)
            end)

          {node, aliases}

        {:alias, _meta, [module_ast, options]} = node, aliases when is_list(options) ->
          module = module_name(module_ast)
          alias_name = options |> Keyword.get(:as, module_ast) |> module_name() |> short_name()
          {node, Map.put(aliases, alias_name, module)}

        {:alias, _meta, [module_ast]} = node, aliases ->
          module = module_name(module_ast)
          {node, Map.put(aliases, short_name(module), module)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp remote_calls(ast, callback) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., dot_meta, [module_ast, function]}, call_meta, arguments} = node, violations
        when is_atom(function) and is_list(arguments) ->
          case callback.(module_name(module_ast), function, call_meta || dot_meta) do
            nil -> {node, violations}
            violation -> {node, [violation | violations]}
          end

        node, violations ->
          {node, violations}
      end)

    violations
  end

  defp module_name({:__aliases__, _meta, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp module_name(_other), do: nil

  defp resolve_module(nil, _aliases), do: nil

  defp resolve_module(module, aliases) do
    case String.split(module, ".", parts: 2) do
      [first, rest] -> Map.get(aliases, first, first) <> "." <> rest
      [first] -> Map.get(aliases, first, first)
    end
  end

  defp short_name(nil), do: nil
  defp short_name(module), do: module |> String.split(".") |> List.last()

  defp repo_module?(nil), do: false
  defp repo_module?(module), do: short_name(module) == "Repo"

  defp context_bang_loader?(module, function) do
    function = Atom.to_string(function)

    is_binary(module) and String.starts_with?(module, "Philomena.") and
      String.ends_with?(function, "!") and
      String.match?(function, ~r/^(fetch|get|load)/)
  end

  defp presentation_paths(root) do
    Path.wildcard(Path.join(root, "lib/philomena_web/**/*.{ex,slime}"))
  end

  defp presentation_policy_violations(path, root) do
    relative_path = relative(path, root)

    path
    |> File.stream!(:line, [])
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if policy_line?(line) and
           not MapSet.member?(@allowed_presentation_policy_lines, {relative_path, line_number}) do
        [
          %{
            file: relative_path,
            line: line_number,
            message:
              "web presentation code must not decide policy from roles, role maps, or actor ownership"
          }
        ]
      else
        []
      end
    end)
  end

  defp policy_line?(line) do
    role_or_role_map? =
      String.match?(line, ~r/\brole_map\b/) or
        String.match?(line, ~r/@?[A-Za-z_][\w.@]*\.role\b/)

    ownership_comparison? =
      (not String.match?(line, ~r/\bdefp?\s+current\?\s*\(/) and
         String.match?(line, ~r/\bcurrent\?\s*\(/)) or
        String.match?(
          line,
          ~r/@?[A-Za-z_][\w.@]*\.(?:user_id|owner_id|from_id|to_id|admin_id)\s*==/
        ) or
        String.match?(line, ~r/@?(?:current_user|user|actor|owner)\.id\s*==/) or
        String.match?(line, ~r/==\s*@?(?:current_user|user|actor|owner)\.id/)

    role_or_role_map? or ownership_comparison?
  end

  defp forbidden_template_can_calls(paths, root) do
    allowlist = template_can_allowlist(root)

    Enum.flat_map(paths, fn path ->
      relative_path = relative(path, root)

      path
      |> File.stream!(:line, [])
      |> Stream.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        template_line_violations(line, relative_path, line_number, allowlist)
      end)
    end)
  end

  defp template_line_violations(line, relative_path, line_number, allowlist) do
    calls = Regex.scan(~r/can\?\s*\([^)]*\)/, line, capture: :first)

    calls
    |> Enum.reject(fn [call] ->
      MapSet.member?(allowlist, {relative_path, line_number, String.trim(call)})
    end)
    |> Enum.map(fn _call ->
      %{
        file: relative_path,
        line: line_number,
        message: "templates must not call can?/3; use a context-owned result"
      }
    end)
  end

  # The phase-0 ledger is the reviewed compatibility allowlist for existing
  # template calls. A fixture or a newly added source line has no ledger row
  # and therefore fails immediately.
  defp template_can_allowlist(root) do
    ledger_path = Path.join(root, "plans/context-policy/ledger.md")

    case File.read(ledger_path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reduce(MapSet.new(), &add_template_allowlist_entry/2)

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp add_template_allowlist_entry(line, allowlist) do
    case Regex.run(~r/^\|\s*\d+\s*\|\s*([^|]+):(\d+)\s*\|\s*([^|]+?)\s*\|/, line) do
      [_, source, line_number, call] ->
        source = String.trim(source)

        if String.ends_with?(source, ".html.slime") do
          MapSet.put(allowlist, {source, String.to_integer(line_number), String.trim(call)})
        else
          allowlist
        end

      _ ->
        allowlist
    end
  end

  defp relative(path, root), do: Path.relative_to(path, root)
end
