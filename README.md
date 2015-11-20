# Bypass

[![Build Status](https://travis-ci.org/PSPDFKit-labs/bypass.svg?branch=master)](https://travis-ci.org/PSPDFKit-labs/bypass)

Bypass provides a quick way to create a custom plug that can be put in place instead of an actual
HTTP server to return prebaked responses to client requests. This is most useful in tests, when you
want to create a mock HTTP server and test how your HTTP client handles different types of
responses from the server.


## Installation

Add bypass to your list of dependencies in mix.exs:

```elixir
def deps do
  [{:bypass, "~> 0.1", only: :test}]
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

To use Bypass in a test case, open a connection and use its port to connect your client to it.

If you want to test what happens when the HTTP server goes down, use `Bypass.down/1` to close the
port and `Bypass.up/1` to start listening on the same port again. Both functions guarantee
that the port will be closed, respective open, after returning:


In this example `TwitterClient` reads its endpoint URL from the `Application`'s configuration:

```elixir
defmodule TwitterClientTest do
  use ExUnit.Case

  setup do
    bypass = Bypass.open
    Application.put_env(:twitter_client, :endpoint, "http://localhost:#{bypass.port}/")
    {:ok, bypass: bypass}
  end

  test "client can handle an error response", %{bypass: bypass} do
    Bypass.expect bypass, fn conn ->
      assert "/1.1/statuses/update.json" == conn.request_path
      assert "POST" == conn.method
      Plug.Conn.send_resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
    end
    {:ok, client} = TwitterClient.start_link()
    assert {:error, :rate_limited} == TwitterClient.post_tweet(client, "Elixir is awesome!")
  end

  test "client can recover from server downtime", %{bypass: bypass} do
    Bypass.expect bypass, fn conn ->
      # We don't care about `request_path` or `method` for this test.
      Plug.Conn.send_resp(conn, 200, "")
    end
    {:ok, client} = TwitterClient.start_link()

    assert :ok == TwitterClient.post_tweet(client, "Elixir is awesome!")

    # Blocks until the TCP socket is closed.
    Bypass.down(bypass)

    assert {:error, :noconnect} == TwitterClient.post_tweet(client, "Elixir is awesome!")

    Bypass.up(bypass)

    # When testing a real client that is using i.e. https://github.com/fishcakez/connection
    # with https://github.com/ferd/backoff to handle reconnecting, we'd have to loop for
    # a while until the client has reconnected.

    assert :ok == TwitterClient.post_tweet(client, "Elixir is awesome!")
  end
end
```

That's all you need to do. Bypass automatically sets up an `on_exit` hook to close its socket when
the test finishes running.

Multiple concurrent Bypass instances are supported, all will have a different unique port.

## Configuration options

Set `:enable_debug_log` to `true` in the application environment to make Bypass log what it's doing:

```elixir
config :bypass, enable_debug_log: true
```
