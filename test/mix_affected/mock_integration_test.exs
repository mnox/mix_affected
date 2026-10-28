defmodule MixAffected.MockIntegrationTest do
  # A Mox mock defined at runtime in test_helper.exs has no source file; the
  # test using it must still be selected when the mocked behaviour changes.
  use ExUnit.Case, async: false

  alias MixAffected.FixtureProject

  setup_all do
    %{dir: FixtureProject.compiled!("mocks")}
  end

  test "a behaviour change selects the tests that use its runtime-defined mock", %{dir: dir} do
    # Read the selection from --output: a stale fixture can make Mix print
    # compile lines (e.g. "==> mox") to stdout before the JSON.
    output = Path.join(dir, "out/selection.json")

    result =
      FixtureProject.mix(
        dir,
        ["affected.files", "--files", "-", "--format", "json", "--explain", "--output", output],
        stdin: "lib/mocks/clock.ex"
      )

    assert result.status == 0, result.stderr
    doc = output |> File.read!() |> JSON.decode!()

    assert doc["tests"] == ["test/mocks/greeter_test.exs"]

    assert doc["explain"]["test/mocks/greeter_test.exs"] ==
             ["lib/mocks/clock.ex", "test/mocks/greeter_test.exs"]
  end
end
