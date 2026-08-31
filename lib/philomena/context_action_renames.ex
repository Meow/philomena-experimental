defmodule Philomena.ContextActionRenames do
  @moduledoc """
  AST-aware codemod for the request-facing context action renames.

  The rename inventory is deliberately read from the Markdown plan rather than
  copied into this module.  Code changes are emitted as Sourceror patches, so
  formatting outside the renamed identifier is left alone.
  """

  alias Sourceror.Patch

  @type mapping :: %{
          required(:module) => module(),
          required(:old) => atom(),
          required(:new) => atom(),
          required(:arity) => non_neg_integer()
        }

  @type file_result :: %{
          path: Path.t(),
          source: String.t(),
          rewritten: String.t(),
          patches: non_neg_integer()
        }

  @doc """
  Parses the rename matrix in `path`.

  A row such as `foo/1,2` is expanded into one mapping per arity.  This is
  important for rows where the same old name has different targets at
  different arities.
  """
  @spec load_plan(Path.t()) :: {:ok, [mapping()]} | {:error, term()}
  def load_plan(path) do
    path
    |> File.read()
    |> case do
      {:ok, contents} -> {:ok, parse_plan(contents)}
      error -> error
    end
  end

  @doc "Raises unless `path` contains a valid rename matrix."
  @spec load_plan!(Path.t()) :: [mapping()]
  def load_plan!(path) do
    case load_plan(path) do
      {:ok, mappings} ->
        mappings

      {:error, reason} ->
        raise ArgumentError, "could not read rename plan #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Rewrites one Elixir source string.

  `:comments` defaults to `true`.  Set it to `false` for code-only changes, or
  set `:comments_only` to `true` to rewrite comments without changing code.
  """
  @spec rewrite_string(String.t(), [mapping()], keyword()) :: String.t()
  def rewrite_string(source, mappings, opts \\ []) do
    ast = Sourceror.parse_string!(source)
    data = discover(ast)
    {rewritten, _patch_count} = rewrite_parsed(source, ast, mappings, data, opts)
    rewritten
  end

  @doc """
  Rewrites the supplied Elixir files.  Files are parsed before any writes are
  made, which prevents a syntax error in a later file from leaving a partial
  codemod behind.
  """
  @spec rewrite_files([Path.t()], [mapping()], keyword()) :: [file_result()]
  def rewrite_files(paths, mappings, opts \\ []) do
    parsed =
      Enum.map(paths, fn path ->
        source = File.read!(path)
        ast = Sourceror.parse_string!(source)
        %{path: path, source: source, ast: ast, data: discover(ast)}
      end)

    data =
      Enum.reduce(parsed, empty_data(), fn %{data: file_data}, acc ->
        merge_data(acc, file_data)
      end)

    Enum.map(parsed, fn %{path: path, source: source, ast: ast} ->
      {rewritten, patch_count} = rewrite_parsed(source, ast, mappings, data, opts)
      %{path: path, source: source, rewritten: rewritten, patches: patch_count}
    end)
  end

  @doc false
  def parse_plan(contents) do
    {mappings, _context} =
      contents
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {mappings, context} ->
        case Regex.run(~r/^### `([^`]+)`\s*$/, line, capture: :all_but_first) do
          [module_name] ->
            {mappings, module_from_string(module_name)}

          nil ->
            case Regex.run(~r/^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`/, line, capture: :all_but_first) do
              [old_signature, new_signature] when not is_nil(context) ->
                {parse_row(mappings, context, old_signature, new_signature), context}

              _ ->
                {mappings, context}
            end
        end
      end)

    mappings
    |> validate_mappings!()
    |> Enum.uniq_by(&{&1.module, &1.old, &1.arity})
  end

  defp parse_row(mappings, module, old_signature, new_signature) do
    {old_name, old_arities} = parse_signature!(old_signature)
    {new_name, new_arities} = parse_signature!(new_signature)

    if length(old_arities) != length(new_arities) do
      raise ArgumentError,
            "rename row for #{inspect(module)}.#{old_signature} has mismatched arities"
    end

    Enum.zip(old_arities, new_arities)
    |> Enum.map(fn {old_arity, new_arity} ->
      if old_arity != new_arity do
        raise ArgumentError,
              "rename row for #{inspect(module)}.#{old_signature} changes arity"
      end

      %{module: module, old: old_name, new: new_name, arity: old_arity}
    end)
    |> then(&(mappings ++ &1))
  end

  defp parse_signature!(signature) do
    case String.split(signature, "/", parts: 2) do
      [name, arities] ->
        parsed_arities =
          arities
          |> String.split(",")
          |> Enum.map(fn arity ->
            case Integer.parse(String.trim(arity)) do
              {value, ""} when value >= 0 -> value
              _ -> raise ArgumentError, "invalid function arity in #{inspect(signature)}"
            end
          end)

        if parsed_arities == [] or not Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_?!]*$/, name) do
          raise ArgumentError, "invalid function signature #{inspect(signature)}"
        end

        {String.to_atom(name), parsed_arities}

      _ ->
        raise ArgumentError, "invalid function signature #{inspect(signature)}"
    end
  end

  defp validate_mappings!(mappings) do
    mappings
    |> Enum.group_by(&{&1.module, &1.old, &1.arity})
    |> Enum.each(fn {key, rows} ->
      targets = rows |> Enum.map(& &1.new) |> Enum.uniq()

      if length(targets) > 1 do
        raise ArgumentError, "conflicting rename targets for #{inspect(key)}"
      end
    end)

    mappings
  end

  defp module_from_string(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
    |> Module.concat()
  end

  defp empty_data do
    %{modules: %{}}
  end

  defp discover(ast) do
    {_ast, data} = Macro.traverse(ast, empty_discovery_state(), &discover_pre/2, &discover_post/2)
    %{modules: data.modules}
  end

  defp empty_discovery_state do
    %{stack: [], modules: %{}}
  end

  defp discover_pre({:defmodule, _meta, [module_ast | _]} = node, state) do
    module = module_from_ast(module_ast)
    state = %{state | stack: [module | state.stack]}
    {node, ensure_module(state, module)}
  end

  defp discover_pre(node, state) do
    case current_module(state) do
      nil ->
        {node, state}

      module ->
        state =
          cond do
            match?({kind, _, [_ | _]} when kind in [:def, :defmacro, :defdelegate], node) ->
              collect_definition(state, module, node, true)

            match?({:defp, _, [_ | _]}, node) ->
              collect_definition(state, module, node, false)

            match?({:alias, _, [_ | _]}, node) ->
              collect_alias(state, module, node)

            match?({:import, _, [_ | _]}, node) ->
              collect_import(state, module, node)

            true ->
              state
          end

        {node, state}
    end
  end

  defp discover_post({:defmodule, _meta, _} = node, state),
    do: {node, %{state | stack: tl(state.stack)}}

  defp discover_post(node, state), do: {node, state}

  defp current_module(%{stack: [module | _]}), do: module
  defp current_module(_state), do: nil

  defp ensure_module(state, module) do
    update_in(state.modules, fn modules ->
      Map.put_new(modules, module, %{
        public: MapSet.new(),
        definitions: %{},
        aliases: %{},
        imports: []
      })
    end)
  end

  defp collect_definition(state, module, {_kind, _meta, [head | _]}, public?) do
    case function_head(head) do
      {name, meta, arities} ->
        data = state.modules[module]
        key = {name, meta[:line], meta[:column]}

        definitions =
          Map.update(data.definitions, key, %{arities: arities, public?: public?}, fn existing ->
            %{existing | public?: existing.public? or public?}
          end)

        public =
          if public?,
            do: Enum.reduce(arities, data.public, &MapSet.put(&2, {name, &1})),
            else: data.public

        data = %{data | public: public, definitions: definitions}
        put_in(state.modules[module], data)

      nil ->
        state
    end
  end

  defp function_head({:when, _meta, [call | _]}), do: function_head(call)

  defp function_head({name, meta, args}) when is_atom(name) and is_list(meta) do
    max_arity = if is_list(args), do: length(args), else: 0
    defaults = if is_list(args), do: Enum.count(args, &default_argument?/1), else: 0
    {name, meta, Enum.to_list((max_arity - defaults)..max_arity)}
  end

  defp function_head(_), do: nil

  defp default_argument?({:\\, _, [_expression]}), do: true
  defp default_argument?(_), do: false

  defp collect_alias(state, module, {:alias, _meta, [module_ast | opts]}) do
    opts = normalize_options(opts)

    module_ast
    |> alias_targets()
    |> Enum.reduce(state, fn target, state ->
      case alias_name(target, opts) do
        nil -> state
        alias_name -> put_in(state.modules[module].aliases[alias_name], target)
      end
    end)
  end

  defp alias_name(target, opts) do
    case option_value(opts, :as) do
      nil ->
        target |> Module.split() |> List.last() |> String.to_atom()

      {:__aliases__, _meta, segments} ->
        segments |> flatten_alias_segments() |> List.last()

      value when is_atom(value) ->
        value

      _ ->
        nil
    end
  end

  defp alias_targets({{:., _, [base, :{}]}, _, children}) do
    case module_from_ast(base) do
      nil ->
        []

      base ->
        Enum.flat_map(children, fn child ->
          case module_from_ast(child) do
            child when not is_nil(child) -> [Module.concat([base, child])]
            _ -> []
          end
        end)
    end
  end

  defp alias_targets(module_ast) do
    case module_from_ast(module_ast) do
      nil -> []
      module -> [module]
    end
  end

  defp collect_import(state, module, {:import, _meta, [module_ast | opts]}) do
    opts = normalize_options(opts)

    case module_from_ast(module_ast) do
      nil ->
        state

      imported_module ->
        only =
          case option_value(opts, :only) do
            nil ->
              :all

            values when is_list(values) ->
              values
              |> Enum.map(&import_spec/1)
              |> Enum.filter(&match?({name, arity} when is_atom(name) and is_integer(arity), &1))
              |> MapSet.new()

            _ ->
              :all
          end

        update_in(state.modules[module].imports, &[%{module: imported_module, only: only} | &1])
    end
  end

  defp option_value(opts, key) when is_list(opts) do
    Enum.find_value(opts, fn
      {option, value} ->
        if keyword_key(option) == key, do: unwrap_literal(value)

      _ ->
        nil
    end)
  end

  defp normalize_options([options]) when is_list(options), do: options
  defp normalize_options(options), do: options

  defp keyword_key({:__block__, _meta, [key]}) when is_atom(key), do: key
  defp keyword_key(key) when is_atom(key), do: key
  defp keyword_key(_), do: nil

  defp unwrap_literal({:__block__, _meta, [value]}), do: value
  defp unwrap_literal(value), do: value

  defp import_spec({name, arity}) do
    case {keyword_key(name), unwrap_literal(arity)} do
      {name, arity} when is_atom(name) and is_integer(arity) -> {name, arity}
      _ -> nil
    end
  end

  defp import_spec(_), do: nil

  defp module_from_ast({:__aliases__, _meta, segments}) do
    segments = flatten_alias_segments(segments)
    if Enum.all?(segments, &is_atom/1), do: Module.concat(segments), else: nil
  end

  defp module_from_ast(module) when is_atom(module), do: module
  defp module_from_ast(_), do: nil

  defp flatten_alias_segments(segments) when is_list(segments) do
    Enum.flat_map(segments, fn segment ->
      if is_atom(segment), do: [segment], else: flatten_alias_segments(segment)
    end)
  end

  defp flatten_alias_segments({:__aliases__, _meta, segments}),
    do: flatten_alias_segments(segments)

  defp flatten_alias_segments(_), do: []

  defp merge_data(left, right) do
    modules =
      Map.merge(left.modules, right.modules, fn _module, left_data, right_data ->
        %{
          public: MapSet.union(left_data.public, right_data.public),
          definitions: Map.merge(left_data.definitions, right_data.definitions),
          aliases: Map.merge(left_data.aliases, right_data.aliases),
          imports: left_data.imports ++ right_data.imports
        }
      end)

    %{modules: modules}
  end

  defp rewrite_parsed(source, ast, mappings, data, opts) do
    mapping_index = Map.new(mappings, &{{&1.module, &1.old, &1.arity}, &1.new})
    comments? = Keyword.get(opts, :comments, true)
    comments_only? = Keyword.get(opts, :comments_only, false)

    patches =
      if comments_only? do
        []
      else
        {_ast, state} =
          Macro.traverse(
            ast,
            %{stack: [], patches: [], seen: MapSet.new(), mappings: mapping_index, data: data},
            &rewrite_pre/2,
            &rewrite_post/2
          )

        state.patches
      end

    patches = if comments?, do: patches ++ comment_patches(ast, mappings), else: patches
    {Sourceror.patch_string(source, patches), length(patches)}
  end

  defp rewrite_pre({:defmodule, _meta, [module_ast | _]} = node, state) do
    {node, %{state | stack: [module_from_ast(module_ast) | state.stack]}}
  end

  defp rewrite_pre({:def, _meta, [head | _]} = node, state) do
    {node, maybe_definition_patch(state, head, true)}
  end

  defp rewrite_pre({:defmacro, _meta, [head | _]} = node, state) do
    {node, maybe_definition_patch(state, head, true)}
  end

  defp rewrite_pre({:defdelegate, _meta, [head | _]} = node, state) do
    {node, maybe_definition_patch(state, head, true)}
  end

  defp rewrite_pre({:defp, _meta, _} = node, state), do: {node, state}

  defp rewrite_pre({:@, _meta, [{:spec, _, [spec]}]} = node, state) do
    state =
      state
      |> add_spec_patches(spec)

    {node, state}
  end

  defp rewrite_pre({:&, _meta, [{:/, _slash_meta, [reference, arity]}]} = node, state)
       when is_integer(arity) do
    {node, add_reference_patch(state, reference, arity)}
  end

  defp rewrite_pre({{:., _dot_meta, [receiver, name]}, _meta, args} = node, state)
       when is_atom(name) and is_list(args) do
    {node, add_remote_call_patch(state, node, receiver, name, length(args))}
  end

  defp rewrite_pre({name, meta, args} = node, state) when is_atom(name) and is_list(args) do
    {node, add_local_call_patch(state, name, meta, length(args))}
  end

  defp rewrite_pre(node, state), do: {node, state}

  defp rewrite_post({:defmodule, _meta, _} = node, state),
    do: {node, %{state | stack: tl(state.stack)}}

  defp rewrite_post(node, state), do: {node, state}

  defp maybe_definition_patch(state, head, public?) do
    module = current_module(state)

    with true <- public?,
         {name, meta, arities} <- function_head(head),
         module_data when not is_nil(module_data) <- state.data.modules[module],
         %{public?: true} <- Map.get(module_data.definitions, {name, meta[:line], meta[:column]}),
         targets when targets != [] <- Enum.map(arities, &state.mappings[{module, name, &1}]),
         true <- Enum.all?(targets, &(is_atom(&1) and not is_nil(&1))),
         [new_name] <- Enum.uniq(targets),
         true <- new_name != name do
      add_patch(state, rename_name_patch({name, meta, arities}, new_name))
    else
      _ -> state
    end
  end

  defp add_local_call_patch(state, name, meta, arity) do
    if meta[:format] == :keyword or definition_position?(state, meta) do
      state
    else
      case local_target(state, name, arity) do
        new_name when is_atom(new_name) and not is_nil(new_name) and new_name != name ->
          add_patch(state, rename_name_patch({name, meta, []}, new_name))

        _ ->
          state
      end
    end
  end

  defp add_remote_call_patch(state, node, receiver, name, arity) do
    with module when not is_nil(module) <-
           resolve_module(receiver, current_module(state), state.data),
         new_name when is_atom(new_name) and not is_nil(new_name) <-
           state.mappings[{module, name, arity}],
         true <- new_name != name do
      add_patch(state, Patch.rename_call(node, new_name))
    else
      _ -> state
    end
  end

  defp local_target(state, name, arity) do
    module = current_module(state)

    own_target =
      if public?(state.data, module, name, arity), do: state.mappings[{module, name, arity}]

    imported_targets =
      imports(state.data, module)
      |> Enum.filter(&imported_function?(&1, name, arity))
      |> Enum.map(&state.mappings[{&1.module, name, arity}])
      |> Enum.filter(&is_atom/1)

    case Enum.uniq(List.wrap(own_target) ++ imported_targets) do
      [target] -> target
      _ -> nil
    end
  end

  defp public?(data, module, name, arity) do
    data.modules
    |> Map.get(module, %{})
    |> Map.get(:public, MapSet.new())
    |> MapSet.member?({name, arity})
  end

  defp imports(data, module), do: Map.get(data.modules, module, %{}) |> Map.get(:imports, [])

  defp imported_function?(%{only: :all}, _name, _arity), do: true
  defp imported_function?(%{only: only}, name, arity), do: MapSet.member?(only, {name, arity})

  defp resolve_module({:__aliases__, _meta, segments}, current, data) do
    segments = flatten_alias_segments(segments)

    case segments do
      [first | rest] when is_atom(first) ->
        aliases = Map.get(data.modules, current, %{}) |> Map.get(:aliases, %{})
        Module.concat([Map.get(aliases, first, first) | rest])

      _ ->
        nil
    end
  end

  defp resolve_module(:__MODULE__, current, _data), do: current
  defp resolve_module(_, _, _), do: nil

  defp definition_position?(state, meta) do
    state.data.modules
    |> Map.values()
    |> Enum.any?(fn module_data ->
      Enum.any?(module_data.definitions, fn {{_name, line, column}, _} ->
        line == meta[:line] and column == meta[:column]
      end)
    end)
  end

  defp add_spec_patches(state, spec) do
    {_spec, state} =
      Macro.prewalk(spec, state, fn
        {:/, _meta, [reference, arity]} = node, state when is_integer(arity) ->
          {node, add_reference_patch(state, reference, arity)}

        node, state ->
          {node, state}
      end)

    state
  end

  defp add_reference_patch(
         state,
         {{:., _dot_meta, [receiver, name]}, _meta, _args} = reference,
         arity
       )
       when is_atom(name) and is_integer(arity) do
    with target_module when not is_nil(target_module) <-
           resolve_module(receiver, current_module(state), state.data),
         new_name when is_atom(new_name) and not is_nil(new_name) <-
           state.mappings[{target_module, name, arity}],
         true <- new_name != name do
      add_patch(state, Patch.rename_call(reference, new_name))
    else
      _ -> state
    end
  end

  defp add_reference_patch(state, {name, meta, _args}, arity)
       when is_atom(name) and is_integer(arity) do
    case local_target(state, name, arity) do
      new_name when is_atom(new_name) and not is_nil(new_name) and new_name != name ->
        add_patch(state, rename_name_patch({name, meta, []}, new_name))

      _ ->
        state
    end
  end

  defp add_reference_patch(state, _reference, _arity), do: state

  defp rename_name_patch({name, meta, _args}, new_name) do
    line = meta[:line]
    column = meta[:column]

    range = %{
      start: [line: line, column: column],
      end: [line: line, column: column + String.length(to_string(name))]
    }

    Patch.new(range, to_string(new_name))
  end

  defp add_patch(state, patch) do
    key = patch_key(patch)

    if MapSet.member?(state.seen, key) do
      state
    else
      %{state | patches: [patch | state.patches], seen: MapSet.put(state.seen, key)}
    end
  end

  defp patch_key(%{range: %{start: start, end: finish}}), do: {start, finish}

  defp comment_patches(ast, mappings) do
    {_ast, comments} = Sourceror.Comments.extract_comments(ast)
    replacements = comment_replacements(mappings)

    comments
    |> Enum.map(fn comment ->
      rewritten =
        Enum.reduce(replacements, comment.text, fn {pattern, replacement}, text ->
          Regex.replace(pattern, text, replacement)
        end)

      if rewritten == comment.text do
        nil
      else
        column = comment[:column] || 1

        range = %{
          start: [line: comment.line, column: column],
          end: [line: comment.line, column: column + String.length(comment.text)]
        }

        Patch.new(range, rewritten)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp comment_replacements(mappings) do
    mappings
    |> Enum.group_by(&{&1.old, &1.arity})
    |> Enum.flat_map(fn {{old, arity}, rows} ->
      targets = Enum.uniq(Enum.map(rows, & &1.new))

      if length(targets) == 1,
        do: [
          {identifier_pattern("#{old}/#{arity}"),
           Atom.to_string(hd(targets)) <> "/" <> Integer.to_string(arity)}
        ],
        else: []
    end)
    |> Kernel.++(bare_comment_replacements(mappings))
    |> Enum.sort_by(fn {pattern, _replacement} -> Regex.source(pattern) end, :desc)
  end

  defp bare_comment_replacements(mappings) do
    mappings
    |> Enum.group_by(& &1.old)
    |> Enum.flat_map(fn {old, rows} ->
      targets = Enum.uniq(Enum.map(rows, & &1.new))

      if length(targets) == 1,
        do: [{identifier_pattern(Atom.to_string(old)), Atom.to_string(hd(targets))}],
        else: []
    end)
  end

  defp identifier_pattern(identifier) do
    ~r/(?<![A-Za-z0-9_?!:])#{Regex.escape(identifier)}(?![A-Za-z0-9_?!])/u
  end
end
