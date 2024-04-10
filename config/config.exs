# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
import Config

config :bypass, test_framework: :ex_unit

config :ex_unit, capture_log: true

config :logger, :console,
  level: :debug,
  format: "$message $metadata\n",
  metadata: [:pid]
