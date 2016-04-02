# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

config :ex_unit, capture_log: true

config :logger, :console,
  level: :debug,
  format: "$message $metadata\n",
  metadata: [:pid]
