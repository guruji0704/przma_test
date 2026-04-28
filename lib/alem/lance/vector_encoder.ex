defmodule Alem.Lance.VectorEncoder do
  @moduledoc """
  Generates 446-dimensional HOLNN vectors from media files.
  Combines: media features (256) + SevenP (7) + PRESERVE (100) + LiGHT (83)
  Total = 446 dimensions
  """

  # ── Public API ─────────────────────────────────────────────────────────

  def encode(file_bytes, media_type, classification) when is_binary(file_bytes) do
    media_vec    = media_features(file_bytes, media_type)   # 256 dims
    seven_p_vec  = seven_p_encode(classification)            # 7 dims
    preserve_vec = preserve_encode(classification)           # 100 dims
    light_vec    = light_encode(classification)              # 83 dims

    vector = media_vec ++ seven_p_vec ++ preserve_vec ++ light_vec
    normalize(vector)
  end

  def encode(_, _, _), do: List.duplicate(0.0, 446)

  # ── Media Feature Extraction ───────────────────────────────────────────

  # Audio — energy-based features (MFCC-style approximation)
  defp media_features(bytes, "audio/" <> _) do
    size       = byte_size(bytes)
    chunk_size = max(1, div(size, 256))

    for i <- 0..255 do
      offset = min(i * chunk_size, size - 1)
      len    = min(chunk_size, size - offset)
      chunk  = binary_part(bytes, offset, len)
      audio_energy(chunk)
    end
  end

  # Video — frame sampling at regular intervals
  defp media_features(bytes, "video/" <> _) do
    size = byte_size(bytes)
    step = max(1, div(size, 256))

    for i <- 0..255 do
      offset = min(i * step, size - 1)
      <<val>> = binary_part(bytes, offset, 1)
      val / 255.0
    end
  end

  # Image — pixel intensity sampling
  defp media_features(bytes, "image/" <> _) do
    size = byte_size(bytes)
    step = max(1, div(size, 256))

    for i <- 0..255 do
      offset = min(i * step, size - 1)
      <<val>> = binary_part(bytes, offset, 1)
      val / 255.0
    end
  end

  # Document/text — byte frequency histogram
  defp media_features(bytes, _) do
    total = byte_size(bytes)
    freq  = bytes |> :binary.bin_to_list() |> Enum.frequencies()
    for i <- 0..255, do: Map.get(freq, i, 0) / max(total, 1)
  end

  # ── SevenP Encoding (7 dimensions) ────────────────────────────────────

  defp seven_p_encode(%{"seven_p_primary" => p}) do
    values = ~w(portfolio platform position product perception purpose people)
    for v <- values, do: if(v == p, do: 1.0, else: 0.0)
  end
  defp seven_p_encode(_), do: List.duplicate(0.0, 7)

  # ── PRESERVE Encoding (100 dimensions) ────────────────────────────────

  defp preserve_encode(%{"preserve_primary" => p}) do
    index = preserve_index(p)
    for i <- 0..99, do: if(i == index, do: 1.0, else: 0.0)
  end
  defp preserve_encode(_), do: List.duplicate(0.0, 100)

  defp preserve_index(p) do
    ~w(engagement empathy equity ethics ethos evidence excellence
       execution experience expression extension extraction
       evaluation evolution exploration exposition
       efficiency effectiveness emergence enablement
       enrichment entertainment enlightenment empowerment
       endurance encouragement endorsement enhancement
       enterprise entitlement environment equilibrium
       escalation estimation evaluation evolution
       examination exchange excitation exclusion
       exemption exertion exhaustion exhibition
       expansion expectation expiration explanation
       exploitation exploration exportation exposition
       expression extension extraction extremity)
    |> Enum.find_index(&(&1 == p)) || 0
  end

  # ── LiGHT Encoding (83 dimensions) ────────────────────────────────────

  defp light_encode(%{"light_element" => l}) do
    index = light_index(l)
    for i <- 0..82, do: if(i == index, do: 1.0, else: 0.0)
  end
  defp light_encode(_), do: List.duplicate(0.0, 83)

  defp light_index(l) do
    ~w(transform transmit transcend translate transact traverse
       trace track train transfer trigger trust
       tend test think throw tie time touch
       turn teach take talk target teach team
       think tie time touch track train
       transform transmit transcend translate
       transact traverse trigger trust tend
       test throw turn lead learn leverage
       listen locate love maintain manage
       measure mediate mentor mobilize
       model moderate monitor motivate
       navigate negotiate nurture observe
       optimize organize orient pioneer
       plan position prepare present
       prioritize produce protect provide
       pursue realize reflect resolve
       restore reward shape share support)
    |> Enum.find_index(&(&1 == l)) || 0
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp audio_energy(bytes) do
    list = :binary.bin_to_list(bytes)
    sum  = Enum.reduce(list, 0, fn b, acc -> acc + b * b end)
    :math.sqrt(sum / max(length(list), 1)) / 255.0
  end

  defp normalize(vector) do
    magnitude =
      vector
      |> Enum.map(&(&1 * &1))
      |> Enum.sum()
      |> :math.sqrt()

    if magnitude > 0,
      do:   Enum.map(vector, &(&1 / magnitude)),
      else: vector
  end
end
