defmodule Adinize.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/udin-io/adinize-elixir"

  def project do
    [
      app: :adinize,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Elixir SDK for the adinize server events API: send conversions from your " <>
          "backend to Meta, TikTok and Google Ads, with hashed personal data.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "OpenAPI contract" => "https://adinize.ai/api/server/v1/openapi.yaml",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40", only: [:dev]},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:plug, "~> 1.20", optional: true},
      {:yaml_elixir, "~> 2.0", only: [:test]},
      {:ex_json_schema, "~> 0.11", only: [:test]},
      {:credo, "~> 1.0", only: [:dev, :test]},
      {:req, "~> 0.7"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
