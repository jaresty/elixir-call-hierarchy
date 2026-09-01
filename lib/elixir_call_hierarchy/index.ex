defmodule ElixirCallHierarchy.Index do
  @moduledoc false

  defstruct definitions: [], calls: [], unsupported: []

  def build(root) do
    temporary =
      Path.join(System.tmp_dir!(), "elixir-call-hierarchy-#{System.unique_integer([:positive])}")

    try do
      build(root, Path.join(temporary, "build"))
    after
      File.rm_rf!(temporary)
    end
  end

  def build(root, build_path, opts \\ []) do
    root = Path.expand(root)
    File.mkdir_p!(build_path)
    profile? = Keyword.get(opts, :profile, false)

    definitions =
      ElixirCallHierarchy.Profile.measure(profile?, "definition_parse", fn ->
        root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.flat_map(&definitions/1)
      end)

    calls = compile(root, definitions, build_path, profile?)
    %__MODULE__{definitions: definitions, calls: calls, unsupported: []}
  end

  def document_symbols(%__MODULE__{definitions: definitions}, file) do
    file = Path.expand(file)

    definitions
    |> Enum.filter(&(&1.file == file))
    |> Enum.sort_by(fn definition ->
      {definition.range.start.line, definition.range.start.character, definition.identity}
    end)
  end

  def prepare(%__MODULE__{definitions: definitions}, file, line) do
    definitions
    |> Enum.filter(
      &(&1.file == Path.expand(file) and line >= &1.range.start.line and line <= &1.range.end.line)
    )
    |> Enum.min_by(&range_size/1, fn -> nil end)
  end

  def incoming(%__MODULE__{} = index, target) do
    index.calls
    |> Enum.filter(&(&1.target == target.identity))
    |> Enum.group_by(& &1.caller)
    |> related_definitions(index)
  end

  def outgoing(%__MODULE__{} = index, caller) do
    index.calls
    |> Enum.filter(&(&1.caller == caller.identity))
    |> Enum.group_by(& &1.target)
    |> related_definitions(index)
  end

  defp related_definitions(grouped_calls, index) do
    grouped_calls
    |> Enum.map(fn {identity, calls} ->
      definition = Enum.find(index.definitions, &(&1.identity == identity))

      %{
        definition: definition,
        ranges: calls |> Enum.map(& &1.call_range) |> Enum.uniq() |> Enum.sort_by(&range_key/1)
      }
    end)
    |> Enum.reject(&is_nil(&1.definition))
    |> Enum.sort_by(fn %{definition: definition} ->
      {definition.file, definition.range.start.line, definition.identity}
    end)
  end

  defp definitions(file) do
    source = File.read!(file)
    source_lines = String.split(source, "\n")
    {:ok, ast} = Code.string_to_quoted(source, columns: true, token_metadata: true)
    {_ast, {_module, found}} = Macro.traverse(ast, {nil, []}, &pre/2, &post/2)

    found
    |> Enum.map(fn definition ->
      end_character = source_lines |> Enum.at(definition.range.end.line, "") |> String.length()
      range = %{definition.range | end: %{definition.range.end | character: end_character}}
      %{definition | file: Path.expand(file), range: range}
    end)
    |> Enum.reverse()
    |> Enum.group_by(& &1.identity)
    |> Enum.map(fn {identity, clauses} ->
      first = Enum.min_by(clauses, & &1.range.start.line)
      last = Enum.max_by(clauses, & &1.range.end.line)
      %{first | identity: identity, range: %{start: first.range.start, end: last.range.end}}
    end)
  end

  defp pre({:defmodule, _meta, [{:__aliases__, _, parts}, _]} = node, {_module, found}),
    do: {node, {Module.concat(parts), found}}

  defp pre({kind, meta, [head | _]} = node, {module, found})
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {name, args} = function_head(head)
    arity = length(args || [])
    line = meta[:line]
    end_line = get_in(meta, [:end, :line]) || line
    column = max((meta[:column] || 1) - 1, 0)
    identity = {module, name, arity}

    definition = %{
      identity: identity,
      file: nil,
      kind: kind,
      range: range(line, column, end_line, column + String.length(to_string(name)))
    }

    {node, {module, [definition | found]}}
  end

  defp pre(node, state), do: {node, state}
  defp post(node, state), do: {node, state}

  defp compile(root, definitions, _build_path, profile?) do
    previous_build = System.get_env("MIX_BUILD_PATH")
    previous_deps = System.get_env("MIX_DEPS_PATH")
    previous_options = Code.compiler_options()
    previous_code_path = :code.get_path()
    deps_path = Path.join(root, "deps")
    Process.register(self(), ElixirCallHierarchy.Collector)
    System.delete_env("MIX_BUILD_PATH")
    System.put_env("MIX_DEPS_PATH", deps_path)

    try do
      ElixirCallHierarchy.Profile.measure(profile?, "project_compile", fn ->
        compile_project(root, previous_options, profile?)
      end)

      ElixirCallHierarchy.Profile.measure(profile?, "tracer_drain", fn ->
        drain([], definitions)
      end)
    after
      Code.compiler_options(previous_options)
      :code.set_path(previous_code_path)
      Process.unregister(ElixirCallHierarchy.Collector)
      restore_env("MIX_BUILD_PATH", previous_build)
      restore_env("MIX_DEPS_PATH", previous_deps)
    end
  end

  defp compile_project(root, previous_options, profile?) do
    Code.ensure_loaded!(ElixirCallHierarchy.Tracer)
    cache_key = {:app, :elixir_call_hierarchy_workspace}
    previous_project = Mix.State.read_cache(cache_key)
    Mix.State.delete_cache(cache_key)

    try do
      Mix.ProjectStack.on_clean_slate(fn ->
        Mix.Project.in_project(:elixir_call_hierarchy_workspace, root, fn _ ->
          Mix.Task.clear()
          config = Path.join(root, "config/config.exs")
          if File.regular?(config), do: Mix.Task.run("loadconfig", [config])

          ElixirCallHierarchy.Profile.measure(profile?, "deps_compile", fn ->
            Mix.Task.run("deps.compile")
          end)

          ElixirCallHierarchy.Profile.measure(profile?, "deps_loadpaths", fn ->
            Mix.Task.run("deps.loadpaths", ["--no-deps-check"])
          end)

          Code.compiler_options(tracers: [ElixirCallHierarchy.Tracer])

          try do
            case Mix.Task.run("compile", ["--force", "--no-deps-check"]) do
              result when elem(result, 0) in [:ok, :noop] -> :ok
              result -> raise "workspace compilation failed: #{inspect(result)}"
            end
          after
            Code.compiler_options(previous_options)
            Mix.Task.clear()
          end
        end)
      end)
    after
      if previous_project,
        do: Mix.State.write_cache(cache_key, previous_project),
        else: Mix.State.delete_cache(cache_key)
    end
  end

  defp drain(calls, definitions) do
    receive do
      {:compiler_trace, call} ->
        caller = {call.caller_module, call.caller_name, call.caller_arity}

        definition =
          Enum.find(definitions, &(&1.identity == caller and &1.file == Path.expand(call.file))) ||
            Enum.find(definitions, &(&1.identity == caller))

        record = %{
          caller: caller,
          caller_definition_range: definition && definition.range,
          target: {call.target_module, call.target_name, call.target_arity},
          call_range: call.call_range,
          kind: call.kind,
          toolchain: call.toolchain
        }

        drain([record | calls], definitions)
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp function_head({:when, _, [head | _]}), do: function_head(head)
  defp function_head({name, _, args}) when is_atom(name), do: {name, args}

  defp range(line, column, end_line, end_column),
    do: %{
      start: %{line: line - 1, character: column},
      end: %{line: end_line - 1, character: max(end_column, column + 1)}
    }

  defp range_size(definition), do: definition.range.end.line - definition.range.start.line

  defp range_key(range),
    do: {range.start.line, range.start.character, range.end.line, range.end.character}

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
