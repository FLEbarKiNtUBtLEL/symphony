defmodule SymphonyElixir.Codex.StopCause do
  @moduledoc """
  Recognises vendor-reported reasons a turn stopped producing work.

  A run can stop because the agent finished, because it asked a question, or because
  the account ran out of capacity. The last of those arrives only as prose inside an
  agent frame, so the runtime did not notice it: a run that had exhausted its usage
  limit was reported to the operator as waiting for operator input, and the operator
  went looking for an approval prompt that did not exist in any session.

  ## This is a classifier, not a parser, and the distinction is deliberate

  Matching a vendor's wording is brittle: the phrase can change without warning and
  this module will silently stop recognising it. So:

    * a match is ADVISORY. It adds an event the operator can read; it never decides
      control flow, so a changed phrase degrades to the old behaviour rather than
      breaking a run.
    * the raw text is carried on the event. Whoever reads it sees what the vendor
      actually said, not only this module's interpretation of it.
    * no match means no claim. Saying nothing is correct when the wording is
      unrecognised; inventing a cause would be worse than the ambiguity it replaces.
  """

  @usage_limit_patterns [
    ~r/you'?ve hit your usage limit/i,
    ~r/usage limit reached/i,
    ~r/you have (?:reached|hit) your (?:usage|rate) limit/i,
    ~r/quota exceeded/i
  ]

  @typedoc "A recognised cause, with the vendor text that showed it."
  @type match :: %{required(:cause) => :usage_limit, required(:phrase) => String.t()}

  @doc """
  Does `text` report exhausted capacity?

  Returns the matched substring rather than a boolean, so the event can quote what
  the vendor said.
  """
  @spec usage_limit(term()) :: {:match, match()} | :no_match
  def usage_limit(text) when is_binary(text) do
    Enum.find_value(@usage_limit_patterns, :no_match, fn pattern ->
      case Regex.run(pattern, text) do
        [phrase | _] -> {:match, %{cause: :usage_limit, phrase: phrase}}
        _ -> nil
      end
    end)
  end

  def usage_limit(_text), do: :no_match

  @doc "The patterns, exposed so a test can assert the set rather than guess at it."
  @spec usage_limit_patterns() :: [Regex.t()]
  def usage_limit_patterns, do: @usage_limit_patterns
end
