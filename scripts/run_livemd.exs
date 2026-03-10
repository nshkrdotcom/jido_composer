# Extracts Elixir code cells from a .livemd file and evaluates them as a single script.
#
# Usage:
#   mix run scripts/run_livemd.exs livebooks/01_etl_pipeline.livemd
#   mix run scripts/run_livemd.exs livebooks/*.livemd
#
# Cells with Mix.install are handled in two ways:
#   - If the livebook only depends on the project itself (+ kino), the Mix.install
#     cell is skipped and any config it contains is applied via Application.put_env.
#   - If the livebook has external deps beyond the project, it is executed as a
#     standalone `elixir` script so that Mix.install can actually run.
#
# Kino display calls are replaced with IO equivalents.
# Blocking Kino widgets (streams, frames, render) are skipped.

defmodule LivemdRunner do
  @kino_skip_patterns [
    ~r/Kino\.Control\.stream/,
    ~r/Kino\.Frame\./,
    ~r/Kino\.render/
  ]

  def run(path) do
    unless File.exists?(path) do
      IO.puts(:stderr, "File not found: #{path}")
      System.halt(1)
    end

    IO.puts("\n#{String.duplicate("=", 60)}")
    IO.puts("Running: #{path}")
    IO.puts(String.duplicate("=", 60))

    cells = extract_cells(File.read!(path))

    if needs_standalone?(cells) do
      run_standalone(path, cells)
    else
      run_inline(path, cells)
    end
  end

  # Detect whether a livebook has external deps that require Mix.install.
  # If the Mix.install cell only has {:jido_composer, path: ...} and {:kino, ...},
  # everything is already available in the project — run inline.
  # Otherwise, run standalone so Mix.install can fetch the extra deps.
  defp needs_standalone?(cells) do
    case Enum.find(cells, &mix_install_cell?/1) do
      nil -> false
      cell -> has_external_deps?(cell)
    end
  end

  defp has_external_deps?(cell) do
    # Extract dep tuples from Mix.install call
    deps =
      Regex.scan(~r/\{:(\w+),/, cell)
      |> Enum.map(fn [_, name] -> name end)

    # These are available in the project context — anything else is external
    project_deps = MapSet.new(~w(jido_composer kino))
    Enum.any?(deps, fn dep -> not MapSet.member?(project_deps, dep) end)
  end

  # ---------- Standalone mode (Mix.install runs in a child `elixir` process) ----------

  defp run_standalone(path, cells) do
    total = length(cells)

    script =
      cells
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {cell, idx} ->
        if kino_skip_cell?(cell) do
          IO.puts("  [#{idx}/#{total}] Skipping (Kino UI)")
          []
        else
          label = if mix_install_cell?(cell), do: "Mix.install", else: "#{line_count(cell)} lines"
          IO.puts("  [#{idx}/#{total}] Including (#{label})")
          [rewrite_mix_install(sanitize_kino(cell), path)]
        end
      end)
      |> Enum.join("\n\n")

    skipped = total - (cells |> Enum.with_index(1) |> Enum.reject(fn {c, _} -> kino_skip_cell?(c) end) |> length())
    included = total - skipped

    IO.puts("\nEvaluating #{included} cells (standalone elixir)...")

    # Write to a temp file and run with `elixir`
    tmp_path = Path.join(System.tmp_dir!(), "livemd_runner_#{:erlang.phash2(path)}.exs")
    File.write!(tmp_path, script)

    try do
      {output, exit_code} =
        System.cmd("elixir", [tmp_path],
          stderr_to_stdout: true,
          env: [{"MIX_INSTALL_DIR", mix_install_cache_dir()}]
        )

      IO.write(output)

      result = if exit_code == 0, do: :ok, else: :error
      status = if result == :ok, do: "PASSED", else: "FAILED"
      IO.puts("\n#{String.duplicate("-", 40)}")
      IO.puts("#{status} (#{included} evaluated, #{skipped} skipped)")
      result
    after
      File.rm(tmp_path)
    end
  end

  # Rewrite Mix.install to use path: for jido_composer relative to the livebook's dir.
  # In standalone mode, __DIR__ won't be the livebook's dir, so resolve it now.
  defp rewrite_mix_install(cell, livebook_path) do
    if mix_install_cell?(cell) do
      project_root = Path.expand(Path.join(Path.dirname(livebook_path), ".."))

      cell
      |> String.replace(
        ~r/Path\.join\(__DIR__,\s*"\.\."\)/,
        inspect(project_root)
      )
    else
      cell
    end
  end

  defp mix_install_cache_dir do
    Path.join(System.tmp_dir!(), "livemd_mix_install")
  end

  # ---------- Inline mode (evaluated inside the mix project process) ----------

  defp run_inline(path, cells) do
    total = length(cells)

    {install_cells, code_cells} = Enum.split_with(cells, &mix_install_cell?/1)

    # Apply config from Mix.install cell (if any) so runtime config is available
    Enum.each(install_cells, &apply_install_config/1)

    skipped_count = Enum.count(cells, &skip_cell?/1)

    script =
      cells
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {cell, idx} ->
        if skip_cell?(cell) do
          IO.puts("  [#{idx}/#{total}] Skipping (Mix.install/Kino UI)")
          []
        else
          IO.puts("  [#{idx}/#{total}] Including (#{line_count(cell)} lines)")
          [sanitize_kino(cell)]
        end
      end)
      |> Enum.join("\n\n")

    IO.puts("\nEvaluating #{total - skipped_count} cells...")

    result =
      try do
        Code.eval_string(script, [], file: path, line: 1)
        :ok
      rescue
        e ->
          IO.puts(:stderr, "\n  ERROR: #{Exception.format(:error, e, __STACKTRACE__)}")
          :error
      catch
        kind, value ->
          IO.puts(:stderr, "\n  ERROR: #{Exception.format(kind, value, __STACKTRACE__)}")
          :error
      end

    status = if result == :ok, do: "PASSED", else: "FAILED"
    IO.puts("\n#{String.duplicate("-", 40)}")
    IO.puts("#{status} (#{total - skipped_count} evaluated, #{skipped_count} skipped)")

    result
  end

  # Extract the `config:` keyword from a Mix.install cell and apply it.
  # This makes runtime config (e.g. req_llm API keys) available even when
  # Mix.install itself is skipped.
  defp apply_install_config(cell) do
    case Regex.run(~r/config:\s*\[(.+)\]\s*\)/s, cell) do
      [_, config_source] ->
        try do
          {config, _} = Code.eval_string("[#{config_source}]")

          Enum.each(config, fn {app, kvs} ->
            Enum.each(kvs, fn {key, value} ->
              Application.put_env(app, key, value)
            end)
          end)
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # ---------- Shared helpers ----------

  defp extract_cells(content) do
    # Match ```elixir ... ``` blocks but not ````elixir (4-backtick blocks)
    regex = ~r/(?<!`)```elixir\n(.*?)```/s

    Regex.scan(regex, content, capture: :all_but_first)
    |> Enum.map(fn [code] -> String.trim(code) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp mix_install_cell?(cell), do: Regex.match?(~r/Mix\.install\(/, cell)

  defp kino_skip_cell?(cell) do
    Enum.any?(@kino_skip_patterns, &Regex.match?(&1, cell))
  end

  defp skip_cell?(cell) do
    mix_install_cell?(cell) or kino_skip_cell?(cell)
  end

  defp line_count(cell) do
    cell |> String.split("\n") |> length()
  end

  defp sanitize_kino(cell) do
    cell
    |> String.replace(~r/Kino\.Markdown\.new\(/, "IO.puts(")
    |> String.replace(~r/Kino\.Tree\.new\(/, "IO.inspect(")
    |> String.replace(~r/Kino\.Layout\.grid\(/, "IO.inspect(")
    |> String.replace(~r/Kino\.Layout\.tabs\(/, "IO.inspect(")
  end
end

# --- Main ---

case System.argv() do
  [] ->
    IO.puts("Usage: mix run scripts/run_livemd.exs <file.livemd> [file2.livemd ...]")
    System.halt(1)

  paths ->
    results =
      paths
      |> Enum.flat_map(fn path ->
        case Path.wildcard(path) do
          [] -> [path]
          expanded -> expanded
        end
      end)
      |> Enum.sort()
      |> Enum.map(&LivemdRunner.run/1)

    failed = Enum.count(results, &(&1 == :error))

    if failed > 0 do
      IO.puts("\n#{failed} file(s) had failures.")
      System.halt(1)
    else
      IO.puts("\nAll files passed.")
    end
end
