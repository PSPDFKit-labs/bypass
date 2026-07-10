# Changelog

## Unreleased

* Switch the default HTTP server backend from Cowboy to
  [Bandit](https://hex.pm/packages/bandit).
* Introduce the `Bypass.Adapter` behaviour, making the backend pluggable via
  `config :bypass, adapter: <module>`. Ships `Bypass.Adapter.Bandit` (default)
  and `Bypass.Adapter.Cowboy`.
* `:plug_cowboy` is now an optional dependency. To keep using Cowboy, add
  `{:plug_cowboy, "~> 2.0"}` to your deps and set
  `config :bypass, adapter: Bypass.Adapter.Cowboy`.
* Require at least Elixir 1.14 and OTP 25 (Bandit / the `reuseport` inet option).

## v2.1.0 - 13 Nov 2020

* Support latest Cowboy.
* Require at least Elixir 1.7.
* Ditch Cowboy 1.0

## v2.0.0 - 19 Aug 2020

* Allow the redefinition of routes.
* Make listen interface configurable.
* Add SO_REUSEPORT.
* Add support for parametric routes.
* Switch from :simple_one_for_one to DynamicSupervisor.
* Require at least Elixir 1.6.
* Replace gun with mint.

## v1.0.0 - 26 Nov 2018

* Support for Plug 1.7 with `plug_cowboy` 1 and 2.

## v0.9.0 - 30 Sept 2018

* Add support for Cowboy 2 thanks to @hassox

## v0.6.0 - 2 Feb 2017

* Add support for Elixir v1.0
* Allow choosing the port number for a Bypass instance
* Bypass instances now only listen on the loopback interface
