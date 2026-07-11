case System.get_env("BYPASS_ADAPTER") do
  "cowboy" -> Application.put_env(:bypass, :adapter, Bypass.Adapter.Cowboy)
  "bandit" -> Application.put_env(:bypass, :adapter, Bypass.Adapter.Bandit)
  nil -> :ok
  other -> raise "unknown BYPASS_ADAPTER: #{inspect(other)}"
end

ExUnit.start()
