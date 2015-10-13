# Bypass

Bypass provides a quick way to create a custom plug that can be put in place instead of an actual
HTTP server to return prebaked responses to client requests. This is most useful in tests, when you
want to create a mock HTTP server and test how your HTTP client handles different types of
responses from the server.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add bypass to your list of dependencies in mix.exs:

     ```elixir
     def deps do
       [{:bypass, "~> 0.0.1"}]
     end
     ```

     It is not recommended to add `:bypass` to the list of applications in your `mix.exs`. See below
     for usage info.


## Usage

Start Bypass in your `test/test_helper.exs` file to make it available in tests:

```elixir
ExUnit.start
Application.ensure_all_started(:bypass)
```

To use Bypass in a test case, open a connection and use its port to connect your client to it:

```elixir
defmodule MyClientTest do
  use ExUnit.Case

  setup do
    bypass = Bypass.open
    context = %{bypass: bypass, url: "http://localhost:#{bypass.port}/"}
    {:ok, context}
  end

  test "client can handle an error response", context do
    Bypass.expect context.bypass, fn conn ->
      assert "/no_idea" == conn.request_path
      assert "POST" == conn.method
      Plug.Conn.send_resp(conn, 400, "Please make up your mind!")
    end

    client = MyClient.connect(context.url)
    assert {:error, {400, "Please make up your mind!"}} == MyClient.post_no_idea(client, "")
  end
end
```

That's all you need to do. Bypass automatically sets up an `on_exit` hook to close its socket when
the test finishes running.
