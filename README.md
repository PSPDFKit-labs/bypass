# Bypass

<!-- MDOC !-->

[![Build Status](https://github.com/PSPDFKit-labs/bypass/actions/workflows/elixir.yml/badge.svg?branch=master)](https://github.com/PSPDFKit-labs/bypass/actions)
[![Module Version](https://img.shields.io/hexpm/v/bypass.svg)](https://hex.pm/packages/bypass)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/bypass/)
[![Total Download](https://img.shields.io/hexpm/dt/bypass.svg)](https://hex.pm/packages/bypass)
[![License](https://img.shields.io/hexpm/l/bypass.svg)](https://github.com/PSPDFKit-labs/bypass/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/PSPDFKit-labs/bypass.svg)](https://github.com/PSPDFKit-labs/bypass/commits/master)


`Bypass` provides a quick way to create a custom plug that can be put in place
instead of an actual HTTP server to return prebaked responses to client
requests. This is most useful in tests, when you want to create a mock HTTP
server and test how your HTTP client handles different types of responses from
the server.

Bypass supports Elixir 1.10 and OTP 21 and up. It works with Cowboy 2.

## Usage

To use Bypass in a test case, open a connection and use its port to connect your
client to it.

If you want to test what happens when the HTTP server goes down, use
`Bypass.down/1` to close the TCP socket and `Bypass.up/1` to start listening on
the same port again. Both functions block until the socket updates its state.

### Expect Functions

You can take any of the following approaches:

* `expect/2` or `expect_once/2` to install a generic function that all calls to
  bypass will use
* `expect/4` and/or `expect_once/4` to install specific routes (method and path)
* `stub/4` to install specific routes without expectations
* a combination of the above, where the routes will be used first, and then the
  generic version will be used as default

### Example

In the following example `TwitterClient.start_link()` takes the endpoint URL as
its argument allowing us to make sure it will connect to the running instance of
Bypass.

```elixir
defmodule TwitterClientTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  test "client can handle an error response", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/1.1/statuses/update.json", fn conn ->
      Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
    end)

    {:ok, client} = TwitterClient.start_link(url: endpoint_url(bypass.port))
    assert {:error, :rate_limited} == TwitterClient.post_tweet(client, "Elixir is awesome!")
  end

  test "client can recover from server downtime", %{bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      # We don't care about `request_path` or `method` for this test.
      Plug.Conn.resp(conn, 200, "")
    end)

    {:ok, client} = TwitterClient.start_link(url: endpoint_url(bypass.port))

    assert :ok == TwitterClient.post_tweet(client, "Elixir is awesome!")

    # Blocks until the TCP socket is closed.
    Bypass.down(bypass)

    assert {:error, :noconnect} == TwitterClient.post_tweet(client, "Elixir is awesome!")

    Bypass.up(bypass)

    # When testing a real client that is using e.g. https://github.com/fishcakez/connection
    # with https://github.com/ferd/backoff to handle reconnecting, we'd have to loop for
    # a while until the client has reconnected.

    assert :ok == TwitterClient.post_tweet(client, "Elixir is awesome!")
  end

  defp endpoint_url(port), do: "http://localhost:#{port}/"
end
```

That's all you need to do. Bypass automatically sets up an `on_exit` hook to
close its socket when the test finishes running.

Multiple concurrent Bypass instances are supported, all will have a different
unique port.  Concurrent requests are also supported on the same instance.

> Note: `Bypass.open/0` **must not** be called in a `setup_all` blocks due to
> the way Bypass verifies the expectations at the end of each test.

## How to use with ESpec

While Bypass primarily targets ExUnit, the official Elixir builtin test
framework, it can also be used with [ESpec](https://hex.pm/packages/espec). The
test configuration is basically the same, there are only two differences:

1. In your Mix config file, you must declare which test framework Bypass is
   being used with (defaults to `:ex_unit`). This simply disables the automatic
   integration with some hooks provided by `ExUnit`.

   ```elixir
   config :bypass, test_framework: :espec
   ```

2. In your specs, you must explicitly verify the declared expectations. You can
   do it in the `finally` block.

   ```elixir
   defmodule TwitterClientSpec do
     use ESpec, async: true

     before do
       bypass = Bypass.open()
       {:shared, bypass: bypass}
     end

     finally do
       Bypass.verify_expectations!(shared.bypass)
     end

     specify "the client can handle an error response" do
       Bypass.expect_once(shared.bypass, "POST", "/1.1/statuses/update.json", fn conn ->
         Plug.Conn.resp(conn, 429, ~s<{"errors": [{"code": 88, "message": "Rate limit exceeded"}]}>)
       end)

       {:ok, client} = TwitterClient.start_link(url: endpoint_url(shared.bypass.port))
       assert {:error, :rate_limited} == TwitterClient.post_tweet(client, "Elixir is awesome!")
     end

     defp endpoint_url(port), do: "http://localhost:#{port}/"
   end
   ```

## Configuration options

Set `:enable_debug_log` to `true` in the application environment to make Bypass
log what it's doing:

```elixir
config :bypass, enable_debug_log: true
```

<!-- MDOC !-->

## Installation

Add `:bypass` to your list of dependencies in mix.exs:

```elixir
def deps do
  [
    {:bypass, "~> 2.1", only: :test}
  ]
end
```

We do not recommended adding `:bypass` to the list of applications in your
`mix.exs`.

## License

This software is licensed under [the MIT license](LICENSE).

## About

<a href="https://pspdfkit.com/">
  <img src="https://avatars2.githubusercontent.com/u/1527679?v=3&s=200" height="80" />
</a>

This project is maintained and funded by [PSPDFKit](https://pspdfkit.com/).

Please ensure [you signed our
CLA](https://pspdfkit.com/guides/web/current/miscellaneous/contributing/) so we
can accept your contributions.

See [our other open source projects](https://github.com/PSPDFKit-labs), read
[our blog](https://pspdfkit.com/blog/) or say hello on Twitter
([@PSPDFKit](https://twitter.com/pspdfkit)).
