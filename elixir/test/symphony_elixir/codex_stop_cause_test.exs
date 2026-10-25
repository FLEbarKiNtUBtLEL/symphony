defmodule SymphonyElixir.Codex.StopCauseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.StopCause
  alias SymphonyElixir.StatusDashboard

  test "the vendor phrase is recognised inside a frame, and quoted back" do
    # The wording arrives as prose in an agent message rather than as a field, which
    # is why nothing noticed it: every structural check passed and the run simply
    # stopped producing work.
    raw = ~s({"method":"item/agentMessage","params":{"text":"You've hit your usage limit."}})

    assert {:match, %{cause: :usage_limit, phrase: phrase}} = StopCause.usage_limit(raw)
    assert phrase =~ "usage limit"
  end

  test "wording variants" do
    for text <- [
          "You've hit your usage limit.",
          "You have reached your usage limit",
          "usage limit reached",
          "Quota exceeded for this account"
        ] do
      assert {:match, _} = StopCause.usage_limit(text), text
    end
  end

  test "NO MATCH makes no claim, which is the correct answer when unsure" do
    # A changed vendor phrase must degrade to silence, not to a wrong cause.
    for text <- [
          ~s({"method":"turn/completed"}),
          "the agent finished and wrote its verdict",
          "waiting for user input",
          "",
          nil,
          %{not: "a string"}
        ] do
      assert StopCause.usage_limit(text) == :no_match, inspect(text)
    end
  end

  test "capacity exhaustion and an operator request do not read the same" do
    exhausted =
      StatusDashboard.humanize_codex_message(%{
        event: :usage_limit_reached,
        message: %{phrase: "You've hit your usage limit.", raw: "{}"}
      })

    waiting = StatusDashboard.humanize_codex_message(%{event: :turn_input_required, message: %{}})

    assert exhausted =~ "capacity exhausted"
    assert exhausted =~ "not an operator request"
    refute exhausted =~ "waiting for user input"
    assert waiting =~ "waiting for user input"
    refute exhausted == waiting
  end

  test "the pattern set is explicit, so a silent reduction is visible" do
    assert length(StopCause.usage_limit_patterns()) >= 4
    assert Enum.all?(StopCause.usage_limit_patterns(), &match?(%Regex{}, &1))
  end
end
