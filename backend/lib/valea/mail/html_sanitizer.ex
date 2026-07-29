defmodule Valea.Mail.HtmlSanitizer do
  @moduledoc """
  Defense-in-depth HTML sanitizer for mail bodies (`get_mail_message`'s
  `html` field). The PRIMARY containment is the frontend's sandboxed iframe
  (no scripts, opaque-by-policy, CSP-gated loads); this pass removes the
  dangerous constructs anyway so the payload is inert even if it ever
  reaches a weaker context:

    * whole elements that execute, embed, or navigate: `<script>`,
      `<iframe>`/`<frame>`/`<frameset>`, `<object>`/`<embed>`/`<applet>`,
      `<form>` and its controls, `<base>`, `<meta>`, `<link>`, `<template>`,
      `<svg>`/`<math>` (script-capable content islands);
    * every `on*` event-handler attribute;
    * URL-bearing attributes (`href`/`src`/`background`/`poster`) whose
      scheme isn't http(s), `mailto:`, `cid:`, `data:image/*`, or relative —
      `javascript:` and friends are dropped, including the
      whitespace-obfuscated variants browsers tolerate;
    * `srcset`/`ping`/`formaction`/`xlink:href` outright (redundant load/
      navigation channels the allow-list above doesn't cover).

  `<style>` blocks and `style=` attributes are KEPT — HTML mail is styled
  almost exclusively inline, CSS cannot execute script, and any `url()`
  loads inside it are governed by the iframe's CSP exactly like `<img src>`.

  `external_content?/1` reports whether the (sanitized) HTML references
  remote http(s) resources that would LOAD on render (`src`-like attributes
  and CSS `url()` — not `href` links, which load nothing until clicked).
  That flag drives the frontend's "load remote content?" banner.
  """

  @dropped_tags ~w(script iframe frame frameset object embed applet base meta link form
                   input select textarea button option template svg math dialog portal)

  @url_attrs ~w(href src background poster)
  @dropped_attrs ~w(srcset ping formaction xlink:href dynsrc lowsrc)

  @doc """
  Sanitizes one HTML mail body. Always returns valid-UTF-8 output — invalid
  input bytes are scrubbed to U+FFFD first (Floki passes raw bytes through
  otherwise), and a document Floki cannot parse sanitizes to `""` (the
  caller treats blank as "no HTML view").
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(html) when is_binary(html) do
    html = if String.valid?(html), do: html, else: Valea.Mail.Normalizer.scrub_utf8(html)

    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.traverse_and_update(&sanitize_node/1)
        |> Floki.raw_html()

      _unparseable ->
        ""
    end
  rescue
    _ -> ""
  end

  defp sanitize_node({tag, attrs, children}) do
    if tag in @dropped_tags do
      nil
    else
      {tag, sanitize_attrs(attrs), children}
    end
  end

  defp sanitize_node(other), do: other

  defp sanitize_attrs(attrs) do
    Enum.filter(attrs, fn {name, value} ->
      name = String.downcase(name)

      cond do
        String.starts_with?(name, "on") -> false
        name in @dropped_attrs -> false
        name in @url_attrs -> safe_url?(value)
        true -> true
      end
    end)
  end

  # Browsers strip ASCII whitespace/control characters INSIDE a scheme
  # before resolving it (`jav\tascript:` runs) — so the check strips them
  # first too. The attribute keeps its original value; only the decision
  # uses the normalized form.
  defp safe_url?(value) do
    normalized =
      value
      |> String.replace(~r/[\s\x00-\x1F\x7F]/, "")
      |> String.downcase()

    cond do
      normalized == "" -> true
      String.starts_with?(normalized, "https://") -> true
      String.starts_with?(normalized, "http://") -> true
      String.starts_with?(normalized, "mailto:") -> true
      String.starts_with?(normalized, "cid:") -> true
      String.starts_with?(normalized, "data:image/") -> true
      String.starts_with?(normalized, "#") -> true
      not String.contains?(normalized, ":") -> true
      true -> false
    end
  end

  # `src`-like attributes and CSS url() auto-load on render; `href` does not.
  @external_attr_re ~r/\b(?:src|background|poster)\s*=\s*["']?\s*https?:/i
  @external_css_re ~r/url\(\s*["']?\s*https?:/i

  @doc "Whether rendering `html` would load remote http(s) content (images, CSS url() loads)."
  @spec external_content?(String.t()) :: boolean()
  def external_content?(html) when is_binary(html) do
    Regex.match?(@external_attr_re, html) or Regex.match?(@external_css_re, html)
  end
end
